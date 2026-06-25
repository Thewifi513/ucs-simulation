#!/usr/bin/env python3
import argparse
import json
import math
import mmap
import os
import re
import signal
import struct
import subprocess
import sys
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional, Tuple

SHM_MAGIC = b"UCSMSH01"
SHM_VERSION = 1
SHM_HEADER = struct.Struct("<8sIIQd")
SHM_RECORD = struct.Struct("<64s8dBB6x")

try:
    from gz.transport13 import Node as GzNode  # type: ignore
    from gz.msgs10.clock_pb2 import Clock as GzClock  # type: ignore
    from gz.msgs10.pose_v_pb2 import Pose_V as GzPoseV  # type: ignore

    GZ_PYTHON_IMPORT_ERROR = ""
except Exception as exc:  # pragma: no cover - depends on host Gazebo packages
    GzNode = None  # type: ignore
    GzClock = None  # type: ignore
    GzPoseV = None  # type: ignore
    GZ_PYTHON_IMPORT_ERROR = str(exc)


@dataclass
class PoseSample:
    x: float
    y: float
    z: float
    t: float


@dataclass
class ModelState:
    prev: Optional[PoseSample] = None
    curr: Optional[PoseSample] = None

    def update(self, sample: PoseSample) -> None:
        self.prev = self.curr
        self.curr = sample

    def speed(self) -> float:
        vx, vy, vz = self.velocity()
        return math.sqrt(vx * vx + vy * vy + vz * vz)

    def velocity(self) -> Tuple[float, float, float]:
        if self.prev is None or self.curr is None:
            return (0.0, 0.0, 0.0)
        dt = self.curr.t - self.prev.t
        if dt <= 0.0:
            return (0.0, 0.0, 0.0)
        dx = self.curr.x - self.prev.x
        dy = self.curr.y - self.prev.y
        dz = self.curr.z - self.prev.z
        return (dx / dt, dy / dt, dz / dt)

    def dist_to(self, gx: float, gy: float, gz: float) -> float:
        if self.curr is None:
            return 0.0
        dx = self.curr.x - gx
        dy = self.curr.y - gy
        dz = self.curr.z - gz
        return math.sqrt(dx * dx + dy * dy + dz * dz)

    def dist_to_state(self, other: "ModelState") -> float:
        if self.curr is None or other.curr is None:
            return 0.0
        dx = self.curr.x - other.curr.x
        dy = self.curr.y - other.curr.y
        dz = self.curr.z - other.curr.z
        return math.sqrt(dx * dx + dy * dy + dz * dz)

    def position(self) -> Optional[Tuple[float, float, float]]:
        if self.curr is None:
            return None
        return (self.curr.x, self.curr.y, self.curr.z)


@dataclass
class LinkMetric:
    speed: float
    distance: float
    src_pos: Tuple[float, float, float]
    dst_pos: Tuple[float, float, float]
    valid: bool
    model_seen: bool


