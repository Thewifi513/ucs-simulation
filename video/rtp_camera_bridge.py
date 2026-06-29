#!/usr/bin/env python3
"""Bridge one video source to RTP/H.264 over UDP.

The process is intended to run in a UAV network namespace, while using the
host filesystem and host GStreamer/Python libraries via nsenter. That makes the
UDP source address the UAV experiment IP, so packets enter the existing
eth1 -> BMv2 -> ns-3 -> GS dataplane.

The default source is a synthetic H.264 stream for network background-load
experiments. Use --source-mode camera when a real Gazebo camera topic is
available and the extra sensor/rendering cost is intentional.
"""

from __future__ import annotations

import argparse
import signal
import sys
import threading
import time
from dataclasses import dataclass

import gi
from gz.msgs10 import image_pb2
from gz.transport13 import Node

gi.require_version("Gst", "1.0")
from gi.repository import Gst  # noqa: E402


PIXEL_FORMATS = {
    image_pb2.RGB_INT8: ("RGB", 3),
    image_pb2.RGBA_INT8: ("RGBA", 4),
    image_pb2.BGR_INT8: ("BGR", 3),
    image_pb2.BGRA_INT8: ("BGRA", 4),
    image_pb2.L_INT8: ("GRAY8", 1),
}


@dataclass
class Stats:
    frames_in: int = 0
    frames_sent: int = 0
    frames_dropped: int = 0
    bytes_in: int = 0
    start_s: float = 0.0
    first_frame_s: float = 0.0
    last_frame_s: float = 0.0
    last_error: str = ""


