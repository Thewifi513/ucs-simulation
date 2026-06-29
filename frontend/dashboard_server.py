#!/usr/bin/env python3
"""HTTP dashboard for the BMv2 six-UAV mesh stage."""

from __future__ import annotations

import argparse
import contextlib
import ipaddress
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
from http import HTTPStatus
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Tuple
from urllib.parse import parse_qs, urlparse


SCRIPT_DIR = Path(__file__).resolve().parent
MESH_DIR = SCRIPT_DIR.parent
DEFAULT_TOPOLOGY = MESH_DIR / "topology" / "wifi_adhoc_matrix_2x3_6uav.json"
DASHBOARD_DIR = SCRIPT_DIR
RTP_CAPS = "application/x-rtp,media=video,clock-rate=90000,encoding-name=H264,payload=96"
LOG_LINE_RE = re.compile(r"\[(?:pair-link|link)\]\s+(.*)")
WIFI_LINE_RE = re.compile(r"\[wifi\]\s+(.*)")
FIELD_RE = re.compile(r"(\w+)=([^\s]+)")
GST_STAT_RE = re.compile(r"([A-Za-z0-9_-]+)=\([^)]*\)([-+]?\d+(?:\.\d+)?)")
LINK_SHM_MAGIC = b"UCSLNK01"
LINK_SHM_VERSION = 1
LINK_SHM_HEADER = struct.Struct("<8sIIQddII16s")
LINK_SHM_MAX_AGE_SEC = 5.0
DASHBOARD_VIDEO_IDLE_SEC = 30.0
DASHBOARD_VIDEO_SENDER_IDLE_SEC = 45.0
RTP_CAMERA_FLOW_SH = MESH_DIR / "video" / "run_rtp_camera_flow.sh"

try:
    import gi  # type: ignore

    gi.require_version("Gst", "1.0")
    from gi.repository import Gst  # type: ignore

    Gst.init(None)
    GST_AVAILABLE = True
    GST_ERROR = ""
except Exception as exc:  # pragma: no cover - depends on host packages
    Gst = None  # type: ignore
    GST_AVAILABLE = False
    GST_ERROR = str(exc)


def parse_float(value: Any, default: float = math.nan) -> float:
    try:
        if value is None:
            return default
        return float(value)
    except (TypeError, ValueError):
        return default


def parse_int(value: Any, default: int = 0) -> int:
    try:
        if value is None:
            return default
        return int(float(value))
    except (TypeError, ValueError):
        return default


def parse_bool(value: Any, default: bool = False) -> bool:
    if value is None:
        return default
    text = str(value).strip().lower()
    if text in {"1", "true", "yes", "on"}:
        return True
    if text in {"0", "false", "no", "off"}:
        return False
    return default


def gst_bool(value: bool) -> str:
    return "true" if value else "false"


def gst_has_factory(factory: str) -> bool:
    return bool(GST_AVAILABLE and Gst.ElementFactory.find(factory) is not None)


def link_model_label(link_sim: Dict[str, Any], impairment_policy: str = "") -> str:
    display = str(link_sim.get("display_name") or "").strip()
    if display:
        return display
    model = str(link_sim.get("model") or "")
    if model == "large_small_fading_v1" and impairment_policy == "ns3_wifi_ad_hoc":
        return "geometry-aware matrix + native ns-3 Wi-Fi ad-hoc"
    if model == "large_small_fading_v1" and impairment_policy == "ns3_pairwise_links":
        return "geometry-aware isolated pairwise L2 impairment"
    if model == "large_small_fading_v1":
        return str(link_sim.get("display_name") or "protocol-stack-aware UAV link and traffic impairment model")
    if model == "ns3_buildings_pathloss":
        return "ns-3 Buildings pathloss"
    return model


def loss_model_label(value: str) -> str:
    labels = {
        "large_small_fading_v1": "geometry-aware statistical",
        "receiver_sensitivity_bler_v1": "receiver-sensitivity PER",
        "phy_single_attempt": "PHY single-attempt",
        "l2_arq_state_machine_v1": "MAC ARQ state machine",
        "mcs_bler_v1": "receiver-sensitivity PER",
        "snr_packet_error_v1": "SNR packet-error",
        "linear_rx_threshold_v1": "linear Rx threshold",
        "mac_retry": "MAC retry",
        "matrix_large_small_fading_v1": "matrix fading",
        "ns3_wifi_ad_hoc": "native ns-3 Wi-Fi ad-hoc",
        "ns3_pairwise_links": "isolated ns-3 pairwise links",
        "native_wifi_phy_mac": "native Wi-Fi PHY/MAC",
        "distance_linear": "distance-linear fallback",
    }
    parts = [part for part in str(value or "").split("/") if part]
    if not parts:
        return ""
    return " / ".join(labels.get(part, part) for part in parts)


def ip_only(value: str) -> str:
    if "/" in value:
        return str(ipaddress.ip_interface(value).ip)
    return str(ipaddress.ip_address(value))


def read_json(path: Path) -> Dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def read_text(path: Path) -> Optional[str]:
    try:
        return path.read_text(encoding="utf-8").strip()
    except OSError:
        return None


def newest_existing(paths: Iterable[str]) -> Optional[str]:
    files = [p for p in paths if os.path.isfile(p)]
    if not files:
        return None
    return max(files, key=os.path.getmtime)


def sanitize_for_path(value: str) -> str:
    safe = re.sub(r"[^A-Za-z0-9_.-]", "_", value)
    return safe or "default"


def parse_link_line(line: str) -> Optional[Dict[str, str]]:
    match = LOG_LINE_RE.search(line)
    if not match:
        return None
    fields = dict(FIELD_RE.findall(match.group(1)))
    return fields if "id" in fields else None


def parse_wifi_line(line: str) -> Optional[Dict[str, str]]:
    match = WIFI_LINE_RE.search(line)
    if not match:
        return None
    fields = dict(FIELD_RE.findall(match.group(1)))
    return fields if "endpoint" in fields else None


def parse_link_snapshot_text(
    text: str,
    source: str,
) -> Tuple[Dict[str, Dict[str, str]], Dict[str, Dict[str, str]]]:
    last_by_id: Dict[str, Dict[str, str]] = {}
    last_wifi_by_endpoint: Dict[str, Dict[str, str]] = {}
    for line in text.splitlines():
        fields = parse_link_line(line)
        if fields and fields.get("id"):
            fields["_source"] = source
            last_by_id[str(fields["id"])] = fields
        wifi_fields = parse_wifi_line(line)
        if wifi_fields and wifi_fields.get("endpoint"):
            wifi_fields["_source"] = source
            last_wifi_by_endpoint[str(wifi_fields["endpoint"])] = wifi_fields
    return last_by_id, last_wifi_by_endpoint


def read_link_state_shm(
    scenario_id: str,
    max_age_sec: float = LINK_SHM_MAX_AGE_SEC,
) -> Tuple[Optional[str], Dict[str, Dict[str, str]], Dict[str, Dict[str, str]]]:
    path = f"/dev/shm/ucs_mesh_link_state_{sanitize_for_path(scenario_id)}.bin"
    if not os.path.isfile(path):
        return None, {}, {}

    try:
        with open(path, "rb") as handle:
            size = os.fstat(handle.fileno()).st_size
            if size < LINK_SHM_HEADER.size:
                return path, {}, {}
            with mmap.mmap(handle.fileno(), 0, access=mmap.ACCESS_READ) as mapped:
                for _ in range(3):
                    first = LINK_SHM_HEADER.unpack(mapped[:LINK_SHM_HEADER.size])
                    (
                        magic,
                        version,
                        payload_bytes,
                        seq,
                        _sim_time,
                        wall_time,
                        used_bytes,
                        _line_count,
                        _reserved,
                    ) = first
                    if (
                        magic != LINK_SHM_MAGIC
                        or version != LINK_SHM_VERSION
                        or seq & 1
                        or payload_bytes <= 0
                        or used_bytes > payload_bytes
                        or LINK_SHM_HEADER.size + used_bytes > size
                    ):
                        return path, {}, {}

                    payload = bytes(
                        mapped[LINK_SHM_HEADER.size:LINK_SHM_HEADER.size + used_bytes]
                    )
                    second = LINK_SHM_HEADER.unpack(mapped[:LINK_SHM_HEADER.size])
                    if first == second and not (second[3] & 1):
                        if math.isfinite(wall_time) and wall_time > 0:
                            if time.time() - wall_time > max_age_sec:
                                return path, {}, {}
                        text = payload.decode("utf-8", errors="replace")
                        links, wifi = parse_link_snapshot_text(text, "ns3_shm")
                        return path, links, wifi
                    time.sleep(0.001)
    except OSError:
        return path, {}, {}
    return path, {}, {}


def read_recent_link_log(
    scenario_id: str,
    max_bytes: int = 4 * 1024 * 1024,
) -> Tuple[Optional[str], Dict[str, Dict[str, str]], Dict[str, Dict[str, str]]]:
    shm_path, shm_links, shm_wifi = read_link_state_shm(scenario_id)
    if shm_links or shm_wifi:
        return shm_path, shm_links, shm_wifi

    candidates = [
        f"/tmp/ucs_mesh_ns3_{scenario_id}.launcher.log",
        f"/tmp/ucs_mesh_ns3_{scenario_id}.log",
    ]
    log_path = newest_existing(candidates)
    if not log_path:
        return None, {}, {}

    last_by_id: Dict[str, Dict[str, str]] = {}
    last_wifi_by_endpoint: Dict[str, Dict[str, str]] = {}
    try:
        with open(log_path, "rb") as handle:
            handle.seek(0, os.SEEK_END)
            size = handle.tell()
            handle.seek(max(0, size - max_bytes), os.SEEK_SET)
            last_by_id, last_wifi_by_endpoint = parse_link_snapshot_text(
                handle.read().decode("utf-8", errors="replace"),
                "ns3_log",
            )
    except OSError:
        return log_path, {}, {}
    return log_path, last_by_id, last_wifi_by_endpoint