class Worker:
    def __init__(self, runtime_file: str, verbose: bool = False, once: bool = False):
        self.runtime_file = runtime_file
        self.verbose = verbose
        self.once = once

        with open(runtime_file, "r", encoding="utf-8") as f:
            self.runtime = json.load(f)

        self.scenario_id = self.runtime["scenario_id"]
        self.world = self.runtime["world"]
        self.gz_partition = self.runtime["gz_partition"]
        self.gz_ip = self.runtime["gz_ip"]
        self.time_file = self.runtime["time_file"]
        self.tick_ms = int(self.runtime["tick_ms"])
        self.tick_sec = self.tick_ms / 1000.0
        self.metrics_channel = str(self.runtime.get("metrics_channel", "files"))
        self.shared_metrics_file = str(self.runtime.get("shared_metrics_file", ""))
        self.legacy_file_tick_ms = int(self.runtime.get("legacy_file_tick_ms", self.tick_ms))
        self.legacy_file_tick_sec = max(0.001, self.legacy_file_tick_ms / 1000.0)

        gs_pose = self.runtime["gs_pose"]
        self.gs_x = float(gs_pose["x"])
        self.gs_y = float(gs_pose["y"])
        self.gs_z = float(gs_pose["z"])

        self.links: List[dict] = self.runtime["links"]
        self.link_simulation = self.runtime.get("link_simulation", {})
        if not isinstance(self.link_simulation, dict):
            self.link_simulation = {}
        self.link_simulation_enabled = bool(self.link_simulation.get("enabled", False))
        self.model_states: Dict[str, ModelState] = {}
        self.latest_sim_time: Optional[float] = None
        self.lock = threading.Lock()
        self.stop_event = threading.Event()
        self.warned_missing_models: set[str] = set()

        self.clock_proc: Optional[subprocess.Popen] = None
        self.pose_proc: Optional[subprocess.Popen] = None
        self.gz_node = None
        self.gz_topics: List[str] = []
        self.threads: List[threading.Thread] = []
        self.shared_seq = 0
        self.shared_mmap: Optional[mmap.mmap] = None
        self.shared_fd: Optional[int] = None
        self.shared_size = 0
        self.shared_warning_logged = False

        self._setup_signal_handlers()

    def log(self, msg: str) -> None:
        print(f"[metrics_worker] {msg}", flush=True)

    def vlog(self, msg: str) -> None:
        if self.verbose:
            self.log(msg)

    def _setup_signal_handlers(self) -> None:
        def _handler(signum, _frame):
            self.log(f"received signal {signum}, stopping ...")
            self.stop_event.set()

        signal.signal(signal.SIGINT, _handler)
        signal.signal(signal.SIGTERM, _handler)

    def _popen(self, cmd: List[str]) -> subprocess.Popen:
        env = os.environ.copy()
        env["GZ_PARTITION"] = self.gz_partition
        env["GZ_IP"] = self.gz_ip
        self.vlog("exec: " + " ".join(cmd))
        return subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            stdin=subprocess.DEVNULL,
            text=True,
            bufsize=1,
            env=env,
        )

    @staticmethod
    def _atomic_write(path: str, content: str) -> None:
        p = Path(path)
        p.parent.mkdir(parents=True, exist_ok=True)
        tmp = p.with_name(p.name + ".tmp")
        tmp.write_text(content, encoding="utf-8")
        os.replace(tmp, p)

    @staticmethod
    def _message_blocks(stream) -> List[str]:
        blocks: List[str] = []
        buf: List[str] = []
        depth = 0
        started = False

        while True:
            line = stream.readline()
            if line == "":
                if buf:
                    blocks.append("".join(buf))
                break

            if not started and not line.strip():
                continue

            started = True
            buf.append(line)
            depth += line.count("{") - line.count("}")

            if started and depth <= 0 and any(ch in line for ch in ("}", '"', ":")):
                blocks.append("".join(buf))
                buf = []
                depth = 0
                started = False

        return blocks

    @staticmethod
    def _stream_message_iter(stream):
        buf: List[str] = []
        depth = 0
        started = False

        while True:
            line = stream.readline()
            if line == "":
                if buf:
                    yield "".join(buf)
                return

            if not started and not line.strip():
                continue

            started = True
            buf.append(line)
            depth += line.count("{") - line.count("}")

            if started and depth <= 0 and any(ch in line for ch in ("}", '"', ":")):
                yield "".join(buf)
                buf = []
                depth = 0
                started = False

    @staticmethod
    def _extract_named_blocks(text: str, field_name: str) -> List[str]:
        blocks: List[str] = []
        pattern = re.compile(rf"\b{re.escape(field_name)}\s*\{{")
        pos = 0

        while True:
            m = pattern.search(text, pos)
            if not m:
                break

            brace_start = text.find("{", m.start())
            if brace_start < 0:
                break

            depth = 0
            end = None
            for i in range(brace_start, len(text)):
                ch = text[i]
                if ch == "{":
                    depth += 1
                elif ch == "}":
                    depth -= 1
                    if depth == 0:
                        end = i
                        break

            if end is None:
                break

            blocks.append(text[brace_start + 1:end])
            pos = end + 1

        return blocks

    @staticmethod
    def _parse_clock_msg(text: str) -> Optional[float]:
        m = re.search(
            r"sim\s*\{\s*sec:\s*(-?\d+)\s*nsec:\s*(-?\d+)\s*\}",
            text,
            flags=re.S,
        )
        if not m:
            return None
        sec = int(m.group(1))
        nsec = int(m.group(2))
        return sec + nsec / 1_000_000_000.0

    @classmethod
    def _parse_pose_msg(cls, text: str) -> Dict[str, Tuple[float, float, float]]:
        out: Dict[str, Tuple[float, float, float]] = {}
        for block in cls._extract_named_blocks(text, "pose"):
            name_m = re.search(r'name:\s*"([^"]+)"', block)
            if not name_m:
                continue
            name = name_m.group(1)

            pos_blocks = cls._extract_named_blocks(block, "position")
            if not pos_blocks:
                continue
            pos_text = pos_blocks[0]

            x_m = re.search(r"x:\s*([-+0-9.eE]+)", pos_text)
            y_m = re.search(r"y:\s*([-+0-9.eE]+)", pos_text)
            z_m = re.search(r"z:\s*([-+0-9.eE]+)", pos_text)
            if not (x_m and y_m and z_m):
                continue

            out[name] = (
                float(x_m.group(1)),
                float(y_m.group(1)),
                float(z_m.group(1)),
            )
        return out

    @staticmethod
    def _position_from_mapping(value: object) -> Tuple[float, float, float]:
        if not isinstance(value, dict):
            return (0.0, 0.0, 0.0)
        return (
            float(value.get("x", 0.0)),
            float(value.get("y", 0.0)),
            float(value.get("z", 0.0)),
        )

    def _link_endpoint_position(
        self,
        model_name: Optional[str],
        fallback: Tuple[float, float, float],
    ) -> Tuple[Tuple[float, float, float], bool]:
        if not model_name:
            return fallback, True
        state = self.model_states.get(model_name)
        if state is None or state.curr is None:
            return fallback, False
        pos = state.position()
        if pos is None:
            return fallback, False
        return pos, True

    @staticmethod
    def _distance_between(
        a: Tuple[float, float, float],
        b: Tuple[float, float, float],
    ) -> float:
        dx = a[0] - b[0]
        dy = a[1] - b[1]
        dz = a[2] - b[2]
        return math.sqrt(dx * dx + dy * dy + dz * dz)

    def _clock_reader(self) -> None:
        assert self.clock_proc is not None
        for block in self._stream_message_iter(self.clock_proc.stdout):
            if self.stop_event.is_set():
                break
            t = self._parse_clock_msg(block)
            if t is None:
                continue
            with self.lock:
                self.latest_sim_time = t

    def _pose_reader(self) -> None:
        assert self.pose_proc is not None
        for block in self._stream_message_iter(self.pose_proc.stdout):
            if self.stop_event.is_set():
                break

            poses = self._parse_pose_msg(block)
            if not poses:
                continue

            with self.lock:
                t = self.latest_sim_time
                if t is None:
                    continue

                for model_name, (x, y, z) in poses.items():
                    state = self.model_states.setdefault(model_name, ModelState())
                    state.update(PoseSample(x=x, y=y, z=z, t=t))

    def _stderr_reader(self, proc: subprocess.Popen, name: str) -> None:
        assert proc.stderr is not None
        for line in proc.stderr:
            if self.stop_event.is_set():
                break
            line = line.rstrip()
            if line:
                self.vlog(f"{name} stderr: {line}")

    def _clock_callback(self, msg) -> None:
        try:
            t = float(msg.sim.sec) + float(msg.sim.nsec) / 1_000_000_000.0
        except Exception as exc:
            self.vlog(f"clock callback parse failed: {exc}")
            return
        with self.lock:
            self.latest_sim_time = t

    def _pose_callback(self, msg) -> None:
        poses: Dict[str, Tuple[float, float, float]] = {}
        try:
            for pose in msg.pose:
                name = str(pose.name)
                if not name:
                    continue
                pos = pose.position
                poses[name] = (float(pos.x), float(pos.y), float(pos.z))
        except Exception as exc:
            self.vlog(f"pose callback parse failed: {exc}")
            return

        if not poses:
            return
        with self.lock:
            t = self.latest_sim_time
            if t is None:
                return
            for model_name, (x, y, z) in poses.items():
                state = self.model_states.setdefault(model_name, ModelState())
                state.update(PoseSample(x=x, y=y, z=z, t=t))

    def _link_metric(self, link: dict) -> LinkMetric:
        src_model = link.get("src_model_name")
        dst_model = link.get("dst_model_name")

        if src_model is None and dst_model is None:
            model_name = link.get("model_name")
            if model_name:
                src_model = None
                dst_model = model_name

        missing = []
        src_state = None
        dst_state = None
        if src_model:
            src_state = self.model_states.get(src_model)
            if src_state is None or src_state.curr is None:
                missing.append(src_model)
        if dst_model:
            dst_state = self.model_states.get(dst_model)
            if dst_state is None or dst_state.curr is None:
                missing.append(dst_model)

        if missing:
            warn_key = "|".join([link.get("link_id", ""), *missing])
            if self.verbose and warn_key not in self.warned_missing_models:
                self.vlog(
                    f"model not seen yet for {link.get('link_id')}: {', '.join(missing)}; using fallback positions"
                )
                self.warned_missing_models.add(warn_key)

        src_fallback = self._position_from_mapping(link.get("src_fallback_pos"))
        dst_fallback = self._position_from_mapping(link.get("dst_fallback_pos"))
        src_pos, src_seen = self._link_endpoint_position(src_model, src_fallback)
        dst_pos, dst_seen = self._link_endpoint_position(dst_model, dst_fallback)
        model_seen = src_seen and dst_seen
        dist = self._distance_between(src_pos, dst_pos)

        speed = 0.0
        if model_seen:
            if src_state is None and dst_state is not None:
                speed = dst_state.speed()
            elif dst_state is None and src_state is not None:
                speed = src_state.speed()
            elif src_state is not None and dst_state is not None:
                svx, svy, svz = src_state.velocity()
                dvx, dvy, dvz = dst_state.velocity()
                rvx = dvx - svx
                rvy = dvy - svy
                rvz = dvz - svz
                speed = math.sqrt(rvx * rvx + rvy * rvy + rvz * rvz)

        return LinkMetric(speed, dist, src_pos, dst_pos, model_seen, model_seen)

    def _write_outputs_once(self) -> None:
        self._write_outputs(write_legacy_files=True)

    def _collect_metrics_locked(self) -> Tuple[float, List[Tuple[dict, LinkMetric]]]:
        sim_time = 0.0 if self.latest_sim_time is None else self.latest_sim_time
        metrics = [(link, self._link_metric(link)) for link in self.links]
        return sim_time, metrics

    def _open_shared_metrics(self) -> bool:
        if self.metrics_channel != "shm" or not self.shared_metrics_file:
            return False
        if self.shared_mmap is not None:
            return True

        self.shared_size = SHM_HEADER.size + len(self.links) * SHM_RECORD.size
        try:
            Path(self.shared_metrics_file).parent.mkdir(parents=True, exist_ok=True)
            self.shared_fd = os.open(self.shared_metrics_file, os.O_CREAT | os.O_RDWR, 0o666)
            os.ftruncate(self.shared_fd, self.shared_size)
            self.shared_mmap = mmap.mmap(self.shared_fd, self.shared_size, access=mmap.ACCESS_WRITE)
            self.log(f"shared_metrics_file={self.shared_metrics_file} size={self.shared_size}")
            return True
        except OSError as exc:
            if not self.shared_warning_logged:
                self.log(f"warning: shared metrics channel unavailable: {exc}")
                self.shared_warning_logged = True
            self._close_shared_metrics()
            return False

    def _close_shared_metrics(self) -> None:
        if self.shared_mmap is not None:
            self.shared_mmap.close()
            self.shared_mmap = None
        if self.shared_fd is not None:
            os.close(self.shared_fd)
            self.shared_fd = None

    def _write_shared_metrics(self, sim_time: float, metrics: List[Tuple[dict, LinkMetric]]) -> None:
        if not self._open_shared_metrics() or self.shared_mmap is None:
            return

        if len(metrics) != len(self.links):
            return

        odd_seq = self.shared_seq + 1
        even_seq = self.shared_seq + 2
        self.shared_mmap[0:SHM_HEADER.size] = SHM_HEADER.pack(
            SHM_MAGIC, SHM_VERSION, len(metrics), odd_seq, sim_time
        )

        offset = SHM_HEADER.size
        for link, metric in metrics:
            link_id = str(link.get("link_id", "")).encode("utf-8", errors="replace")[:63]
            link_id = link_id + (b"\0" * (64 - len(link_id)))
            self.shared_mmap[offset:offset + SHM_RECORD.size] = SHM_RECORD.pack(
                link_id,
                metric.speed,
                metric.distance,
                metric.src_pos[0],
                metric.src_pos[1],
                metric.src_pos[2],
                metric.dst_pos[0],
                metric.dst_pos[1],
                metric.dst_pos[2],
                1 if metric.valid else 0,
                1 if metric.model_seen else 0,
            )
            offset += SHM_RECORD.size

        self.shared_mmap[0:SHM_HEADER.size] = SHM_HEADER.pack(
            SHM_MAGIC, SHM_VERSION, len(metrics), even_seq, sim_time
        )
        self.shared_seq = even_seq

    def _write_legacy_files(self, sim_time: float, metrics: List[Tuple[dict, LinkMetric]]) -> None:
        self._atomic_write(self.time_file, f"{sim_time:.6f}\n")

        for link, metric in metrics:
            metrics_file = link["metrics_file"]
            self._atomic_write(
                metrics_file,
                (
                    f"{metric.speed:.6f} {metric.distance:.6f} "
                    f"{metric.src_pos[0]:.6f} {metric.src_pos[1]:.6f} {metric.src_pos[2]:.6f} "
                    f"{metric.dst_pos[0]:.6f} {metric.dst_pos[1]:.6f} {metric.dst_pos[2]:.6f} "
                    f"{1 if metric.valid else 0} {1 if metric.model_seen else 0}\n"
                ),
            )

    def _write_outputs(self, write_legacy_files: bool) -> None:
        with self.lock:
            sim_time, metrics = self._collect_metrics_locked()

        self._write_shared_metrics(sim_time, metrics)
        if write_legacy_files:
            self._write_legacy_files(sim_time, metrics)

    def _have_initial_samples(self) -> bool:
        with self.lock:
            if self.latest_sim_time is None:
                return False
            return any(state.curr is not None for state in self.model_states.values())

    def _wait_initial_samples(self) -> bool:
        deadline = time.monotonic() + max(2.0, self.tick_sec * 5.0)
        while not self.stop_event.is_set() and time.monotonic() < deadline:
            if self._have_initial_samples():
                return True
            time.sleep(0.05)
        return self._have_initial_samples()

    def _start_python_subscribers(self) -> bool:
        if GzNode is None or GzClock is None or GzPoseV is None:
            self.vlog(f"python Gazebo transport unavailable: {GZ_PYTHON_IMPORT_ERROR}")
            return False

        os.environ["GZ_PARTITION"] = self.gz_partition
        os.environ["GZ_IP"] = self.gz_ip
        clock_topic = "/clock"
        pose_topic = f"/world/{self.world}/dynamic_pose/info"

        try:
            self.gz_node = GzNode()
            clock_ok = self.gz_node.subscribe(GzClock, clock_topic, self._clock_callback)
            pose_ok = self.gz_node.subscribe(GzPoseV, pose_topic, self._pose_callback)
        except Exception as exc:
            self.log(f"python Gazebo transport failed; falling back to gz topic CLI: {exc}")
            self.gz_node = None
            return False

        if not (clock_ok and pose_ok):
            self.log(
                "python Gazebo transport subscribe failed; falling back to gz topic CLI "
                f"(clock={clock_ok} pose={pose_ok})"
            )
            self.gz_node = None
            return False

        self.gz_topics = [clock_topic, pose_topic]
        self.log("subscriber_backend=python_transport")
        return True

    def _start_cli_subscribers(self) -> None:
        self.clock_proc = self._popen(["gz", "topic", "-e", "-t", "/clock"])
        self.pose_proc = self._popen(["gz", "topic", "-e", "-t", f"/world/{self.world}/dynamic_pose/info"])

        self.threads = [
            threading.Thread(target=self._clock_reader, daemon=True),
            threading.Thread(target=self._pose_reader, daemon=True),
            threading.Thread(target=self._stderr_reader, args=(self.clock_proc, "clock"), daemon=True),
            threading.Thread(target=self._stderr_reader, args=(self.pose_proc, "pose"), daemon=True),
        ]
        for th in self.threads:
            th.start()
        self.log("subscriber_backend=gz_topic_cli")

    def _start_subscribers(self) -> None:
        if self._start_python_subscribers():
            return
        self._start_cli_subscribers()

    def _stop_subprocesses(self) -> None:
        if self.gz_node is not None:
            for topic in self.gz_topics:
                try:
                    self.gz_node.unsubscribe(topic)
                except Exception as exc:
                    self.vlog(f"unsubscribe failed for {topic}: {exc}")
            self.gz_node = None
        for proc in (self.clock_proc, self.pose_proc):
            if proc is None:
                continue
            if proc.poll() is None:
                proc.terminate()
        time.sleep(0.2)
        for proc in (self.clock_proc, self.pose_proc):
            if proc is None:
                continue
            if proc.poll() is None:
                proc.kill()

    def run(self) -> int:
        self.log(f"scenario={self.scenario_id}")
        self.log(f"world={self.world}")
        self.log(f"GZ_PARTITION={self.gz_partition}")
        self.log(f"GZ_IP={self.gz_ip}")
        self.log(f"time_file={self.time_file}")
        self.log(f"tick_ms={self.tick_ms}")
        self.log(f"metrics_channel={self.metrics_channel}")
        if self.metrics_channel == "shm":
            self.log(f"legacy_file_tick_ms={self.legacy_file_tick_ms}")
        if self.link_simulation_enabled:
            obstacles = self.link_simulation.get("obstacles", [])
            obstacle_count = len(obstacles) if isinstance(obstacles, list) else 0
            self.log(
                "link_simulation=model:%s output:speed_distance_endpoint_positions obstacles:%d"
                % (self.link_simulation.get("model", "ns3_buildings_pathloss"), obstacle_count)
            )
        for link in self.links:
            src_model = link.get("src_model_name") or "ground"
            dst_model = link.get("dst_model_name") or "ground"
            self.log(
                f"link {link['link_id']}: {link.get('src')}({src_model}) -> {link.get('dst')}({dst_model}) -> {link['metrics_file']}"
            )

        self._start_subscribers()
        if not self._wait_initial_samples():
            self.log("warning: no initial Gazebo clock/pose sample before first metrics write")

        next_ts = time.monotonic()
        next_legacy_ts = 0.0
        try:
            while not self.stop_event.is_set():
                now = time.monotonic()
                if now < next_ts:
                    time.sleep(min(0.05, next_ts - now))
                    continue

                write_legacy = self.once or now >= next_legacy_ts
                self._write_outputs(write_legacy_files=write_legacy)
                if self.once:
                    break
                if write_legacy:
                    next_legacy_ts = now + self.legacy_file_tick_sec

                next_ts += self.tick_sec
                if next_ts < time.monotonic():
                    next_ts = time.monotonic() + self.tick_sec

            return 0
        finally:
            self._stop_subprocesses()
            self._close_shared_metrics()


def parse_args() -> argparse.Namespace:
    ap = argparse.ArgumentParser(description="UCS fleet metrics worker")
    ap.add_argument("--runtime-file", required=True, help="Resolved runtime JSON file")
    ap.add_argument("--verbose", action="store_true", help="Verbose output")
    ap.add_argument("--once", action="store_true", help="Run one write cycle and exit")
    return ap.parse_args()


def main() -> int:
    args = parse_args()
    worker = Worker(runtime_file=args.runtime_file, verbose=args.verbose, once=args.once)
    return worker.run()


if __name__ == "__main__":
    sys.exit(main())