class RtpCameraBridge:
    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        self.node: Node | None = None
        self.stop_event = threading.Event()
        self.ready_event = threading.Event()
        self.lock = threading.Lock()
        self.stats = Stats(start_s=time.monotonic())
        self.pipeline: Gst.Pipeline | None = None
        self.appsrc: Gst.Element | None = None
        self.frame_duration_ns = int(Gst.SECOND / max(args.fps, 1))
        self.next_pts = 0
        self.width = 0
        self.height = 0
        self.output_width = 0
        self.output_height = 0
        self.gst_format = ""
        self.channels = 0
        self.encoder_label = ""

    def _has_factory(self, factory: str) -> bool:
        return Gst.ElementFactory.find(factory) is not None

    def _encoder_fragment(self, encoder: str, keyint: int) -> tuple[str, str, str, str] | None:
        normalized = encoder.strip().lower().replace("_", "-")
        bitrate = max(1, int(self.args.bitrate_kbps))
        if normalized in {"x264", "x264enc", "software", "soft"}:
            return (
                "x264enc",
                "x264enc",
                "I420",
                f"x264enc bitrate={bitrate} speed-preset=ultrafast "
                f"tune=zerolatency key-int-max={keyint} threads=2",
            )
        if normalized in {"openh264", "openh264enc"}:
            return (
                "openh264enc",
                "openh264enc",
                "I420",
                f"openh264enc bitrate={bitrate * 1000}",
            )
        if normalized in {"nvenc", "nvh264", "nvh264enc", "nvidia"}:
            return (
                "nvh264enc",
                "nvh264enc",
                "NV12",
                f"nvh264enc bitrate={bitrate} gop-size={keyint}",
            )
        if normalized in {"nvauto", "nvautogpu", "nvautogpuh264", "nvautogpuh264enc"}:
            return (
                "nvautogpuh264enc",
                "nvautogpuh264enc",
                "NV12",
                f"nvautogpuh264enc bitrate={bitrate} gop-size={keyint}",
            )
        if normalized in {"nvcuda", "nvcudah264", "nvcudah264enc"}:
            return (
                "nvcudah264enc",
                "nvcudah264enc",
                "NV12",
                f"nvcudah264enc bitrate={bitrate} gop-size={keyint}",
            )
        if normalized in {"va", "vah264", "vah264enc"}:
            return (
                "vah264enc",
                "vah264enc",
                "NV12",
                f"vah264enc bitrate={bitrate}",
            )
        if normalized in {"vaapi", "vaapih264", "vaapih264enc"}:
            return (
                "vaapih264enc",
                "vaapih264enc",
                "NV12",
                f"vaapih264enc bitrate={bitrate} keyframe-period={keyint}",
            )
        if normalized in {"v4l2", "v4l2h264", "v4l2h264enc"}:
            return (
                "v4l2h264enc",
                "v4l2h264enc",
                "NV12",
                "v4l2h264enc",
            )
        return None

    def _encoder_candidates(self, keyint: int) -> list[tuple[str, str, str]]:
        requested = self.args.encoder.strip().lower().replace("_", "-")
        hard_names = (
            "nvautogpuh264enc",
            "nvh264enc",
            "nvcudah264enc",
            "vah264enc",
            "vaapih264enc",
            "v4l2h264enc",
        )
        if requested in {"auto", "hard", "hw", "hardware"}:
            candidates: list[tuple[str, str, str]] = []
            for name in hard_names:
                fragment = self._encoder_fragment(name, keyint)
                if fragment is not None and self._has_factory(fragment[1]):
                    candidates.append((fragment[0], fragment[2], fragment[3]))
            if requested == "auto":
                for name in ("openh264enc", "x264"):
                    fallback = self._encoder_fragment(name, keyint)
                    if fallback is not None and self._has_factory(fallback[1]):
                        candidates.append((fallback[0], fallback[2], fallback[3]))
            if not candidates:
                if requested == "auto":
                    self._error("no usable H.264 encoder is available")
                else:
                    self._error("no usable hardware H.264 encoder is available")
            return candidates

        fragment = self._encoder_fragment(requested, keyint)
        if fragment is None:
            self._error(f"unsupported encoder: {self.args.encoder}")
            return []
        label, factory, raw_format, pipeline_fragment = fragment
        if not self._has_factory(factory):
            self._error(f"GStreamer encoder is not available: {factory}")
            return []
        return [(label, raw_format, pipeline_fragment)]

    def _encoder_can_try_next(self) -> bool:
        requested = self.args.encoder.strip().lower().replace("_", "-")
        return requested in {"auto", "hard", "hw", "hardware"}

    def _keyint(self) -> int:
        interval_sec = max(0.0, float(self.args.keyframe_interval_sec))
        if interval_sec <= 0.0:
            interval_sec = 1.0
        return max(1, int(round(float(self.args.fps) * interval_sec)))

    def _launch_pipeline(self, pipeline_desc: str, encoder_label: str) -> Gst.Pipeline | None:
        if self.args.print_pipeline:
            print(f"[rtp-camera] encoder={encoder_label} pipeline={pipeline_desc}", flush=True)

        try:
            pipeline = Gst.parse_launch(pipeline_desc)
        except Exception as exc:
            if self._encoder_can_try_next():
                print(
                    f"[rtp-camera][W] encoder {encoder_label} failed to build: {exc}",
                    file=sys.stderr,
                    flush=True,
                )
                return None
            self._error(f"failed to build GStreamer pipeline: {exc}")
            return None

        ret = pipeline.set_state(Gst.State.PLAYING)
        if ret == Gst.StateChangeReturn.FAILURE:
            pipeline.set_state(Gst.State.NULL)
            if self._encoder_can_try_next():
                print(
                    f"[rtp-camera][W] encoder {encoder_label} failed to start",
                    file=sys.stderr,
                    flush=True,
                )
                return None
            self._error("failed to set GStreamer pipeline to PLAYING")
            return None

        self.encoder_label = encoder_label
        return pipeline

    def start(self) -> None:
        Gst.init(None)
        if self.args.source_mode == "synthetic":
            self._build_synthetic_pipeline()
            return

        if not self.args.topic:
            self._error("--topic is required when --source-mode camera")
            self.stop_event.set()
            return
        self.node = Node()
        self.node.subscribe(image_pb2.Image, self.args.topic, self._on_image)
        print(
            "[rtp-camera] subscribed "
            f"topic={self.args.topic} dst={self.args.dst_ip}:{self.args.dst_port} "
            f"bind={self.args.bind_ip or 'auto'} bitrate_kbps={self.args.bitrate_kbps}",
            flush=True,
        )

    def stop(self) -> None:
        self.stop_event.set()
        if self.node is not None and self.args.topic:
            try:
                self.node.unsubscribe(self.args.topic)
            except Exception:
                pass
        if self.appsrc is not None:
            self.appsrc.emit("end-of-stream")
        if self.pipeline is not None:
            self.pipeline.set_state(Gst.State.NULL)

    def wait(self) -> int:
        deadline = None
        if self.args.duration_sec > 0:
            deadline = time.monotonic() + self.args.duration_sec

        next_report = time.monotonic() + self.args.report_sec
        while not self.stop_event.is_set():
            now = time.monotonic()
            if deadline is not None and now >= deadline:
                break
            if now >= next_report:
                self._print_report("report")
                next_report = now + self.args.report_sec
            self._poll_bus()
            time.sleep(0.05)

        self.stop()
        self._print_report("summary")
        if self.args.source_mode == "synthetic":
            return 0 if self.pipeline is not None and not self.stats.last_error else 1
        return 0 if self.stats.frames_sent > 0 else 1

    def _build_synthetic_pipeline(self) -> bool:
        bind_part = ""
        if self.args.bind_ip:
            bind_part = f" bind-address={self.args.bind_ip} bind-port=0"

        fps_int = max(1, int(round(self.args.fps)))
        keyint = self._keyint()
        pipeline = None
        for encoder_label, raw_format, encoder_fragment in self._encoder_candidates(keyint):
            pipeline_desc = (
                f"videotestsrc is-live=true pattern={self.args.pattern} "
                f"! video/x-raw,format=I420,width={self.args.width},height={self.args.height},"
                f"framerate={fps_int}/1 "
                "! queue leaky=downstream max-size-buffers=2 max-size-time=0 max-size-bytes=0 "
                "! videoconvert "
                f"! video/x-raw,format={raw_format} "
                f"! {encoder_fragment} "
                f"! rtph264pay config-interval=1 pt=96 mtu={self.args.mtu} "
                f"! udpsink host={self.args.dst_ip} port={self.args.dst_port}"
                f"{bind_part} sync=false async=false"
            )
            pipeline = self._launch_pipeline(pipeline_desc, encoder_label)
            if pipeline is not None:
                break
        if pipeline is None:
            return False

        self.pipeline = pipeline
        self.ready_event.set()
        print(
            "[rtp-camera] synthetic streaming "
            f"{self.args.width}x{self.args.height}@{self.args.fps:g} "
            f"to {self.args.dst_ip}:{self.args.dst_port} "
            f"bind={self.args.bind_ip or 'auto'} bitrate_kbps={self.args.bitrate_kbps} "
            f"encoder={self.encoder_label} keyint={keyint}",
            flush=True,
        )
        return True

    def _build_pipeline(self, msg: image_pb2.Image) -> bool:
        pixel_format = int(msg.pixel_format_type)
        if pixel_format not in PIXEL_FORMATS:
            self._drop(f"unsupported pixel_format_type={pixel_format}")
            return False

        gst_format, channels = PIXEL_FORMATS[pixel_format]
        width = int(msg.width)
        height = int(msg.height)
        expected_step = width * channels
        if int(msg.step) != expected_step:
            self._drop(f"unsupported stride step={msg.step} expected={expected_step}")
            return False

        bind_part = ""
        if self.args.bind_ip:
            bind_part = f" bind-address={self.args.bind_ip} bind-port=0"

        keyint = self._keyint()
        pipeline = None
        for encoder_label, raw_format, encoder_fragment in self._encoder_candidates(keyint):
            output_width = int(self.args.output_width or width)
            output_height = int(self.args.output_height or height)
            scale_caps = f"video/x-raw,format={raw_format},width={output_width},height={output_height}"
            pipeline_desc = (
                "appsrc name=src is-live=true block=false do-timestamp=true format=time "
                f"caps=video/x-raw,format={gst_format},width={width},height={height},"
                f"framerate={int(self.args.fps)}/1 "
                "! queue leaky=downstream max-size-buffers=2 max-size-time=0 max-size-bytes=0 "
                "! videoconvert ! videoscale "
                f"! {scale_caps} "
                f"! {encoder_fragment} "
                f"! rtph264pay config-interval=1 pt=96 mtu={self.args.mtu} "
                f"! udpsink host={self.args.dst_ip} port={self.args.dst_port}"
                f"{bind_part} sync=false async=false"
            )
            pipeline = self._launch_pipeline(pipeline_desc, encoder_label)
            if pipeline is not None:
                break
        if pipeline is None:
            return False

        appsrc = pipeline.get_by_name("src")
        if appsrc is None:
            self._error("failed to get appsrc from GStreamer pipeline")
            return False

        ret = pipeline.set_state(Gst.State.PLAYING)
        if ret == Gst.StateChangeReturn.FAILURE:
            self._error("failed to set GStreamer pipeline to PLAYING")
            return False

        self.pipeline = pipeline
        self.appsrc = appsrc
        self.width = width
        self.height = height
        self.output_width = int(self.args.output_width or width)
        self.output_height = int(self.args.output_height or height)
        self.gst_format = gst_format
        self.channels = channels
        self.ready_event.set()
        shape = f"{width}x{height}"
        if self.output_width != width or self.output_height != height:
            shape = f"{shape}->{self.output_width}x{self.output_height}"
        print(
            "[rtp-camera] streaming "
            f"{shape}@{self.args.fps:g} format={gst_format} "
            f"to {self.args.dst_ip}:{self.args.dst_port} encoder={self.encoder_label} keyint={keyint}",
            flush=True,
        )
        return True

    def _on_image(self, msg: image_pb2.Image) -> None:
        if self.stop_event.is_set():
            return

        with self.lock:
            self.stats.frames_in += 1
            self.stats.bytes_in += len(msg.data)
            now = time.monotonic()
            if self.stats.first_frame_s == 0.0:
                self.stats.first_frame_s = now
            self.stats.last_frame_s = now

            if self.pipeline is None and not self._build_pipeline(msg):
                return
            if self.appsrc is None:
                self._drop("appsrc is not available")
                return

            expected_size = self.width * self.height * self.channels
            if len(msg.data) != expected_size:
                self._drop(f"bad frame size={len(msg.data)} expected={expected_size}")
                return

            buffer = Gst.Buffer.new_allocate(None, expected_size, None)
            buffer.fill(0, msg.data)
            buffer.pts = self.next_pts
            buffer.dts = self.next_pts
            buffer.duration = self.frame_duration_ns
            self.next_pts += self.frame_duration_ns

            ret = self.appsrc.emit("push-buffer", buffer)
            if ret != Gst.FlowReturn.OK:
                self._drop(f"push-buffer failed: {ret.value_nick}")
                return

            self.stats.frames_sent += 1

    def _drop(self, reason: str) -> None:
        self.stats.frames_dropped += 1
        if reason != self.stats.last_error:
            self.stats.last_error = reason
            print(f"[rtp-camera][W] {reason}", file=sys.stderr, flush=True)

    def _error(self, reason: str) -> None:
        self.stats.last_error = reason
        print(f"[rtp-camera][ERR] {reason}", file=sys.stderr, flush=True)

    def _poll_bus(self) -> None:
        if self.pipeline is None:
            return
        bus = self.pipeline.get_bus()
        while True:
            msg = bus.pop_filtered(Gst.MessageType.ERROR | Gst.MessageType.WARNING)
            if msg is None:
                break
            if msg.type == Gst.MessageType.ERROR:
                err, debug = msg.parse_error()
                self._error(f"gstreamer error: {err}; {debug}")
                self.stop_event.set()
            elif msg.type == Gst.MessageType.WARNING:
                err, debug = msg.parse_warning()
                print(f"[rtp-camera][W] gstreamer warning: {err}; {debug}", file=sys.stderr, flush=True)

    def _print_report(self, tag: str) -> None:
        elapsed = max(time.monotonic() - self.stats.start_s, 1e-9)
        fps = self.stats.frames_sent / elapsed
        mbps_in = (self.stats.bytes_in * 8.0) / elapsed / 1_000_000.0
        if self.args.source_mode == "synthetic":
            print(
                f"[rtp-camera][{tag}] source=synthetic elapsed_s={elapsed:.3f} "
                f"target={self.args.width}x{self.args.height}@{self.args.fps:g} "
                f"bitrate_kbps={self.args.bitrate_kbps} "
                f"dst={self.args.dst_ip}:{self.args.dst_port} bind={self.args.bind_ip or 'auto'}",
                flush=True,
            )
        else:
            print(
                f"[rtp-camera][{tag}] frames_in={self.stats.frames_in} "
                f"frames_sent={self.stats.frames_sent} dropped={self.stats.frames_dropped} "
                f"elapsed_s={elapsed:.3f} fps_sent={fps:.2f} raw_in_mbps={mbps_in:.2f} "
                f"dst={self.args.dst_ip}:{self.args.dst_port} bind={self.args.bind_ip or 'auto'}",
                flush=True,
            )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Bridge video traffic to RTP/H.264 over UDP")
    parser.add_argument(
        "--source-mode",
        choices=["synthetic", "camera"],
        default="synthetic",
        help="Video source. synthetic preserves network background load without Gazebo camera rendering.",
    )
    parser.add_argument("--topic", default="", help="Gazebo camera image topic; required for --source-mode camera")
    parser.add_argument("--dst-ip", required=True, help="Destination IP, usually GS experiment IP")
    parser.add_argument("--dst-port", type=int, required=True, help="Destination UDP port")
    parser.add_argument("--bind-ip", default="", help="Source IP to bind, usually UAV experiment IP")
    parser.add_argument("--bitrate-kbps", type=int, default=4000, help="H.264 target bitrate")
    parser.add_argument("--fps", type=float, default=30.0, help="Input/output frame rate")
    parser.add_argument(
        "--keyframe-interval-sec",
        type=float,
        default=1.0,
        help="Target keyframe interval in seconds; lower values reduce receiver switch latency. Default: 1.0",
    )
    parser.add_argument(
        "--encoder",
        default="auto",
        help=(
            "H.264 encoder: auto (default, hardware first then software), hard "
            "(hardware only), nvautogpuh264enc, nvh264enc/nvenc, nvcudah264enc, "
            "vah264enc/va, vaapih264enc/vaapi, v4l2h264enc/v4l2, openh264enc, or x264"
        ),
    )
    parser.add_argument("--width", type=int, default=1280, help="Synthetic stream width")
    parser.add_argument("--height", type=int, default=720, help="Synthetic stream height")
    parser.add_argument("--output-width", type=int, default=0, help="Camera output width; 0 keeps source width")
    parser.add_argument("--output-height", type=int, default=0, help="Camera output height; 0 keeps source height")
    parser.add_argument("--pattern", default="ball", help="GStreamer videotestsrc pattern for synthetic mode")
    parser.add_argument("--mtu", type=int, default=1200, help="RTP packet MTU")
    parser.add_argument("--duration-sec", type=float, default=0.0, help="Stop after this many seconds; 0 means until signal")
    parser.add_argument("--report-sec", type=float, default=1.0, help="Periodic report interval")
    parser.add_argument("--print-pipeline", action="store_true", help="Print GStreamer pipeline before streaming")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    bridge = RtpCameraBridge(args)

    def handle_signal(_signum: int, _frame: object) -> None:
        bridge.stop_event.set()

    signal.signal(signal.SIGINT, handle_signal)
    signal.signal(signal.SIGTERM, handle_signal)

    bridge.start()
    return bridge.wait()


if __name__ == "__main__":
    raise SystemExit(main())