def parse_metrics_file(path: str) -> Dict[str, Any]:
    try:
        parts = Path(path).read_text(encoding="utf-8").strip().split()
    except OSError:
        return {"present": False}
    if len(parts) < 10:
        return {"present": True, "valid": False}
    values = [parse_float(part) for part in parts[:8]]
    return {
        "present": True,
        "speed_mps": values[0],
        "distance_m": values[1],
        "src_pos": {"x": values[2], "y": values[3], "z": values[4]},
        "dst_pos": {"x": values[5], "y": values[6], "z": values[7]},
        "valid": parse_int(parts[8]) == 1,
        "model_seen": parse_int(parts[9]) == 1,
        "mtime": Path(path).stat().st_mtime,
    }


def parse_wifi_stats(fields: Dict[str, str]) -> Dict[str, Any]:
    if not fields:
        return {}
    int_keys = {
        "mac_tx_packets",
        "mac_tx_bytes",
        "mac_rx_packets",
        "mac_rx_bytes",
        "mac_promisc_rx_packets",
        "mac_promisc_rx_bytes",
        "mac_tx_drop_packets",
        "mac_rx_drop_packets",
        "phy_tx_begin_packets",
        "phy_tx_begin_bytes",
        "phy_tx_end_packets",
        "phy_tx_drop_packets",
        "phy_rx_begin_packets",
        "phy_rx_begin_bytes",
        "phy_rx_end_packets",
        "phy_rx_end_bytes",
        "phy_rx_drop_packets",
        "acked_mpdu",
        "nacked_mpdu",
        "dropped_mpdu",
        "final_data_failed",
        "retry_limit_drops",
        "retry_count",
        "mpdu_response_timeout",
        "last_phy_rx_drop_reason",
        "last_response_timeout_reason",
    }
    stats: Dict[str, Any] = {
        "endpoint": fields.get("endpoint", ""),
        "source": str(fields.get("_source") or "ns3_log"),
        "last_mac_drop_reason": fields.get("last_mac_drop_reason", ""),
    }
    t = parse_float(fields.get("t"))
    stats["sim_time"] = None if not math.isfinite(t) else t
    for key in int_keys:
        stats[key] = parse_int(fields.get(key), 0)
    return stats


def command_output(args: List[str], timeout: float = 1.5) -> Tuple[int, str, str]:
    try:
        proc = subprocess.run(
            args,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
            check=False,
        )
        return proc.returncode, proc.stdout, proc.stderr
    except (OSError, subprocess.TimeoutExpired) as exc:
        return 127, "", str(exc)


def tcp_port_open(host: str, port: int, timeout: float = 0.2) -> bool:
    import socket

    sock = None
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(timeout)
        sock.connect((host, port))
        return True
    except OSError:
        return False
    finally:
        if sock is not None:
            sock.close()


def inspect_containers(instances: List[Dict[str, Any]]) -> Dict[str, Dict[str, Any]]:
    names = [str(inst.get("container_name") or inst.get("id")) for inst in instances if inst.get("type") == "uav"]
    result = {name: {"known": False, "running": False, "status": "unknown", "pid": 0} for name in names}
    if not names:
        return result
    code, stdout, stderr = command_output(
        ["docker", "inspect", "-f", "{{.Name}}\t{{.State.Running}}\t{{.State.Status}}\t{{.State.Pid}}", *names],
        timeout=2.5,
    )
    if code != 0:
        for name in names:
            result[name]["error"] = stderr.strip() or stdout.strip() or "docker inspect failed"
        return result
    for line in stdout.splitlines():
        parts = line.split("\t")
        if len(parts) != 4:
            continue
        name = parts[0].lstrip("/")
        running = parts[1].lower() == "true"
        result[name] = {
            "known": True,
            "running": running,
            "status": parts[2],
            "pid": parse_int(parts[3]),
        }
    return result


def process_lines(pattern: str) -> List[str]:
    code, stdout, _ = command_output(["pgrep", "-af", pattern], timeout=1.0)
    if code not in {0, 1}:
        return []
    return [line for line in stdout.splitlines() if "frontend/dashboard_server.py" not in line]


def rtp_port_process_running(port: int) -> bool:
    needle_space = f"--dst-port {port}"
    needle_equal = f"--dst-port={port}"
    return any(
        needle_space in line or needle_equal in line
        for line in process_lines(r"rtp_camera_bridge\.py")
    )


def pid_alive(pidfile: Path) -> bool:
    raw = read_text(pidfile)
    if not raw:
        return False
    try:
        os.kill(int(raw), 0)
        return True
    except (OSError, ValueError):
        return False


def read_control_runtime(scenario_id: str, uav_id: str) -> Dict[str, Any]:
    runtime_file = Path(f"/tmp/ucs_mesh_control_{scenario_id}_{uav_id}.runtime.json")
    base: Dict[str, Any] = {
        "runtime_file": str(runtime_file),
        "present": False,
        "relay_port": None,
        "core_port": None,
        "mavsdk_server_port": None,
        "relay_open": False,
        "core_open": False,
        "mavsdk_server_open": False,
        "all_alive": False,
        "control_ws": "",
    }
    try:
        payload = read_json(runtime_file)
    except OSError:
        return base
    except json.JSONDecodeError as exc:
        base["error"] = str(exc)
        return base

    relay_port = parse_int(payload.get("relay_port"), 0)
    core_port = parse_int(payload.get("core_port"), 0)
    mavsdk_server_port = parse_int(payload.get("mavsdk_server_port"), 0)
    pidfiles = payload.get("pidfiles", {}) if isinstance(payload.get("pidfiles"), dict) else {}
    pid_alive_by_name = {
        name: pid_alive(Path(path))
        for name, path in pidfiles.items()
        if path
    }
    relay_pid_present = bool(pidfiles.get("remote_web"))
    if relay_pid_present:
        relay_open = bool(pid_alive_by_name.get("remote_web"))
    else:
        relay_open = relay_port > 0 and tcp_port_open("127.0.0.1", relay_port)
    core_open = core_port > 0 and tcp_port_open("127.0.0.1", core_port)
    mavsdk_open = mavsdk_server_port > 0 and tcp_port_open("127.0.0.1", mavsdk_server_port)
    base.update(
        {
            "present": True,
            "target_uav": payload.get("uav_id", uav_id),
            "run_dir": payload.get("run_dir"),
            "relay_port": relay_port or None,
            "core_port": core_port or None,
            "mavsdk_server_port": mavsdk_server_port or None,
            "mavsdk_url": payload.get("mavsdk_url"),
            "mavsdk_remote_port": payload.get("mavsdk_remote_port"),
            "relay_open": relay_open,
            "core_open": core_open,
            "mavsdk_server_open": mavsdk_open,
            "pid_alive": pid_alive_by_name,
            "all_alive": bool(relay_open and core_open and mavsdk_open),
            "control_ws": f"ws://127.0.0.1:{relay_port}" if relay_port else "",
            "updated_at": payload.get("updated_at"),
        }
    )
    return base


def camera_topic(topo: Dict[str, Any], inst: Dict[str, Any]) -> str:
    globals_ = topo.get("globals", {})
    payload = globals_.get("payload", {})
    world = globals_.get("px4_gz_world_name", "default")
    model = inst.get("model_name") or f"x500_gimbal_{int(inst.get('idx', 0)):02d}"
    camera_link = payload.get("camera_link", "camera_link")
    camera_sensor = payload.get("camera_sensor", "camera")
    return f"/world/{world}/model/{model}/link/{camera_link}/sensor/{camera_sensor}/image"


def video_flow_configs(topo: Dict[str, Any]) -> List[Dict[str, Any]]:
    business = topo.get("globals", {}).get("business_flows", {})
    if not isinstance(business, dict):
        return []
    result: List[Dict[str, Any]] = []
    for key in ("video", "video_main"):
        flow = business.get(key, {})
        if not isinstance(flow, dict) or not flow.get("enabled", False):
            continue
        if flow.get("encoding", "rtp_h264") != "rtp_h264":
            continue
        result.append(
            {
                "key": key,
                "label": str(flow.get("label") or flow.get("role") or key),
                "role": str(flow.get("role") or ("sub" if key == "video" else key)),
                "port_base": parse_int(flow.get("port_base"), 5600 if key == "video" else 5700),
                "resolution": str(flow.get("default_resolution", "")),
                "fps": parse_float(flow.get("default_fps"), math.nan),
                "bitrate_kbps": parse_int(flow.get("default_bitrate_kbps"), 0),
                "flow": flow,
            }
        )
    return result


def normalize_video_stream_key(stream: str) -> str:
    return {
        "sub": "video",
        "preview": "video",
        "dashboard": "video",
        "main": "video_main",
        "video_main": "video_main",
        "video": "video",
    }.get(stream.strip().lower(), stream.strip())


def resolve_video_request(topology_path: Path, uav_id: str, stream: str) -> Tuple[str, str, int, str]:
    topo = read_json(topology_path)
    globals_ = topo.get("globals", {})
    flows = globals_.get("business_flows", {})
    stream_key = normalize_video_stream_key(stream)
    video = flows.get(stream_key, {}) if isinstance(flows, dict) else {}
    if not isinstance(video, dict) or not video.get("enabled", False):
        raise ValueError(f"video stream is not enabled: {stream}")
    port_base = int(video.get("port_base", 5600))
    instances = topo.get("instances", [])
    gs_id = globals_.get("gs_id", "gs")
    gs = next((item for item in instances if item.get("id") == gs_id), None)
    if not gs:
        raise ValueError("ground station instance not found")
    address = ip_only(str(gs.get("exp_ip") or globals_.get("experiment_net", {}).get("gs_ips", [""])[0]))
    uav = next((item for item in instances if item.get("id") == uav_id), None)
    if not uav:
        raise ValueError(f"unknown UAV: {uav_id}")
    port = port_base + int(uav.get("idx", 0))
    return address, str(uav_id), port, stream_key


def mavsdk_endpoint(topo: Dict[str, Any], inst: Dict[str, Any], gs_ip: str) -> Dict[str, Any]:
    idx = int(inst.get("idx", 0))
    globals_ = topo.get("globals", {})
    business_flows = globals_.get("business_flows", {}) if isinstance(globals_, dict) else {}
    control_flow = business_flows.get("control", {}) if isinstance(business_flows, dict) else {}
    mavsdk_flow = control_flow.get("mavsdk", {}) if isinstance(control_flow, dict) else {}
    if not isinstance(mavsdk_flow, dict):
        mavsdk_flow = {}
    local_port = int(inst.get("mavsdk_local_port", int(mavsdk_flow.get("uav_local_port_base", 18600)) + idx))
    remote_port = int(inst.get("mavsdk_remote_port", int(mavsdk_flow.get("gs_remote_port_base", 14600)) + idx))
    remote_ip = str(inst.get("mavsdk_remote_ip") or mavsdk_flow.get("remote_ip") or gs_ip or "10.10.0.254")
    if remote_ip == "ground_station.exp_ip":
        remote_ip = gs_ip or "10.10.0.254"
    return {
        "local_port": local_port,
        "remote_ip": ip_only(remote_ip),
        "remote_port": remote_port,
        "url": str(inst.get("mavsdk_url") or f"udpin://0.0.0.0:{remote_port}"),
    }


def expected_control_ports(inst: Dict[str, Any]) -> Dict[str, int]:
    idx = int(inst.get("idx", 0))
    relay_base = parse_int(os.environ.get("CONTROL_RELAY_PORT_BASE"), 8770)
    core_base = parse_int(os.environ.get("CONTROL_CORE_PORT_BASE"), 9010)
    mavsdk_server_base = parse_int(os.environ.get("CONTROL_MAVSDK_SERVER_PORT_BASE"), 50100)
    return {
        "relay_port": relay_base + idx,
        "core_port": core_base + idx,
        "mavsdk_server_port": mavsdk_server_base + idx,
    }


def default_control_ws(topology_path: Path) -> str:
    relay_base = parse_int(os.environ.get("CONTROL_RELAY_PORT_BASE"), 8770)
    fallback = f"ws://127.0.0.1:{relay_base + 1}"
    try:
        topo = read_json(topology_path)
        uavs = [inst for inst in topo.get("instances", []) if inst.get("type") == "uav"]
        if not uavs:
            return fallback
        selected = next(
            (
                inst
                for inst in uavs
                if str(inst.get("id") or inst.get("name") or inst.get("container_name")) == "uav04"
            ),
            uavs[0],
        )
        return f"ws://127.0.0.1:{expected_control_ports(selected)['relay_port']}"
    except Exception:
        return fallback


def compute_link_quality(
    raw: Dict[str, Any],
    metric: Dict[str, Any],
    log_fields: Dict[str, str],
    *,
    native_wifi: bool = False,
) -> Dict[str, Any]:
    mac_delivery_loss = parse_float(log_fields.get("mac_delivery_loss"))
    mac_expected_drop = parse_float(log_fields.get("mac_expected_drop"))
    per = parse_float(
        log_fields.get("mac_expected_drop", log_fields.get("post_mac_drop")),
        parse_float(log_fields.get("per"), parse_float(log_fields.get("loss"))),
    )
    phy_per = parse_float(log_fields.get("phy_per"))
    raw_per = parse_float(log_fields.get("raw_per"))
    dist = parse_float(log_fields.get("dist"), metric.get("distance_m", math.nan))
    speed = parse_float(log_fields.get("speed"), metric.get("speed_mps", math.nan))
    rx_dbm = parse_float(log_fields.get("rx_dbm"))
    jitter_ms = parse_float(log_fields.get("jitter_ms"))
    retry_delay_ms = parse_float(log_fields.get("retry_delay_ms"))
    queue_delay_ms = parse_float(log_fields.get("queue_delay_ms"))
    busy_delay_ms = parse_float(log_fields.get("busy_delay_ms"))
    airtime_ms = parse_float(log_fields.get("airtime_ms"))
    queue_service_ms = parse_float(log_fields.get("queue_service_ms"), airtime_ms)
    queue_busy_ms = parse_float(log_fields.get("queue_busy_ms"), busy_delay_ms)
    delay_ms = parse_float(log_fields.get("delay_ms"))
    mac_retry_count_avg = parse_float(log_fields.get("mac_retry_count_avg"))
    path_loss_db = parse_float(log_fields.get("path_loss_db"))
    shadow_db = parse_float(log_fields.get("shadow_db"))
    obstruction_loss_db = parse_float(log_fields.get("obstruction_loss_db"))
    obstruction_raw_loss_db = parse_float(log_fields.get("obstruction_raw_loss_db"))
    multipath_db = parse_float(log_fields.get("multipath_db"))
    multipath_resampled = parse_int(log_fields.get("multipath_resampled"), 0) if log_fields else None
    dropped = parse_int(log_fields.get("dropped"), 0) if log_fields else None
    forwarded = parse_int(log_fields.get("forwarded"), 0) if log_fields else None
    mac_pending = parse_int(log_fields.get("mac_pending"), 0) if log_fields else None
    mac_delivered = parse_int(log_fields.get("mac_delivered"), 0) if log_fields else None
    mac_dropped = parse_int(log_fields.get("mac_dropped"), 0) if log_fields else None
    mac_phy_attempts = parse_int(log_fields.get("mac_phy_attempts"), 0) if log_fields else None
    queue_packets = parse_int(log_fields.get("queue_packets"), mac_pending or 0) if log_fields else None
    queue_bytes = parse_int(log_fields.get("queue_bytes"), 0) if log_fields else None
    queue_dropped = parse_int(log_fields.get("queue_dropped"), 0) if log_fields else None
    mac_drop_reason = str(log_fields.get("mac_drop_reason", "")) if log_fields else ""
    channel_state = str(log_fields.get("channel_state", "")) if log_fields else ""
    drop_authority = str(log_fields.get("drop_authority", "")) if log_fields else ""
    loss_model = str(log_fields.get("loss_model", "")) if log_fields else ""
    loss_delegated = (
        native_wifi
        or drop_authority == "ns3_wifi_phy_mac"
        or "ns3_wifi_ad_hoc" in loss_model
        or str(log_fields.get("legacy_loss", "")) == "delegated_to_ns3_wifi"
    )

    if loss_delegated:
        per = math.nan
        mac_delivery_loss = math.nan
        mac_expected_drop = math.nan
        phy_per = math.nan
        raw_per = math.nan
        mac_retry_count_avg = math.nan
        mac_drop_reason = mac_drop_reason or "delegated_to_ns3_wifi"
        drop_authority = drop_authority or "ns3_wifi_phy_mac"

    if not loss_delegated and not math.isfinite(per):
        dist_no_loss = parse_float(raw.get("dist_no_loss"), 50.0)
        dist_max = parse_float(raw.get("dist_max"), 500.0)
        loss_max = parse_float(raw.get("loss_max"), 0.3)
        if math.isfinite(dist) and dist_max > dist_no_loss:
            per = max(0.0, min(loss_max, (dist - dist_no_loss) / (dist_max - dist_no_loss) * loss_max))

    if not loss_delegated and not math.isfinite(phy_per):
        phy_per = per
    if not loss_delegated and not math.isfinite(raw_per):
        raw_per = phy_per

    if not metric.get("present") and not log_fields:
        status = "unknown"
    elif loss_delegated:
        status = "stale" if metric.get("valid") is False else "good"
    elif math.isfinite(per) and per >= 0.2:
        status = "bad"
    elif math.isfinite(per) and per >= 0.05:
        status = "warn"
    elif metric.get("valid") is False:
        status = "stale"
    else:
        status = "good"

    return {
        "status": status,
        "per": None if not math.isfinite(per) else per,
        "post_mac_drop": None if not math.isfinite(per) else per,
        "mac_delivery_loss": None if not math.isfinite(mac_delivery_loss) else mac_delivery_loss,
        "mac_expected_drop": None if not math.isfinite(mac_expected_drop) else mac_expected_drop,
        "phy_per": None if not math.isfinite(phy_per) else phy_per,
        "raw_per": None if not math.isfinite(raw_per) else raw_per,
        "distance_m": None if not math.isfinite(dist) else dist,
        "speed_mps": None if not math.isfinite(speed) else speed,
        "rx_dbm": None if not math.isfinite(rx_dbm) else rx_dbm,
        "jitter_ms": None if not math.isfinite(jitter_ms) else jitter_ms,
        "retry_delay_ms": None if not math.isfinite(retry_delay_ms) else retry_delay_ms,
        "queue_delay_ms": None if not math.isfinite(queue_delay_ms) else queue_delay_ms,
        "busy_delay_ms": None if not math.isfinite(busy_delay_ms) else busy_delay_ms,
        "airtime_ms": None if not math.isfinite(airtime_ms) else airtime_ms,
        "queue_service_ms": None if not math.isfinite(queue_service_ms) else queue_service_ms,
        "queue_busy_ms": None if not math.isfinite(queue_busy_ms) else queue_busy_ms,
        "delay_ms": None if not math.isfinite(delay_ms) else delay_ms,
        "mac_retry_count_avg": None if not math.isfinite(mac_retry_count_avg) else mac_retry_count_avg,
        "mac_drop_reason": mac_drop_reason,
        "drop_authority": drop_authority,
        "loss_delegated": loss_delegated,
        "mac_pending": None if loss_delegated else mac_pending,
        "mac_delivered": None if loss_delegated else mac_delivered,
        "mac_dropped": None if loss_delegated else mac_dropped,
        "mac_phy_attempts": None if loss_delegated else mac_phy_attempts,
        "queue_packets": None if loss_delegated else queue_packets,
        "queue_bytes": None if loss_delegated else queue_bytes,
        "queue_dropped": None if loss_delegated else queue_dropped,
        "channel_state": channel_state,
        "loss_model": loss_model,
        "loss_model_label": loss_model_label(loss_model) if log_fields else "",
        "path_loss_db": None if not math.isfinite(path_loss_db) else path_loss_db,
        "shadow_db": None if not math.isfinite(shadow_db) else shadow_db,
        "obstruction_loss_db": None if not math.isfinite(obstruction_loss_db) else obstruction_loss_db,
        "obstruction_raw_loss_db": None if not math.isfinite(obstruction_raw_loss_db) else obstruction_raw_loss_db,
        "multipath_db": None if not math.isfinite(multipath_db) else multipath_db,
        "multipath_resampled": multipath_resampled,
        "dropped": None if loss_delegated else dropped,
        "forwarded": None if loss_delegated else forwarded,
        "source": str(log_fields.get("_source") or "ns3_log")
        if log_fields
        else ("metrics" if metric.get("present") else "topology"),
    }


def build_state(topology_path: Path) -> Dict[str, Any]:
    topo = read_json(topology_path)
    globals_ = topo.get("globals", {})
    link_sim = globals_.get("link_simulation", {})
    experiment_net = globals_.get("experiment_net", {}) if isinstance(globals_, dict) else {}
    impairment_policy = (
        str(experiment_net.get("impairment_policy", ""))
        if isinstance(experiment_net, dict)
        else ""
    )
    native_wifi = impairment_policy == "ns3_wifi_ad_hoc"
    scenario_id = str(topo.get("scenario_id", "unknown"))
    instances = topo.get("instances", [])
    uavs = [inst for inst in instances if inst.get("type") == "uav"]
    gs_id = globals_.get("gs_id", "gs")
    programmable = topo.get("programmable_net", globals_.get("programmable_net", {}))
    programmable_routing = programmable.get("routing", {}) if isinstance(programmable, dict) else {}
    gs = next((inst for inst in instances if inst.get("id") == gs_id), None)
    gs_ip = ""
    if gs:
        gs_ip = ip_only(str(gs.get("exp_ip") or globals_.get("experiment_net", {}).get("gs_ips", [""])[0]))

    video = globals_.get("business_flows", {}).get("video", {})
    video_flows = video_flow_configs(topo)
    sub_video_flow = next((item for item in video_flows if item["key"] == "video"), None)
    main_video_flow = next((item for item in video_flows if item["key"] == "video_main"), None)
    video_port_base = int((sub_video_flow or {}).get("port_base", 5600))
    container_status = inspect_containers(instances)
    rtp_processes = process_lines(r"rtp_camera_bridge\.py|run_rtp_camera_flow\.sh")
    log_path, latest_link_fields, latest_wifi_fields = read_recent_link_log(scenario_id)

    all_links_raw = [link for link in topo.get("links", []) if link.get("enabled", True)]
    all_links_raw.extend(link for link in topo.get("mesh_links", []) if link.get("enabled", True))

    positions: Dict[str, Dict[str, Any]] = {}
    if isinstance(globals_.get("gs_pose"), dict):
        pose = globals_["gs_pose"]
        positions[str(gs_id)] = {
            "x": parse_float(pose.get("x"), 0.0),
            "y": parse_float(pose.get("y"), 0.0),
            "z": parse_float(pose.get("z"), 1.5),
            "source": "topology",
        }

    links: List[Dict[str, Any]] = []
    now = time.time()
    for raw in all_links_raw:
        link_id = str(raw.get("id", ""))
        metric = parse_metrics_file(str(raw.get("metrics_file", "")))
        if metric.get("present"):
            src = str(raw.get("src", ""))
            dst = str(raw.get("dst", ""))
            if isinstance(metric.get("src_pos"), dict):
                positions[src] = {**metric["src_pos"], "source": "metrics", "valid": metric.get("valid")}
            if isinstance(metric.get("dst_pos"), dict):
                positions[dst] = {**metric["dst_pos"], "source": "metrics", "valid": metric.get("valid")}
        log_fields = latest_link_fields.get(link_id, {})
        quality = compute_link_quality(raw, metric, log_fields, native_wifi=native_wifi)
        metric_age = None if not metric.get("mtime") else max(0.0, now - float(metric["mtime"]))
        if not log_fields and metric_age is not None and metric_age > 5.0:
            quality["status"] = "stale"
            quality["source"] = "stale_metrics"
        links.append(
            {
                "id": link_id,
                "src": raw.get("src"),
                "dst": raw.get("dst"),
                "type": raw.get("type"),
                "metrics_file": raw.get("metrics_file"),
                "metric_age_sec": metric_age,
                **quality,
            }
        )

    ui_positions = topo.get("ui", {}).get("node_positions", {})
    nodes: List[Dict[str, Any]] = []
    control_runtimes: List[Dict[str, Any]] = []
    for inst in instances:
        inst_id = str(inst.get("id") or inst.get("name"))
        pos = positions.get(inst_id, {})
        if not pos and isinstance(inst.get("spawn_pose"), dict):
            spawn = inst["spawn_pose"]
            pos = {
                "x": parse_float(spawn.get("x"), 0.0),
                "y": parse_float(spawn.get("y"), 0.0),
                "z": parse_float(spawn.get("z"), 0.0),
                "source": "spawn_pose",
            }
        if not pos and isinstance(ui_positions.get(inst_id), dict):
            pos = {
                "x": parse_float(ui_positions[inst_id].get("x"), 0.0) / 10.0,
                "y": parse_float(ui_positions[inst_id].get("y"), 0.0) / 10.0,
                "z": 0.0,
                "source": "ui",
            }

        node: Dict[str, Any] = {
            "id": inst_id,
            "type": inst.get("type"),
            "cluster_id": inst.get("cluster_id"),
            "exp_ip": inst.get("exp_ip"),
            "position": pos or None,
            "wifi_stats": parse_wifi_stats(latest_wifi_fields.get(inst_id, {})),
        }
        if inst.get("type") == "uav":
            idx = int(inst.get("idx", 0))
            container = str(inst.get("container_name") or inst_id)
            port = video_port_base + idx
            node_video_streams: List[Dict[str, Any]] = []
            for flow in video_flows:
                stream_port = int(flow["port_base"]) + idx
                running = any(
                    f"--dst-port {stream_port}" in line or f"--dst-port={stream_port}" in line
                    for line in rtp_processes
                )
                node_video_streams.append(
                    {
                        "key": flow["key"],
                        "label": flow["label"],
                        "role": flow["role"],
                        "port": stream_port,
                        "destination": f"{gs_ip}:{stream_port}" if gs_ip else f":{stream_port}",
                        "resolution": flow["resolution"],
                        "fps": flow["fps"],
                        "bitrate_kbps": flow["bitrate_kbps"],
                        "rtp_running": running,
                    }
                )
            sub_running = next((item["rtp_running"] for item in node_video_streams if item["key"] == "video"), False)
            main_port = int(main_video_flow["port_base"]) + idx if main_video_flow else None
            mavsdk = mavsdk_endpoint(topo, inst, gs_ip)
            control_runtime = read_control_runtime(scenario_id, inst_id)
            expected_control = expected_control_ports(inst)
            control_relay_port = control_runtime.get("relay_port") or expected_control["relay_port"]
            control_core_port = control_runtime.get("core_port") or expected_control["core_port"]
            control_mavsdk_server_port = (
                control_runtime.get("mavsdk_server_port") or expected_control["mavsdk_server_port"]
            )
            control_runtimes.append({"uav_id": inst_id, **control_runtime})
            node.update(
                {
                    "idx": idx,
                    "container": container,
                    "container_status": container_status.get(container, {}),
                    "qgc_port": inst.get("qgc_port"),
                    "mavsdk_local_port": mavsdk["local_port"],
                    "mavsdk_remote_ip": mavsdk["remote_ip"],
                    "mavsdk_remote_port": mavsdk["remote_port"],
                    "mavsdk_url": mavsdk["url"],
                    "model_name": inst.get("model_name"),
                    "video_port": port,
                    "video_destination": f"{gs_ip}:{port}" if gs_ip else f":{port}",
                    "video_main_port": main_port,
                    "video_streams": node_video_streams,
                    "camera_topic": camera_topic(topo, inst),
                    "rtp_running": sub_running,
                    "control_ws": control_runtime.get("control_ws") or f"ws://127.0.0.1:{control_relay_port}",
                    "control_relay_port": control_relay_port,
                    "control_core_port": control_core_port,
                    "control_mavsdk_server_port": control_mavsdk_server_port,
                    "control_relay_open": control_runtime.get("relay_open", False),
                    "control_core_open": control_runtime.get("core_open", False),
                    "control_mavsdk_server_open": control_runtime.get("mavsdk_server_open", False),
                    "control_runtime": control_runtime,
                }
            )
        nodes.append(node)

    status_counts: Dict[str, int] = {"good": 0, "warn": 0, "bad": 0, "stale": 0, "unknown": 0}
    for link in links:
        status_counts[str(link.get("status", "unknown"))] = status_counts.get(str(link.get("status", "unknown")), 0) + 1

    pid_prefix = f"/tmp/ucs_mesh_{scenario_id}"
    metrics_pid = Path(f"/tmp/ucs_mesh_metrics_{scenario_id}.pid")
    ns3_pid = Path(f"/tmp/ucs_mesh_ns3_{scenario_id}.pid")
    time_file = Path(str(globals_.get("time_file", "/tmp/ucs_mesh_sim_time.txt")))
    sim_time = parse_float(read_text(time_file))
    control_relay_count = sum(1 for item in control_runtimes if item.get("relay_open"))
    control_core_count = sum(1 for item in control_runtimes if item.get("core_open"))
    mavsdk_server_count = sum(1 for item in control_runtimes if item.get("mavsdk_server_open"))
    legacy_control_relay_port = parse_int(os.environ.get("CONTROL_RELAY_PORT"), 8765)
    legacy_control_core_port = parse_int(os.environ.get("CONTROL_CORE_PORT"), 9001)
    legacy_mavsdk_server_port = parse_int(os.environ.get("CONTROL_MAVSDK_SERVER_PORT"), 50051)

    return {
        "ts": now,
        "topology": {
            "path": str(topology_path),
            "scenario_id": scenario_id,
            "description": topo.get("description", ""),
            "world": globals_.get("px4_gz_world_name"),
            "world_sdf": globals_.get("world_sdf"),
            "gz_partition": globals_.get("gz_partition"),
            "link_model": link_sim.get("model"),
            "link_model_display": link_model_label(link_sim, impairment_policy),
            "impairment_policy": impairment_policy,
            "link_simulation": link_sim,
            "programmable_routing": programmable_routing,
            "payload": globals_.get("payload", {}),
            "video": video,
            "video_flows": [
                {
                    "key": item["key"],
                    "label": item["label"],
                    "role": item["role"],
                    "port_base": item["port_base"],
                    "resolution": item["resolution"],
                    "fps": item["fps"],
                    "bitrate_kbps": item["bitrate_kbps"],
                }
                for item in video_flows
            ],
            "control": globals_.get("business_flows", {}).get("control", {}),
        },
        "runtime": {
            "sim_time": None if not math.isfinite(sim_time) else sim_time,
            "time_file": str(time_file),
            "metrics_pidfile": str(metrics_pid),
            "metrics_alive": pid_alive(metrics_pid),
            "ns3_pidfile": str(ns3_pid),
            "ns3_alive": pid_alive(ns3_pid),
            "ns3_log": log_path,
            "rtp_processes": len(rtp_processes),
            "control_ws_open": control_relay_count > 0 or tcp_port_open("127.0.0.1", legacy_control_relay_port),
            "control_relay_count": control_relay_count,
            "control_core_open": control_core_count > 0 or tcp_port_open("127.0.0.1", legacy_control_core_port),
            "control_core_count": control_core_count,
            "mavsdk_server_open": mavsdk_server_count > 0 or tcp_port_open("127.0.0.1", legacy_mavsdk_server_port),
            "mavsdk_server_count": mavsdk_server_count,
            "control_runtimes": control_runtimes,
            "pid_prefix": pid_prefix,
        },
        "ground_station": {
            "id": gs_id,
            "exp_ip": gs_ip,
        },
        "nodes": nodes,
        "links": links,
        "link_status_counts": status_counts,
        "video_proxy": {
            "available": GST_AVAILABLE,
            "error": GST_ERROR,
            "caps": RTP_CAPS,
        },
    }


class OnDemandVideoSender:
    def __init__(
        self,
        *,
        uav_id: str,
        stream_key: str,
        port: int,
        topology_path: Path,
        encoder: str,
        run_dir: Path,
    ):
        self.uav_id = uav_id
        self.stream_key = stream_key
        self.port = port
        self.topology_path = topology_path
        self.encoder = encoder
        self.run_dir = run_dir
        self.proc: Optional[subprocess.Popen] = None
        self.external = False
        self.started_at = 0.0
        self.last_client_at = time.monotonic()
        self.last_error = ""
        self.log_path = run_dir / f"{uav_id}-{stream_key}.log"

    def mark_client_active(self) -> None:
        self.last_client_at = time.monotonic()

    def is_running(self) -> bool:
        if self.external:
            return rtp_port_process_running(self.port)
        return self.proc is not None and self.proc.poll() is None

    def start(self) -> None:
        self.mark_client_active()
        if self.is_running():
            return
        self.external = False
        self.proc = None
        self.last_error = ""
        self.run_dir.mkdir(parents=True, exist_ok=True)
        if rtp_port_process_running(self.port):
            self.external = True
            self.started_at = time.monotonic()
            print(
                f"[dashboard] on-demand video sender adopted existing stream "
                f"{self.uav_id}/{self.stream_key} port={self.port}",
                flush=True,
            )
            return

        cmd = [
            str(RTP_CAMERA_FLOW_SH),
            "--topology",
            str(self.topology_path),
            "--uav",
            self.uav_id,
            "--flow",
            self.stream_key,
            "--encoder",
            self.encoder,
        ]
        env = os.environ.copy()
        env["RTP_RUN_DIR"] = str(self.run_dir)
        try:
            log_fh = open(self.log_path, "ab", buffering=0)
            try:
                self.proc = subprocess.Popen(
                    cmd,
                    cwd=str(MESH_DIR),
                    env=env,
                    stdout=log_fh,
                    stderr=subprocess.STDOUT,
                    start_new_session=hasattr(os, "setsid"),
                )
            finally:
                log_fh.close()
            self.started_at = time.monotonic()
            print(
                f"[dashboard] on-demand video sender started "
                f"{self.uav_id}/{self.stream_key} port={self.port} "
                f"pid={self.proc.pid} log={self.log_path}",
                flush=True,
            )
        except Exception as exc:
            self.last_error = str(exc)
            self.proc = None
            print(
                f"[dashboard][ERR] failed to start on-demand video sender "
                f"{self.uav_id}/{self.stream_key}: {exc}",
                flush=True,
            )

    def stop(self) -> None:
        if self.external:
            self.external = False
            return
        proc = self.proc
        self.proc = None
        if proc is None or proc.poll() is not None:
            return
        try:
            if hasattr(os, "killpg"):
                os.killpg(proc.pid, signal.SIGTERM)
            else:
                proc.terminate()
            proc.wait(timeout=5.0)
        except subprocess.TimeoutExpired:
            with contextlib.suppress(Exception):
                if hasattr(os, "killpg"):
                    os.killpg(proc.pid, signal.SIGKILL)
                else:
                    proc.kill()
        except Exception as exc:
            self.last_error = str(exc)
        print(
            f"[dashboard] on-demand video sender stopped "
            f"{self.uav_id}/{self.stream_key} port={self.port}",
            flush=True,
        )

    def snapshot(self, now: Optional[float] = None) -> Dict[str, Any]:
        now = time.monotonic() if now is None else now
        proc = self.proc
        return {
            "uav_id": self.uav_id,
            "stream": self.stream_key,
            "port": self.port,
            "running": self.is_running(),
            "external": self.external,
            "pid": None if proc is None else proc.pid,
            "idle_s": max(0.0, now - self.last_client_at),
            "started_s": None if not self.started_at else max(0.0, now - self.started_at),
            "log": str(self.log_path),
            "error": self.last_error,
        }


class OnDemandVideoSenderManager:
    def __init__(
        self,
        *,
        enabled: bool,
        topology_path: Path,
        encoder: str,
        idle_sec: float,
        run_dir: Path,
    ):
        self.enabled = enabled
        self.topology_path = topology_path
        self.encoder = encoder
        self.idle_sec = max(1.0, idle_sec)
        self.run_dir = run_dir
        self.lock = threading.Lock()
        self.senders: Dict[Tuple[str, str, int], OnDemandVideoSender] = {}
        self.stop_event = threading.Event()
        self.monitor_thread: Optional[threading.Thread] = None

    def ensure(self, uav_id: str, stream_key: str, port: int) -> Optional[OnDemandVideoSender]:
        if not self.enabled:
            return None
        key = (uav_id, stream_key, port)
        with self.lock:
            sender = self.senders.get(key)
            if sender is None:
                sender = OnDemandVideoSender(
                    uav_id=uav_id,
                    stream_key=stream_key,
                    port=port,
                    topology_path=self.topology_path,
                    encoder=self.encoder,
                    run_dir=self.run_dir / f"{uav_id}-{stream_key}",
                )
                self.senders[key] = sender
            sender.start()
            self._ensure_monitor_locked()
            return sender

    def _ensure_monitor_locked(self) -> None:
        if self.monitor_thread is not None and self.monitor_thread.is_alive():
            return
        self.stop_event.clear()
        self.monitor_thread = threading.Thread(target=self._monitor_loop, name="video-sender-monitor", daemon=True)
        self.monitor_thread.start()

    def _monitor_loop(self) -> None:
        while not self.stop_event.wait(2.0):
            now = time.monotonic()
            stale: List[Tuple[Tuple[str, str, int], OnDemandVideoSender]] = []
            with self.lock:
                for key, sender in list(self.senders.items()):
                    idle_for = now - sender.last_client_at
                    if not sender.is_running():
                        stale.append((key, sender))
                    elif idle_for > self.idle_sec:
                        stale.append((key, sender))
                for key, _sender in stale:
                    self.senders.pop(key, None)
            for _key, sender in stale:
                sender.stop()

    def mark_active(self, sender: Optional[OnDemandVideoSender]) -> None:
        if sender is not None:
            sender.mark_client_active()

    def snapshot(self) -> List[Dict[str, Any]]:
        now = time.monotonic()
        with self.lock:
            return [sender.snapshot(now) for sender in self.senders.values()]

    def stop_all(self) -> None:
        self.stop_event.set()
        with self.lock:
            senders = list(self.senders.values())
            self.senders.clear()
        for sender in senders:
            sender.stop()


class VideoReceiver:
    def __init__(
        self,
        address: str,
        port: int,
        width: int,
        height: int,
        quality: int,
        *,
        jitter_latency_ms: int,
        drop_on_latency: bool,
        udp_buffer_bytes: int,
        decoder: str,
    ):
        self.address = address
        self.port = port
        self.width = width
        self.height = height
        self.quality = quality
        self.jitter_latency_ms = max(0, jitter_latency_ms)
        self.drop_on_latency = drop_on_latency
        self.udp_buffer_bytes = max(0, udp_buffer_bytes)
        self.decoder_request = decoder
        self.decoder_label = ""
        self.pipeline_text = ""
        self.frame: Optional[bytes] = None
        self.seq = 0
        self.error = ""
        self.error_count = 0
        self.last_error_at = 0.0
        self.warning_count = 0
        self.last_warning = ""
        self.started_at = time.monotonic()
        self.first_frame_at = 0.0
        self.last_frame_at = 0.0
        self.last_frame_bytes = 0
        self.rtp_stats: Dict[str, float] = {}
        self.rtp_stats_text = ""
        self.started = False
        self.stop_requested = False
        self.last_client_at = time.monotonic()
        self.lock = threading.Condition()
        self.thread: Optional[threading.Thread] = None
        self.pipeline = None

    def start(self) -> None:
        with self.lock:
            if self.started:
                return
            self.stop_requested = False
            self.error = ""
        if not GST_AVAILABLE:
            with self.lock:
                self.error = GST_ERROR
            return
        self.started = True
        self.thread = threading.Thread(target=self._run, name=f"rtp-mjpeg-{self.port}", daemon=True)
        self.thread.start()

    def mark_client_active(self) -> None:
        with self.lock:
            self.last_client_at = time.monotonic()

    def stop(self) -> None:
        with self.lock:
            self.stop_requested = True
            self.lock.notify_all()
        if self.pipeline is not None:
            self.pipeline.set_state(Gst.State.NULL)

    def _on_sample(self, sink: Any) -> Any:
        sample = sink.emit("pull-sample")
        if sample is None:
            return Gst.FlowReturn.ERROR
        buf = sample.get_buffer()
        ok, mapinfo = buf.map(Gst.MapFlags.READ)
        if not ok:
            return Gst.FlowReturn.ERROR
        try:
            data = bytes(mapinfo.data)
        finally:
            buf.unmap(mapinfo)
        now = time.monotonic()
        with self.lock:
            self.frame = data
            self.seq += 1
            if not self.first_frame_at:
                self.first_frame_at = now
            self.last_frame_at = now
            self.last_frame_bytes = len(data)
            self.lock.notify_all()
        return Gst.FlowReturn.OK

    def set_error(self, text: str) -> None:
        with self.lock:
            self.error = text
            self.error_count += 1
            self.last_error_at = time.monotonic()
            self.lock.notify_all()

    def set_warning(self, text: str) -> None:
        with self.lock:
            self.warning_count += 1
            self.last_warning = text
            self.lock.notify_all()

    def update_jitter_stats(self) -> None:
        if self.pipeline is None:
            return
        try:
            jitter = self.pipeline.get_by_name("jitter")
            if jitter is None:
                return
            stats = jitter.get_property("stats")
            text = stats.to_string() if stats is not None else ""
        except Exception:
            return
        parsed = {key: float(value) for key, value in GST_STAT_RE.findall(text)}
        with self.lock:
            self.rtp_stats = parsed
            self.rtp_stats_text = text

    def _decoder_candidates(self) -> List[Tuple[str, List[str], str]]:
        requested = self.decoder_request.strip().lower().replace("_", "-")
        hard_candidates: List[Tuple[str, List[str], str]] = [
            ("nvh264dec", ["nvh264dec", "cudadownload"], "nvh264dec ! queue ! cudadownload ! videoconvert"),
            ("nvh264dec", ["nvh264dec"], "nvh264dec ! queue ! videoconvert"),
            ("nvh264sldec", ["nvh264sldec", "cudadownload"], "nvh264sldec ! queue ! cudadownload ! videoconvert"),
            ("nvh264sldec", ["nvh264sldec"], "nvh264sldec ! queue ! videoconvert"),
            ("vah264dec", ["vah264dec", "vapostproc"], "vah264dec ! vapostproc ! video/x-raw ! videoconvert"),
            ("vah264dec", ["vah264dec"], "vah264dec ! videoconvert"),
            ("vaapih264dec", ["vaapih264dec", "vaapipostproc"], "vaapih264dec ! vaapipostproc ! video/x-raw ! videoconvert"),
            ("vaapih264dec", ["vaapih264dec"], "vaapih264dec ! videoconvert"),
            ("v4l2h264dec", ["v4l2h264dec"], "v4l2h264dec ! videoconvert"),
        ]
        software_candidate = ("avdec_h264", ["avdec_h264"], "avdec_h264 ! videoconvert")

        aliases = {
            "auto": "auto",
            "hw": "hard",
            "hard": "hard",
            "hardware": "hard",
            "soft": "avdec-h264",
            "software": "avdec-h264",
            "avdec": "avdec-h264",
            "avdec-h264": "avdec-h264",
            "nvdec": "nvh264dec",
            "nvidia": "nvh264dec",
            "nvh264dec": "nvh264dec",
            "nvh264sldec": "nvh264sldec",
            "va": "vah264dec",
            "vaapi": "vaapih264dec",
            "vah264dec": "vah264dec",
            "vaapih264dec": "vaapih264dec",
            "v4l2": "v4l2h264dec",
            "v4l2h264dec": "v4l2h264dec",
        }
        normalized = aliases.get(requested, requested or "auto")
        if normalized == "auto":
            return hard_candidates + [software_candidate]
        if normalized == "hard":
            return hard_candidates
        if normalized in {"avdec-h264", "avdec_h264"}:
            return [software_candidate]
        return [candidate for candidate in hard_candidates if candidate[0] == normalized]

    def _pipeline_for_decoder(self, decoder_fragment: str) -> str:
        udp_buffer = f" buffer-size={self.udp_buffer_bytes}" if self.udp_buffer_bytes > 0 else ""
        return (
            f"udpsrc address={self.address} port={self.port}{udp_buffer} caps=\"{RTP_CAPS}\" "
            f"! rtpjitterbuffer name=jitter latency={self.jitter_latency_ms} "
            f"drop-on-latency={gst_bool(self.drop_on_latency)} do-lost=true "
            f"! rtph264depay ! h264parse ! {decoder_fragment} "
            f"! videoscale ! video/x-raw,width={self.width},height={self.height} "
            f"! jpegenc quality={self.quality} "
            "! appsink name=sink emit-signals=true sync=false max-buffers=1 drop=true"
        )

    def _build_pipeline(self) -> bool:
        errors: List[str] = []
        for label, factories, decoder_fragment in self._decoder_candidates():
            missing = [factory for factory in factories if not gst_has_factory(factory)]
            if missing:
                errors.append(f"{label}: missing {','.join(missing)}")
                continue
            pipeline_text = self._pipeline_for_decoder(decoder_fragment)
            try:
                pipeline = Gst.parse_launch(pipeline_text)
                sink = pipeline.get_by_name("sink")
                if sink is None:
                    raise RuntimeError("appsink not found")
                sink.connect("new-sample", self._on_sample)
                ret = pipeline.set_state(Gst.State.PLAYING)
                if ret == Gst.StateChangeReturn.FAILURE:
                    pipeline.set_state(Gst.State.NULL)
                    raise RuntimeError("failed to set pipeline PLAYING")
            except Exception as exc:
                errors.append(f"{label}: {exc}")
                continue
            self.pipeline = pipeline
            self.decoder_label = label
            self.pipeline_text = pipeline_text
            print(
                f"[dashboard] video_receiver port={self.port} decoder={label} "
                f"requested={self.decoder_request}",
                flush=True,
            )
            return True

        self.set_error(
            "no usable H.264 decoder for dashboard video: "
            + "; ".join(errors or [self.decoder_request])
        )
        return False

    def _run(self) -> None:
        try:
            if not self._build_pipeline():
                return
            bus = self.pipeline.get_bus()
            while True:
                with self.lock:
                    if self.stop_requested:
                        break
                    idle_for = time.monotonic() - self.last_client_at
                if idle_for > DASHBOARD_VIDEO_IDLE_SEC:
                    break
                self.update_jitter_stats()
                msg = bus.timed_pop_filtered(
                    Gst.SECOND,
                    Gst.MessageType.ERROR | Gst.MessageType.EOS | Gst.MessageType.WARNING,
                )
                if msg is None:
                    continue
                if msg.type == Gst.MessageType.ERROR:
                    err, debug = msg.parse_error()
                    self.set_error(f"{err}: {debug}")
                    break
                if msg.type == Gst.MessageType.EOS:
                    self.set_error("end-of-stream")
                    break
                if msg.type == Gst.MessageType.WARNING:
                    warn, debug = msg.parse_warning()
                    self.set_warning(f"{warn}: {debug}")
        except Exception as exc:
            self.set_error(str(exc))
        finally:
            if self.pipeline is not None:
                self.pipeline.set_state(Gst.State.NULL)
            with self.lock:
                self.started = False
                self.lock.notify_all()

    def wait_frame(self, previous_seq: int, timeout: float = 5.0) -> Tuple[int, Optional[bytes]]:
        deadline = time.monotonic() + timeout
        with self.lock:
            while self.seq == previous_seq and not self.error:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    break
                self.lock.wait(remaining)
            return self.seq, self.frame

    def snapshot(self, now: Optional[float] = None) -> Dict[str, Any]:
        now = time.monotonic() if now is None else now
        with self.lock:
            seq = self.seq
            has_frame = self.frame is not None
            first_frame_at = self.first_frame_at
            last_frame_at = self.last_frame_at
            error = self.error
            warning_count = self.warning_count
            last_warning = self.last_warning
            error_count = self.error_count
            last_error_at = self.last_error_at
            last_frame_bytes = self.last_frame_bytes
            stats = dict(self.rtp_stats)

        age = None if not last_frame_at else max(0.0, now - last_frame_at)
        elapsed = max(0.0, now - first_frame_at) if first_frame_at else 0.0
        fps = (seq / elapsed) if elapsed > 0.0 else None
        pushed = int(stats.get("num-pushed", 0))
        lost = int(stats.get("num-lost", 0))
        late = int(stats.get("num-late", 0))
        duplicates = int(stats.get("num-duplicates", 0))
        impaired_packets = lost + late
        packet_total = pushed + impaired_packets
        rtp_loss_rate = (impaired_packets / packet_total) if packet_total > 0 else None
        impairment_rate = rtp_loss_rate or 0.0

        if age is not None and age > 1.0:
            impairment_rate = max(impairment_rate, min(1.0, (age - 1.0) / 2.0))
        if fps is not None and elapsed > 3.0 and fps < 8.0:
            impairment_rate = max(impairment_rate, min(1.0, (8.0 - fps) / 8.0))

        if error:
            status = "bad"
            status_label = "err"
        elif not self.started:
            status = "idle"
            status_label = "idle"
        elif seq <= 0:
            status = "warn"
            status_label = "wait"
        elif age is not None and age > 2.5:
            status = "bad"
            status_label = "stale"
        elif impairment_rate >= 0.05:
            status = "bad"
            status_label = "rtp"
        elif (age is not None and age > 1.0) or impairment_rate > 0.0:
            status = "warn"
            status_label = "rtp"
        else:
            status = "good"
            status_label = "ok"

        return {
            "address": self.address,
            "port": self.port,
            "width": self.width,
            "height": self.height,
            "quality": self.quality,
            "decoder_requested": self.decoder_request,
            "decoder": self.decoder_label,
            "jitter_latency_ms": self.jitter_latency_ms,
            "drop_on_latency": self.drop_on_latency,
            "udp_buffer_bytes": self.udp_buffer_bytes,
            "started": self.started,
            "frames": seq,
            "has_frame": has_frame,
            "age_s": age,
            "fps": fps,
            "last_frame_bytes": last_frame_bytes,
            "error": error,
            "error_count": error_count,
            "last_error_age_s": None if not last_error_at else max(0.0, now - last_error_at),
            "warning_count": warning_count,
            "last_warning": last_warning,
            "rtp_pushed": pushed,
            "rtp_lost": lost,
            "rtp_late": late,
            "rtp_duplicates": duplicates,
            "rtp_loss_rate": rtp_loss_rate,
            "video_impairment_rate": impairment_rate,
            "status": status,
            "status_label": status_label,
        }


class DashboardHandler(SimpleHTTPRequestHandler):
    server: "DashboardHTTPServer"

    def log_message(self, fmt: str, *args: Any) -> None:
        sys.stderr.write("[dashboard] " + fmt % args + "\n")

    def end_headers(self) -> None:
        if getattr(self, "_static_no_store", False):
            self.send_header("Cache-Control", "no-store")
            self.send_header("Pragma", "no-cache")
        super().end_headers()

    def serve_static(self, *, head: bool = False) -> None:
        self._static_no_store = True
        try:
            if head:
                return SimpleHTTPRequestHandler.do_HEAD(self)
            return SimpleHTTPRequestHandler.do_GET(self)
        finally:
            self._static_no_store = False

    def send_json(self, payload: Dict[str, Any], status: int = 200) -> None:
        raw = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_HEAD(self) -> None:  # noqa: N802
        parsed = urlparse(self.path)
        if parsed.path in {"/", "/index.html"}:
            self.path = "/index.html"
        return self.serve_static(head=True)

    def do_GET(self) -> None:  # noqa: N802
        parsed = urlparse(self.path)
        if parsed.path in {"/", "/index.html"}:
            self.path = "/index.html"
            return self.serve_static()
        if parsed.path == "/api/state":
            try:
                payload = build_state(self.server.topology_path)
                receivers = []
                receiver_by_port: Dict[int, Dict[str, Any]] = {}
                now_mono = time.monotonic()
                for key, receiver in self.server.video_receivers.items():
                    _address, port, _width, _height, _quality, _decoder = key
                    snap = receiver.snapshot(now_mono)
                    receivers.append(snap)
                    current = receiver_by_port.get(port)
                    if current is None or int(snap.get("frames", 0)) >= int(current.get("frames", 0)):
                        receiver_by_port[port] = snap
                payload["video_proxy"]["receivers"] = receivers
                for node in payload.get("nodes", []):
                    port = parse_int(node.get("video_port"), -1)
                    if port in receiver_by_port:
                        node["video_receiver"] = receiver_by_port[port]
                    for stream in node.get("video_streams", []):
                        stream_port = parse_int(stream.get("port"), -1)
                        if stream_port in receiver_by_port:
                            stream["receiver"] = receiver_by_port[stream_port]
                payload["video_proxy"]["on_demand"] = self.server.video_sender_manager.enabled
                payload["video_proxy"]["senders"] = self.server.video_sender_manager.snapshot()
                self.send_json(payload)
            except Exception as exc:
                self.send_json({"error": str(exc)}, status=500)
            return
        if parsed.path == "/api/config":
            self.send_json(
                {
                    "topology": str(self.server.topology_path),
                    "control_ws": self.server.control_ws,
                    "control_protocol": self.server.control_protocol,
                    "video_proxy": {
                        "available": GST_AVAILABLE,
                        "error": GST_ERROR,
                        "jitter_latency_ms": self.server.video_jitter_latency_ms,
                        "drop_on_latency": self.server.video_drop_on_latency,
                        "udp_buffer_bytes": self.server.video_udp_buffer_bytes,
                        "decoder": self.server.video_decoder,
                        "on_demand": self.server.video_sender_manager.enabled,
                        "sender_idle_sec": self.server.video_sender_manager.idle_sec,
                        "sender_encoder": self.server.video_sender_manager.encoder,
                    },
                }
            )
            return
        if parsed.path == "/api/video/start":
            qs = parse_qs(parsed.query)
            uav_id = str(qs.get("uav", [""])[0]).strip()
            stream = str(qs.get("stream", ["sub"])[0])
            if not uav_id:
                self.send_json({"ok": False, "error": "missing uav"}, status=400)
                return
            try:
                _address, resolved_uav, port, stream_key = resolve_video_request(self.server.topology_path, uav_id, stream)
                sender = self.server.video_sender_manager.ensure(resolved_uav, stream_key, port)
                self.send_json(
                    {
                        "ok": True,
                        "uav": resolved_uav,
                        "stream": stream_key,
                        "port": port,
                        "on_demand": self.server.video_sender_manager.enabled,
                        "sender": None if sender is None else sender.snapshot(),
                    }
                )
            except Exception as exc:
                self.send_json({"ok": False, "error": str(exc)}, status=400)
            return
        if parsed.path.startswith("/video/") and parsed.path.endswith(".mjpg"):
            uav_id = Path(parsed.path).name.removesuffix(".mjpg")
            qs = parse_qs(parsed.query)
            width = parse_int(qs.get("w", [640])[0], 640)
            height = parse_int(qs.get("h", [360])[0], 360)
            quality = parse_int(qs.get("q", [75])[0], 75)
            stream = str(qs.get("stream", ["sub"])[0])
            self.serve_mjpeg(uav_id, width, height, quality, stream=stream)
            return
        return self.serve_static()

    def serve_mjpeg(self, uav_id: str, width: int, height: int, quality: int, *, stream: str = "sub") -> None:
        if not GST_AVAILABLE:
            self.send_error(HTTPStatus.SERVICE_UNAVAILABLE, f"GStreamer unavailable: {GST_ERROR}")
            return
        try:
            address, resolved_uav, port, stream_key = resolve_video_request(self.server.topology_path, uav_id, stream)
        except Exception as exc:
            self.send_error(HTTPStatus.BAD_REQUEST, str(exc))
            return

        sender = self.server.video_sender_manager.ensure(resolved_uav, stream_key, port)
        key = (address, port, width, height, quality, self.server.video_decoder)
        receiver = self.server.video_receivers.setdefault(
            key,
            VideoReceiver(
                address,
                port,
                width,
                height,
                quality,
                jitter_latency_ms=self.server.video_jitter_latency_ms,
                drop_on_latency=self.server.video_drop_on_latency,
                udp_buffer_bytes=self.server.video_udp_buffer_bytes,
                decoder=self.server.video_decoder,
            ),
        )
        receiver.mark_client_active()
        receiver.start()

        self.send_response(HTTPStatus.OK)
        self.send_header("Age", "0")
        self.send_header("Cache-Control", "no-cache, private")
        self.send_header("Pragma", "no-cache")
        self.send_header("Content-Type", "multipart/x-mixed-replace; boundary=frame")
        self.end_headers()

        seq = -1
        try:
            while True:
                receiver.mark_client_active()
                self.server.video_sender_manager.mark_active(sender)
                seq, frame = receiver.wait_frame(seq)
                if frame is None:
                    if receiver.error:
                        raise RuntimeError(receiver.error)
                    continue
                self.wfile.write(b"--frame\r\n")
                self.wfile.write(b"Content-Type: image/jpeg\r\n")
                self.wfile.write(f"Content-Length: {len(frame)}\r\n\r\n".encode("ascii"))
                self.wfile.write(frame)
                self.wfile.write(b"\r\n")
                self.wfile.flush()
        except Exception:
            return


class DashboardHTTPServer(ThreadingHTTPServer):
    def __init__(
        self,
        server_address: Tuple[str, int],
        handler_class: type[DashboardHandler],
        *,
        topology_path: Path,
        control_ws: str,
        control_protocol: str,
        video_jitter_latency_ms: int,
        video_drop_on_latency: bool,
        video_udp_buffer_bytes: int,
        video_decoder: str,
        video_on_demand: bool,
        video_sender_idle_sec: float,
        video_sender_encoder: str,
        video_sender_run_dir: Path,
    ):
        self.topology_path = topology_path
        self.control_ws = control_ws
        self.control_protocol = control_protocol
        self.video_jitter_latency_ms = max(0, video_jitter_latency_ms)
        self.video_drop_on_latency = video_drop_on_latency
        self.video_udp_buffer_bytes = max(0, video_udp_buffer_bytes)
        self.video_decoder = video_decoder
        self.video_receivers: Dict[Tuple[str, int, int, int, int, str], VideoReceiver] = {}
        self.video_sender_manager = OnDemandVideoSenderManager(
            enabled=video_on_demand,
            topology_path=topology_path,
            encoder=video_sender_encoder,
            idle_sec=video_sender_idle_sec,
            run_dir=video_sender_run_dir,
        )
        super().__init__(server_address, handler_class)

    def server_close(self) -> None:
        for receiver in list(getattr(self, "video_receivers", {}).values()):
            receiver.stop()
        self.video_sender_manager.stop_all()
        super().server_close()


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--topology", default=str(DEFAULT_TOPOLOGY), help="BMv2 topology JSON")
    parser.add_argument("--host", default="0.0.0.0", help="HTTP listen host")
    parser.add_argument("--port", type=int, default=8088, help="HTTP listen port")
    parser.add_argument("--control-ws", default="", help="Default remote-control WebSocket URL")
    parser.add_argument(
        "--control-protocol",
        choices=["relay", "legacy"],
        default="relay",
        help="Default control WebSocket protocol",
    )
    parser.add_argument(
        "--video-jitter-latency-ms",
        type=int,
        default=parse_int(os.environ.get("DASHBOARD_VIDEO_JITTER_LATENCY_MS"), 800),
        help="Dashboard RTP jitter-buffer latency in ms. Default: 800",
    )
    parser.add_argument(
        "--video-drop-on-latency",
        action=argparse.BooleanOptionalAction,
        default=parse_bool(os.environ.get("DASHBOARD_VIDEO_DROP_ON_LATENCY"), False),
        help="Drop RTP packets when the jitter buffer exceeds latency. Default: false",
    )
    parser.add_argument(
        "--video-udp-buffer-bytes",
        type=int,
        default=parse_int(os.environ.get("DASHBOARD_VIDEO_UDP_BUFFER_BYTES"), 0),
        help="Dashboard UDP receive buffer size in bytes, or 0 for system default. Default: 0",
    )
    parser.add_argument(
        "--video-decoder",
        default=os.environ.get("DASHBOARD_VIDEO_DECODER", "auto"),
        help=(
            "Dashboard H.264 decoder: auto, hard, nvh264dec, nvh264sldec, "
            "vah264dec, vaapih264dec, v4l2h264dec, or avdec_h264. "
            "Default: auto"
        ),
    )
    parser.add_argument(
        "--video-on-demand",
        action=argparse.BooleanOptionalAction,
        default=parse_bool(os.environ.get("DASHBOARD_VIDEO_ON_DEMAND"), False),
        help="Start RTP camera senders only when /video/<uav>.mjpg is requested. Default: false",
    )
    parser.add_argument(
        "--video-sender-idle-sec",
        type=float,
        default=parse_float(os.environ.get("DASHBOARD_VIDEO_SENDER_IDLE_SEC"), DASHBOARD_VIDEO_SENDER_IDLE_SEC),
        help=f"Stop on-demand RTP senders after this many idle seconds. Default: {DASHBOARD_VIDEO_SENDER_IDLE_SEC:g}",
    )
    parser.add_argument(
        "--video-sender-encoder",
        default=os.environ.get("DASHBOARD_VIDEO_SENDER_ENCODER", os.environ.get("VIDEO_ENCODER", "auto")),
        help="Encoder passed to video/run_rtp_camera_flow.sh for on-demand senders. Default: VIDEO_ENCODER or auto",
    )
    parser.add_argument(
        "--video-sender-run-dir",
        default=os.environ.get("DASHBOARD_VIDEO_SENDER_RUN_DIR", f"/tmp/ucs-mesh-{os.getuid()}/dashboard-rtp"),
        help="Directory for on-demand RTP sender logs and pid files.",
    )
    return parser


def main() -> int:
    args = build_arg_parser().parse_args()
    topology_path = Path(args.topology).expanduser().resolve()
    if not topology_path.is_file():
        print(f"[dashboard][ERR] topology not found: {topology_path}", file=sys.stderr)
        return 2

    control_ws = args.control_ws
    if not control_ws:
        control_ws = default_control_ws(topology_path)
    os.chdir(DASHBOARD_DIR)
    httpd = DashboardHTTPServer(
        (args.host, args.port),
        DashboardHandler,
        topology_path=topology_path,
        control_ws=control_ws,
        control_protocol=args.control_protocol,
        video_jitter_latency_ms=args.video_jitter_latency_ms,
        video_drop_on_latency=args.video_drop_on_latency,
        video_udp_buffer_bytes=args.video_udp_buffer_bytes,
        video_decoder=args.video_decoder,
        video_on_demand=args.video_on_demand,
        video_sender_idle_sec=args.video_sender_idle_sec,
        video_sender_encoder=args.video_sender_encoder,
        video_sender_run_dir=Path(args.video_sender_run_dir).expanduser().resolve(),
    )
    print(f"[dashboard] topology={topology_path}", flush=True)
    print(f"[dashboard] listening=http://{args.host}:{args.port}", flush=True)
    print(f"[dashboard] video_proxy={'on' if GST_AVAILABLE else 'off'} {GST_ERROR}", flush=True)
    print(
        "[dashboard] video_pipeline="
        f"jitter_latency_ms={httpd.video_jitter_latency_ms} "
        f"drop_on_latency={gst_bool(httpd.video_drop_on_latency)} "
        f"udp_buffer_bytes={httpd.video_udp_buffer_bytes} "
        f"decoder={httpd.video_decoder}",
        flush=True,
    )
    print(
        "[dashboard] video_on_demand="
        f"{httpd.video_sender_manager.enabled} "
        f"sender_encoder={httpd.video_sender_manager.encoder} "
        f"sender_idle_sec={httpd.video_sender_manager.idle_sec:g} "
        f"sender_run_dir={httpd.video_sender_manager.run_dir}",
        flush=True,
    )
    print(f"[dashboard] control_ws={control_ws} protocol={args.control_protocol}", flush=True)

    def _stop_on_signal(_signum: int, _frame: Any) -> None:
        raise KeyboardInterrupt

    with contextlib.suppress(Exception):
        signal.signal(signal.SIGTERM, _stop_on_signal)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\n[dashboard] stopped", flush=True)
    finally:
        httpd.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
