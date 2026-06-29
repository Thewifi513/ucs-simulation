#!/usr/bin/env python3
"""Generate P4Runtime table entries for UCS edge routing modes.

The generated entries do not change Linux routes. Linux keeps ordinary on-link
reachability; BMv2 rewrites the Ethernet next hop at each programmable edge.
"""

from __future__ import annotations

import argparse
import heapq
import ipaddress
import json
import math
import mmap
import os
import re
import struct
import subprocess
import time
from pathlib import Path
from typing import Any


TABLE = "IngressImpl.ipv4_lpm"
ACTION = "IngressImpl.set_nhop"
MATCH_FIELD = "hdr.ipv4.dst_addr"
PARAM_DST_MAC = "dst_mac"
PARAM_SRC_MAC = "src_mac"
PARAM_PORT = "port"
DEFAULT_AIR_PORT = 2
LINK_SHM_MAGIC = b"UCSLNK01"
LINK_SHM_VERSION = 1
LINK_SHM_HEADER = struct.Struct("<8sIIQddII16s")
LINK_SHM_MAX_AGE_SEC = 5.0
LOG_LINE_RE = re.compile(r"\[(?:pair-link|link)\]\s+(.*)")
FIELD_RE = re.compile(r"(\w+)=([^\s]+)")

CLUSTER_HEAD_MODES = {"cluster_heads", "cluster_head_routes"}
ADAPTIVE_PRIOR_MODES = {"adaptive_prior", "adaptive_prior_loss", "prior_adaptive", "adaptive"}
ADAPTIVE_RESOURCE_MODES = {
    "adaptive_resource",
    "adaptive_resources",
    "resource_adaptive",
    "resource_scheduled",
    "scheduled_resource",
}
ROUTING_ENTRY_MODES = CLUSTER_HEAD_MODES | ADAPTIVE_PRIOR_MODES | ADAPTIVE_RESOURCE_MODES

EXPLICIT_COST_KEYS = (
    "routing_cost",
    "prior_cost",
    "cost",
    "weight",
)
LOSS_KEYS = (
    "prior_loss",
    "prior_loss_rate",
    "loss",
    "loss_rate",
    "packet_error_rate",
    "per",
    "phy_per",
    "mac_drop_rate",
    "post_mac_drop_rate",
)
DELAY_KEYS = ("delay_ms", "latency_ms", "queue_delay_ms", "prior_delay_ms")
JITTER_KEYS = ("jitter_ms", "delay_jitter_ms", "prior_jitter_ms")
DISTANCE_KEYS = ("distance_m", "distance", "prior_distance_m")
OBSTRUCTION_KEYS = (
    "obstruction_loss_db",
    "obstruction_raw_loss_db",
    "prior_obstruction_loss_db",
)
RESOURCE_ROLE_KEYS = {"link_resource", "resource", "relay_resource", "high_resource"}


def cidr_ip(cidr: str) -> str:
    return str(ipaddress.ip_interface(cidr).ip)


def read_host_mac(ifname: str) -> str:
    path = Path("/sys/class/net") / ifname / "address"
    return path.read_text(encoding="utf-8").strip().lower()


def read_container_mac(container: str, ifname: str) -> str:
    cmd = ["docker", "exec", container, "cat", f"/sys/class/net/{ifname}/address"]
    return subprocess.check_output(cmd, text=True).strip().lower()


def parse_cluster_heads(value: str) -> dict[int, str]:
    result: dict[int, str] = {}
    if not value:
        return result
    for item in value.split(","):
        item = item.strip()
        if not item:
            continue
        if ":" not in item:
            raise ValueError(f"bad cluster-head item: {item!r}; expected CLUSTER:UAV_ID")
        cluster_raw, head_id = item.split(":", 1)
        result[int(cluster_raw)] = head_id.strip()
    return result


def normalize_routing_mode(value: str) -> str:
    mode = str(value or "cluster_heads").strip()
    if mode in CLUSTER_HEAD_MODES:
        return "cluster_heads"
    if mode in ADAPTIVE_PRIOR_MODES:
        return "adaptive_prior"
    if mode in ADAPTIVE_RESOURCE_MODES:
        return "adaptive_resource"
    raise ValueError(
        f"unsupported routing mode: {mode}; expected one of {', '.join(sorted(ROUTING_ENTRY_MODES))}"
    )


def routing_config(topo: dict[str, Any]) -> dict[str, Any]:
    globals_ = topo.get("globals", {})
    programmable = topo.get("programmable_net", globals_.get("programmable_net", {}))
    routing = programmable.get("routing", {}) if isinstance(programmable, dict) else {}
    return routing if isinstance(routing, dict) else {}


def resolve_air_port(topo: dict[str, Any]) -> int:
    programmable = topo.get("programmable_net", topo.get("globals", {}).get("programmable_net", {}))
    ports = programmable.get("ports", {}) if isinstance(programmable, dict) else {}
    air = ports.get("air", {}) if isinstance(ports, dict) else {}
    topology_port = air.get("port_id", DEFAULT_AIR_PORT) if isinstance(air, dict) else DEFAULT_AIR_PORT
    return int(os.environ.get("UCS_MESH_BMV2_AIR_PORT", topology_port))


def table_entry(dst_ip: str, dst_mac: str, src_mac: str, port: int) -> dict[str, Any]:
    return {
        "table": TABLE,
        "match": {
            MATCH_FIELD: f"{dst_ip}/32",
        },
        "action": ACTION,
        "params": {
            PARAM_DST_MAC: dst_mac,
            PARAM_SRC_MAC: src_mac,
            PARAM_PORT: str(port),
        },
    }


def finite_float(value: Any) -> float | None:
    if value is None or value == "":
        return None
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    if not math.isfinite(number):
        return None
    return number


def data_rate_mbps(value: Any) -> float | None:
    if value is None or value == "":
        return None
    text = str(value).strip().lower()
    match = re.fullmatch(r"([-+]?\d+(?:\.\d+)?)\s*([kmgt]?)(?:bit/s|bps|b/s|bit|b)?", text)
    if not match:
        match = re.fullmatch(r"([-+]?\d+(?:\.\d+)?)\s*([kmgt]?)", text)
    if not match:
        return finite_float(value)
    number = finite_float(match.group(1))
    if number is None:
        return None
    unit = match.group(2)
    scale = {
        "": 1.0 / 1_000_000.0,
        "k": 1.0 / 1_000.0,
        "m": 1.0,
        "g": 1_000.0,
        "t": 1_000_000.0,
    }[unit]
    return number * scale


def nested_dicts(source: dict[str, Any]) -> list[dict[str, Any]]:
    result = [source]
    for key in ("routing", "prior", "impairment", "metrics", "link_state"):
        child = source.get(key)
        if isinstance(child, dict):
            result.append(child)
    return result


def sanitize_for_path(value: str) -> str:
    safe = re.sub(r"[^A-Za-z0-9_.-]", "_", value)
    return safe or "default"


def first_number(source: dict[str, Any], keys: tuple[str, ...]) -> float | None:
    for item in nested_dicts(source):
        for key in keys:
            value = finite_float(item.get(key))
            if value is not None:
                return value
    return None


def pose_from_dict(value: Any) -> dict[str, float] | None:
    if isinstance(value, dict):
        x = finite_float(value.get("x"))
        y = finite_float(value.get("y"))
        z = finite_float(value.get("z"))
        if x is not None and y is not None:
            return {"x": x, "y": y, "z": z if z is not None else 0.0}
    if isinstance(value, list) and len(value) >= 2:
        x = finite_float(value[0])
        y = finite_float(value[1])
        z = finite_float(value[2]) if len(value) >= 3 else 0.0
        if x is not None and y is not None:
            return {"x": x, "y": y, "z": z if z is not None else 0.0}
    return None


def endpoint_positions(
    topo: dict[str, Any],
    instances: list[dict[str, Any]],
    gs_id: str,
    metrics_max_age_sec: float,
) -> dict[str, dict[str, float]]:
    globals_ = topo.get("globals", {})
    positions: dict[str, dict[str, float]] = {}

    gs_pose = pose_from_dict(globals_.get("gs_pose"))
    if gs_pose:
        positions[gs_id] = gs_pose

    ui_positions = topo.get("ui", {}).get("node_positions", {})
    for inst in instances:
        inst_id = str(inst.get("id", ""))
        pose = pose_from_dict(inst.get("spawn_pose"))
        if pose:
            positions[inst_id] = pose
            continue
        ui_pose = pose_from_dict(ui_positions.get(inst_id) if isinstance(ui_positions, dict) else None)
        if ui_pose:
            positions[inst_id] = {
                "x": ui_pose["x"] / 10.0,
                "y": ui_pose["y"] / 10.0,
                "z": ui_pose["z"],
            }

    latest_mtime: dict[str, float] = {}
    for raw_link in list(topo.get("links", [])) + list(topo.get("mesh_links", [])):
        if not isinstance(raw_link, dict):
            continue
        metric = read_pair_metrics(raw_link, metrics_max_age_sec)
        if not metric:
            continue
        mtime = float(metric.get("mtime", 0.0))
        src = str(raw_link.get("src", ""))
        dst = str(raw_link.get("dst", ""))
        for endpoint, key in ((src, "src_pos"), (dst, "dst_pos")):
            pos = metric.get(key)
            if isinstance(pos, dict) and mtime >= latest_mtime.get(endpoint, -1.0):
                positions[endpoint] = pos
                latest_mtime[endpoint] = mtime
    return positions


def node_resource_profiles(
    topo: dict[str, Any],
    instances: list[dict[str, Any]],
    link_sim: dict[str, Any],
) -> dict[str, dict[str, Any]]:
    routing = routing_config(topo)
    defaults = routing.get("node_resource_defaults", {})
    if not isinstance(defaults, dict):
        defaults = {}

    default_tx = (
        finite_float(defaults.get("tx_power_dbm"))
        or finite_float(link_sim.get("tx_power_dbm"))
        or 20.0
    )
    default_bandwidth = (
        finite_float(defaults.get("bandwidth_mbps"))
        or data_rate_mbps(defaults.get("bandwidth"))
        or data_rate_mbps(link_sim.get("mac_data_rate"))
        or 20.0
    )
    ordinary_penalty = finite_float(defaults.get("relay_penalty")) or 1.0
    resource_defaults = routing.get("resource_node_defaults", {})
    if not isinstance(resource_defaults, dict):
        resource_defaults = {}
    resource_tx = finite_float(resource_defaults.get("tx_power_dbm")) or max(default_tx + 6.0, default_tx)
    resource_bandwidth = (
        finite_float(resource_defaults.get("bandwidth_mbps"))
        or data_rate_mbps(resource_defaults.get("bandwidth"))
        or max(default_bandwidth * 4.0, default_bandwidth)
    )
    resource_penalty = finite_float(resource_defaults.get("relay_penalty")) or 0.25

    resource_nodes_raw = routing.get("resource_nodes", [])
    resource_nodes = {
        str(item)
        for item in resource_nodes_raw
        if isinstance(resource_nodes_raw, list)
    }
    node_overrides = routing.get("node_resources", {})
    if not isinstance(node_overrides, dict):
        node_overrides = {}

    profiles: dict[str, dict[str, Any]] = {}
    for inst in instances:
        node_id = str(inst.get("id", ""))
        if not node_id:
            continue
        override = node_overrides.get(node_id, {})
        if not isinstance(override, dict):
            override = {}
        inst_resource = inst.get("link_resource", {})
        if isinstance(inst_resource, dict):
            override = {**inst_resource, **override}

        role = str(override.get("role") or ("link_resource" if node_id in resource_nodes else "ordinary"))
        is_resource = role in RESOURCE_ROLE_KEYS or node_id in resource_nodes
        base_tx = resource_tx if is_resource else default_tx
        base_bandwidth = resource_bandwidth if is_resource else default_bandwidth
        base_penalty = resource_penalty if is_resource else ordinary_penalty

        tx_power = finite_float(override.get("tx_power_dbm")) or base_tx
        bandwidth = (
            finite_float(override.get("bandwidth_mbps"))
            or data_rate_mbps(override.get("bandwidth"))
            or base_bandwidth
        )
        relay_penalty = finite_float(override.get("relay_penalty"))
        if relay_penalty is None:
            relay_penalty = base_penalty

        profiles[node_id] = {
            "role": role,
            "is_resource": is_resource,
            "tx_power_dbm": tx_power,
            "bandwidth_mbps": bandwidth,
            "relay_penalty": max(0.0, relay_penalty),
            "default_tx_power_dbm": default_tx,
            "default_bandwidth_mbps": default_bandwidth,
        }
    return profiles


def read_pair_metrics(raw_link: dict[str, Any], max_age_sec: float) -> dict[str, Any]:
    path_value = str(raw_link.get("metrics_file", ""))
    if not path_value:
        return {}
    path = Path(path_value)
    try:
        stat = path.stat()
        if max_age_sec > 0.0 and time.time() - stat.st_mtime > max_age_sec:
            return {}
        parts = path.read_text(encoding="utf-8").strip().split()
    except OSError:
        return {}
    if len(parts) < 8:
        return {}
    values = [finite_float(part) for part in parts[:10]]
    if any(value is None for value in values[:8]):
        return {}
    return {
        "mtime": stat.st_mtime,
        "age_sec": max(0.0, time.time() - stat.st_mtime),
        "sim_time": values[0],
        "distance_m": values[1],
        "src_pos": {"x": values[2], "y": values[3], "z": values[4]},
        "dst_pos": {"x": values[5], "y": values[6], "z": values[7]},
        "src_valid": values[8] if len(values) > 8 else None,
        "dst_valid": values[9] if len(values) > 9 else None,
    }


def parse_link_snapshot_text(text: str) -> dict[str, dict[str, str]]:
    last_by_id: dict[str, dict[str, str]] = {}
    for line in text.splitlines():
        match = LOG_LINE_RE.search(line)
        if not match:
            continue
        fields = dict(FIELD_RE.findall(match.group(1)))
        if fields.get("id"):
            last_by_id[str(fields["id"])] = fields
    return last_by_id


def read_link_state_shm(scenario_id: str, max_age_sec: float) -> dict[str, dict[str, str]]:
    path = Path("/dev/shm") / f"ucs_mesh_link_state_{sanitize_for_path(scenario_id)}.bin"
    if not path.is_file():
        return {}
    try:
        with path.open("rb") as handle:
            size = os.fstat(handle.fileno()).st_size
            if size < LINK_SHM_HEADER.size:
                return {}
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
                        return {}
                    if math.isfinite(wall_time) and wall_time > 0.0 and max_age_sec > 0.0:
                        if time.time() - wall_time > max_age_sec:
                            return {}
                    payload = bytes(mapped[LINK_SHM_HEADER.size:LINK_SHM_HEADER.size + used_bytes])
                    second = LINK_SHM_HEADER.unpack(mapped[:LINK_SHM_HEADER.size])
                    if first == second and not (second[3] & 1):
                        return parse_link_snapshot_text(payload.decode("utf-8", errors="replace"))
                    time.sleep(0.001)
    except OSError:
        return {}
    return {}


def read_recent_link_log(scenario_id: str, max_bytes: int = 4 * 1024 * 1024) -> dict[str, dict[str, str]]:
    for path in (
        Path(f"/tmp/ucs_mesh_ns3_{scenario_id}.launcher.log"),
        Path(f"/tmp/ucs_mesh_ns3_{scenario_id}.log"),
    ):
        if not path.is_file():
            continue
        try:
            with path.open("rb") as handle:
                handle.seek(0, os.SEEK_END)
                size = handle.tell()
                handle.seek(max(0, size - max_bytes), os.SEEK_SET)
                return parse_link_snapshot_text(handle.read().decode("utf-8", errors="replace"))
        except OSError:
            continue
    return {}


def runtime_link_state(topo: dict[str, Any], max_age_sec: float) -> dict[str, dict[str, str]]:
    scenario_id = str(topo.get("scenario_id", ""))
    if not scenario_id:
        return {}
    state = read_link_state_shm(scenario_id, max_age_sec)
    if state:
        return state
    return read_recent_link_log(scenario_id)


def distance_m(a: dict[str, float], b: dict[str, float]) -> float:
    dx = float(a.get("x", 0.0)) - float(b.get("x", 0.0))
    dy = float(a.get("y", 0.0)) - float(b.get("y", 0.0))
    dz = float(a.get("z", 0.0)) - float(b.get("z", 0.0))
    return math.sqrt(dx * dx + dy * dy + dz * dz)


def smooth_step_01(value: float) -> float:
    t = min(1.0, max(0.0, value))
    return t * t * (3.0 - 2.0 * t)


def segment_aabb_intersection_length(
    a: dict[str, float],
    b: dict[str, float],
    obstacle: dict[str, Any],
    expansion_m: float = 0.0,
) -> float:
    center = pose_from_dict(obstacle.get("center"))
    size_raw = obstacle.get("size")
    size = pose_from_dict(size_raw)
    if not center or not size:
        return 0.0

    expansion = max(0.0, expansion_m)
    mins = {
        "x": center["x"] - size["x"] / 2.0 - expansion,
        "y": center["y"] - size["y"] / 2.0 - expansion,
        "z": center["z"] - size["z"] / 2.0 - expansion,
    }
    maxs = {
        "x": center["x"] + size["x"] / 2.0 + expansion,
        "y": center["y"] + size["y"] / 2.0 + expansion,
        "z": center["z"] + size["z"] / 2.0 + expansion,
    }
    delta = {
        "x": b["x"] - a["x"],
        "y": b["y"] - a["y"],
        "z": b["z"] - a["z"],
    }

    t_min = 0.0
    t_max = 1.0
    for axis in ("x", "y", "z"):
        p = a[axis]
        dp = delta[axis]
        if abs(dp) < 1.0e-9:
            if p < mins[axis] or p > maxs[axis]:
                return 0.0
            continue
        t1 = (mins[axis] - p) / dp
        t2 = (maxs[axis] - p) / dp
        if t1 > t2:
            t1, t2 = t2, t1
        t_min = max(t_min, t1)
        t_max = min(t_max, t2)
        if t_min > t_max:
            return 0.0

    return max(0.0, (t_max - t_min) * distance_m(a, b))


def obstruction_config(link_sim: dict[str, Any]) -> dict[str, float | bool | list[Any]]:
    large_scale = link_sim.get("large_scale", {}) if isinstance(link_sim, dict) else {}
    obstruction = large_scale.get("obstruction", {}) if isinstance(large_scale, dict) else {}
    if not isinstance(obstruction, dict):
        obstruction = {}
    return {
        "enabled": bool(obstruction.get("enabled", link_sim.get("obstruction_loss_enabled", False))),
        "base_loss_db": finite_float(obstruction.get("base_loss_db")) or finite_float(link_sim.get("obstruction_base_loss_db")) or 0.0,
        "loss_per_hit_db": finite_float(obstruction.get("loss_per_hit_db")) or finite_float(link_sim.get("obstruction_loss_per_hit_db")) or 0.0,
        "loss_per_meter_db": finite_float(obstruction.get("loss_per_meter_db")) or finite_float(link_sim.get("obstruction_loss_per_meter_db")) or 0.0,
        "max_loss_db": finite_float(obstruction.get("max_loss_db")) or finite_float(link_sim.get("obstruction_loss_max_db")) or 0.0,
        "min_intersection_m": finite_float(obstruction.get("min_intersection_m")) or finite_float(link_sim.get("obstruction_min_intersection_m")) or 0.0,
        "diffraction_margin_m": finite_float(obstruction.get("diffraction_margin_m")) or finite_float(link_sim.get("obstruction_diffraction_margin_m")) or 0.0,
        "diffraction_loss_db": finite_float(obstruction.get("diffraction_loss_db")) or finite_float(link_sim.get("obstruction_diffraction_loss_db")) or 0.0,
        "edge_ramp_m": finite_float(obstruction.get("edge_ramp_m")) or finite_float(link_sim.get("obstruction_edge_ramp_m")) or 0.0,
        "obstacles": link_sim.get("obstacles", []) if isinstance(link_sim.get("obstacles", []), list) else [],
    }


def estimate_obstruction_loss_db(
    a: dict[str, float],
    b: dict[str, float],
    link_sim: dict[str, Any],
) -> float:
    cfg = obstruction_config(link_sim)
    if not cfg["enabled"]:
        return 0.0
    raw_loss = 0.0
    min_intersection = float(cfg["min_intersection_m"])
    for obs in cfg["obstacles"]:
        if not isinstance(obs, dict):
            continue
        core_length = segment_aabb_intersection_length(a, b, obs)
        if core_length >= min_intersection:
            penetration = max(0.0, core_length - min_intersection)
            edge_ramp = float(cfg["edge_ramp_m"])
            ramp_weight = smooth_step_01(penetration / edge_ramp) if edge_ramp > 0.0 else 1.0
            meter_length = penetration if edge_ramp > 0.0 else core_length
            raw_loss += (
                float(cfg["base_loss_db"])
                + ramp_weight * float(cfg["loss_per_hit_db"])
                + meter_length * float(cfg["loss_per_meter_db"])
            )
            continue

        margin = float(cfg["diffraction_margin_m"])
        diffraction_loss = float(cfg["diffraction_loss_db"])
        if margin > 0.0 and diffraction_loss > 0.0:
            shell_length = segment_aabb_intersection_length(a, b, obs, margin)
            if shell_length >= min_intersection:
                shell_penetration = max(0.0, shell_length - min_intersection)
                raw_loss += smooth_step_01(shell_penetration / margin) * diffraction_loss

    max_loss = float(cfg["max_loss_db"])
    if max_loss > 0.0:
        raw_loss = min(max_loss, raw_loss)
    return max(0.0, raw_loss)


def reference_loss_db(link_sim: dict[str, Any]) -> float:
    large_scale = link_sim.get("large_scale", {}) if isinstance(link_sim, dict) else {}
    path_loss = large_scale.get("path_loss", {}) if isinstance(large_scale, dict) else {}
    if isinstance(path_loss, dict):
        explicit = finite_float(path_loss.get("reference_loss_db"))
        if explicit is not None:
            return explicit
        ref_dist = finite_float(path_loss.get("reference_distance_m")) or 1.0
    else:
        ref_dist = 1.0
    frequency_hz = finite_float(link_sim.get("frequency_hz")) or 5.18e9
    return 20.0 * math.log10(4.0 * math.pi * ref_dist * frequency_hz / 299_792_458.0)


def estimate_path_loss_db(distance: float, link_sim: dict[str, Any]) -> float:
    large_scale = link_sim.get("large_scale", {}) if isinstance(link_sim, dict) else {}
    path_loss = large_scale.get("path_loss", {}) if isinstance(large_scale, dict) else {}
    exponent = 2.0
    ref_dist = 1.0
    if isinstance(path_loss, dict):
        exponent = finite_float(path_loss.get("exponent")) or exponent
        ref_dist = finite_float(path_loss.get("reference_distance_m")) or ref_dist
    d = max(distance, ref_dist, 1.0e-6)
    return reference_loss_db(link_sim) + 10.0 * exponent * math.log10(d / ref_dist)


def estimate_link_cost(
    raw_link: dict[str, Any],
    positions: dict[str, dict[str, float]],
    link_sim: dict[str, Any],
    node_profiles: dict[str, dict[str, Any]],
) -> tuple[float, dict[str, Any]]:
    explicit_cost = first_number(raw_link, EXPLICIT_COST_KEYS)
    if explicit_cost is not None:
        cost = max(1.0e-6, explicit_cost)
        return cost, {"cost_source": "explicit", "cost": cost}

    src = str(raw_link.get("src", ""))
    dst = str(raw_link.get("dst", ""))
    src_pos = positions.get(src)
    dst_pos = positions.get(dst)
    src_profile = node_profiles.get(src, {})
    dst_profile = node_profiles.get(dst, {})

    dist = first_number(raw_link, DISTANCE_KEYS) or 0.0
    obstruction_loss_value = first_number(raw_link, OBSTRUCTION_KEYS)
    obstruction_loss = obstruction_loss_value if obstruction_loss_value is not None else 0.0
    margin_db: float | None = None
    if src_pos and dst_pos:
        if dist <= 0.0:
            dist = distance_m(src_pos, dst_pos)
        if obstruction_loss_value is None:
            obstruction_loss = estimate_obstruction_loss_db(src_pos, dst_pos, link_sim)
        path_loss = estimate_path_loss_db(dist, link_sim)
        tx_power = first_number(raw_link, ("tx_power_dbm", "prior_tx_power_dbm"))
        if tx_power is None:
            tx_power = max(
                finite_float(src_profile.get("tx_power_dbm")) or 0.0,
                finite_float(dst_profile.get("tx_power_dbm")) or 0.0,
                finite_float(link_sim.get("tx_power_dbm")) or 20.0,
            )
        rx_sensitivity = first_number(raw_link, ("rx_sensitivity_dbm", "prior_rx_sensitivity_dbm"))
        if rx_sensitivity is None:
            rx_sensitivity = finite_float(link_sim.get("rx_sensitivity_dbm")) or -92.0
        rx_power = tx_power - path_loss - obstruction_loss
        margin_db = rx_power - rx_sensitivity

    loss = first_number(raw_link, LOSS_KEYS)
    delay_ms = first_number(raw_link, DELAY_KEYS)
    jitter_ms = first_number(raw_link, JITTER_KEYS)
    default_bandwidth = max(
        1.0e-6,
        finite_float(src_profile.get("default_bandwidth_mbps"))
        or finite_float(dst_profile.get("default_bandwidth_mbps"))
        or data_rate_mbps(link_sim.get("mac_data_rate"))
        or 20.0,
    )
    edge_bandwidth = (
        first_number(raw_link, ("bandwidth_mbps", "prior_bandwidth_mbps"))
        or data_rate_mbps(raw_link.get("data_rate"))
        or max(
            finite_float(src_profile.get("bandwidth_mbps")) or 0.0,
            finite_float(dst_profile.get("bandwidth_mbps")) or 0.0,
            default_bandwidth,
        )
    )
    edge_bandwidth = max(1.0e-6, edge_bandwidth)
    relay_penalty = 0.5 * (
        (finite_float(src_profile.get("relay_penalty")) or 0.0)
        + (finite_float(dst_profile.get("relay_penalty")) or 0.0)
    )

    cost = max(0.05, default_bandwidth / edge_bandwidth) + relay_penalty
    if dist > 0.0:
        cost += dist / 50.0
    if obstruction_loss > 0.0:
        cost += obstruction_loss / 3.0
    if margin_db is not None and margin_db < 25.0:
        cost += (25.0 - margin_db) / 5.0
        if margin_db < 0.0:
            cost += 50.0 + abs(margin_db)
    if loss is not None:
        loss = min(0.9999, max(0.0, loss))
        cost += -10.0 * math.log10(max(1.0e-6, 1.0 - loss))
    if delay_ms is not None:
        cost += max(0.0, delay_ms) / 10.0
    if jitter_ms is not None:
        cost += max(0.0, jitter_ms) / 20.0

    return max(1.0e-6, cost), {
        "cost_source": "prior_estimate",
        "cost": max(1.0e-6, cost),
        "distance_m": dist,
        "obstruction_loss_db": obstruction_loss,
        "margin_db": margin_db,
        "loss": loss,
        "delay_ms": delay_ms,
        "jitter_ms": jitter_ms,
        "bandwidth_mbps": edge_bandwidth,
        "tx_power_dbm": tx_power if src_pos and dst_pos else None,
        "resource_roles": {
            src: src_profile.get("role"),
            dst: dst_profile.get("role"),
        },
        "metrics_age_sec": first_number(raw_link, ("age_sec",)),
        "runtime_source": "link_state" if raw_link.get("link_state") else ("metrics" if raw_link.get("metrics") else "topology"),
    }


def add_edge(graph: dict[str, dict[str, float]], src: str, dst: str, cost: float) -> None:
    graph.setdefault(src, {})[dst] = min(cost, graph.setdefault(src, {}).get(dst, cost))
    graph.setdefault(dst, {})[src] = min(cost, graph.setdefault(dst, {}).get(src, cost))


def build_adaptive_graph(
    topo: dict[str, Any],
    instances: list[dict[str, Any]],
    gs_id: str,
    endpoint_cluster: dict[str, int],
    metrics_max_age_sec: float,
    routing_mode: str,
) -> tuple[dict[str, dict[str, float]], list[dict[str, Any]]]:
    globals_ = topo.get("globals", {})
    link_sim = globals_.get("link_simulation", {})
    if not isinstance(link_sim, dict):
        link_sim = {}
    positions = endpoint_positions(topo, instances, gs_id, metrics_max_age_sec)
    node_profiles = node_resource_profiles(topo, instances, link_sim)
    link_state = runtime_link_state(topo, metrics_max_age_sec)
    graph: dict[str, dict[str, float]] = {}
    link_costs: list[dict[str, Any]] = []
    uav_ids = {str(inst.get("id")) for inst in instances if inst.get("type") == "uav"}

    for raw_link in list(topo.get("links", [])) + list(topo.get("mesh_links", [])):
        if not isinstance(raw_link, dict) or not raw_link.get("enabled", True):
            continue
        src = str(raw_link.get("src", ""))
        dst = str(raw_link.get("dst", ""))
        if not src or not dst or src == dst:
            continue
        src_is_gs = src == gs_id
        dst_is_gs = dst == gs_id
        src_is_uav = src in uav_ids
        dst_is_uav = dst in uav_ids
        if (src_is_gs and dst_is_uav) or (dst_is_gs and src_is_uav):
            allowed = True
        elif src_is_uav and dst_is_uav:
            allowed = routing_mode == "adaptive_resource" or endpoint_cluster.get(src) == endpoint_cluster.get(dst)
        else:
            allowed = False
        if not allowed:
            continue

        link_id = str(raw_link.get("id", f"{src}-{dst}"))
        augmented_link = dict(raw_link)
        metric = read_pair_metrics(raw_link, metrics_max_age_sec)
        if metric:
            augmented_link["metrics"] = metric
        if link_id in link_state:
            augmented_link["link_state"] = link_state[link_id]

        cost, details = estimate_link_cost(augmented_link, positions, link_sim, node_profiles)
        add_edge(graph, src, dst, cost)
        link_costs.append(
            {
                "id": link_id,
                "src": src,
                "dst": dst,
                **details,
            }
        )

    return graph, link_costs


def shortest_paths(
    graph: dict[str, dict[str, float]],
    start: str,
) -> tuple[dict[str, float], dict[str, str]]:
    distances: dict[str, float] = {start: 0.0}
    previous: dict[str, str] = {}
    queue: list[tuple[float, str]] = [(0.0, start)]
    while queue:
        current_distance, node = heapq.heappop(queue)
        if current_distance > distances.get(node, math.inf):
            continue
        for neighbor, weight in graph.get(node, {}).items():
            candidate = current_distance + weight
            if candidate < distances.get(neighbor, math.inf):
                distances[neighbor] = candidate
                previous[neighbor] = node
                heapq.heappush(queue, (candidate, neighbor))
    return distances, previous


def path_to(previous: dict[str, str], start: str, dst: str) -> list[str]:
    if start == dst:
        return [start]
    if dst not in previous:
        return []
    path = [dst]
    while path[-1] != start:
        parent = previous.get(path[-1])
        if parent is None:
            return []
        path.append(parent)
    path.reverse()
    return path


def route_destinations(
    target: str,
    gs_id: str,
    uavs: list[dict[str, Any]],
    endpoint_cluster: dict[str, int],
    routing_mode: str,
) -> list[str]:
    if target == gs_id:
        return [str(inst.get("id")) for inst in uavs]
    if routing_mode == "adaptive_resource":
        return [gs_id] + [
            str(inst.get("id"))
            for inst in uavs
            if str(inst.get("id")) != target
        ]
    cluster_id = endpoint_cluster[target]
    destinations = [gs_id]
    destinations.extend(
        str(inst.get("id"))
        for inst in uavs
        if str(inst.get("id")) != target and endpoint_cluster[str(inst.get("id"))] == cluster_id
    )
    return destinations


def validate_cluster_heads(
    cluster_heads: dict[int, str],
    by_id: dict[str, dict[str, Any]],
) -> None:
    if not cluster_heads:
        raise SystemExit("[cluster-entries][ERR] no cluster heads configured")
    for cluster_id, head_id in cluster_heads.items():
        if head_id not in by_id:
            raise SystemExit(
                f"[cluster-entries][ERR] cluster {cluster_id} head is not a UAV: {head_id}"
            )
        head_cluster = int(by_id[head_id].get("cluster_id", -1))
        if head_cluster != cluster_id:
            raise SystemExit(
                f"[cluster-entries][ERR] head {head_id} is in cluster {head_cluster}, "
                f"not {cluster_id}"
            )


def append_entry_for_path(
    entries: list[dict[str, Any]],
    routes: dict[str, dict[str, list[str]]],
    target: str,
    dst: str,
    path: list[str],
    endpoint_ip: dict[str, str],
    endpoint_mac: dict[str, str],
    src_mac: str,
    air_port: int,
) -> None:
    if len(path) < 2:
        return
    next_hop_id = path[1]
    entries.append(table_entry(endpoint_ip[dst], endpoint_mac[next_hop_id], src_mac, air_port))
    routes.setdefault(target, {})[dst] = path


def cluster_head_route_entries(
    target: str,
    gs_id: str,
    uavs: list[dict[str, Any]],
    by_id: dict[str, dict[str, Any]],
    cluster_heads: dict[int, str],
    endpoint_cluster: dict[str, int],
    endpoint_ip: dict[str, str],
    endpoint_mac: dict[str, str],
    air_port: int,
) -> tuple[list[dict[str, Any]], dict[str, dict[str, list[str]]]]:
    validate_cluster_heads(cluster_heads, by_id)
    entries: list[dict[str, Any]] = []
    routes: dict[str, dict[str, list[str]]] = {}

    if target == gs_id:
        src_mac = endpoint_mac[gs_id]
        for inst in uavs:
            uav_id = str(inst.get("id"))
            cluster_id = endpoint_cluster[uav_id]
            head_id = cluster_heads.get(cluster_id)
            if not head_id:
                continue
            path = [gs_id, uav_id] if head_id == uav_id else [gs_id, head_id, uav_id]
            append_entry_for_path(entries, routes, target, uav_id, path, endpoint_ip, endpoint_mac, src_mac, air_port)
        return entries, routes

    if target not in by_id:
        raise SystemExit(f"[cluster-entries][ERR] unknown target id: {target}")

    cluster_id = endpoint_cluster[target]
    head_id = cluster_heads.get(cluster_id)
    if not head_id:
        return entries, routes

    src_mac = endpoint_mac[target]
    if target == head_id:
        append_entry_for_path(
            entries,
            routes,
            target,
            gs_id,
            [target, gs_id],
            endpoint_ip,
            endpoint_mac,
            src_mac,
            air_port,
        )
        for inst in uavs:
            uav_id = str(inst.get("id"))
            if uav_id == target or endpoint_cluster[uav_id] != cluster_id:
                continue
            append_entry_for_path(
                entries,
                routes,
                target,
                uav_id,
                [target, uav_id],
                endpoint_ip,
                endpoint_mac,
                src_mac,
                air_port,
            )
    else:
        append_entry_for_path(
            entries,
            routes,
            target,
            gs_id,
            [target, head_id, gs_id],
            endpoint_ip,
            endpoint_mac,
            src_mac,
            air_port,
        )
    return entries, routes


def adaptive_prior_route_entries_from_topology(
    topo: dict[str, Any],
    target: str,
    gs_id: str,
    instances: list[dict[str, Any]],
    uavs: list[dict[str, Any]],
    by_id: dict[str, dict[str, Any]],
    endpoint_cluster: dict[str, int],
    endpoint_ip: dict[str, str],
    endpoint_mac: dict[str, str],
    air_port: int,
    metrics_max_age_sec: float,
    routing_mode: str,
) -> tuple[list[dict[str, Any]], dict[str, dict[str, list[str]]], list[dict[str, Any]]]:
    if target != gs_id and target not in by_id:
        raise SystemExit(f"[cluster-entries][ERR] unknown target id: {target}")

    graph, link_costs = build_adaptive_graph(
        topo,
        instances,
        gs_id,
        endpoint_cluster,
        metrics_max_age_sec,
        routing_mode,
    )
    if target not in graph:
        raise SystemExit(f"[cluster-entries][ERR] no adaptive graph edges for target: {target}")

    distances, previous = shortest_paths(graph, target)
    entries: list[dict[str, Any]] = []
    routes: dict[str, dict[str, list[str]]] = {}
    src_mac = endpoint_mac[target]

    for dst in route_destinations(target, gs_id, uavs, endpoint_cluster, routing_mode):
        if dst not in distances:
            continue
        path = path_to(previous, target, dst)
        append_entry_for_path(entries, routes, target, dst, path, endpoint_ip, endpoint_mac, src_mac, air_port)

    return entries, routes, link_costs


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Generate BMv2 edge routing table entries"
    )
    parser.add_argument("--topology", required=True)
    parser.add_argument("--target-id", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--routing-mode", default="")
    parser.add_argument("--cluster-heads", default="")
    parser.add_argument("--gs-id", default="")
    parser.add_argument("--gs-app-if", default=os.environ.get("UCS_MESH_GS_APP_IF", "gs0"))
    parser.add_argument("--uav-exp-if", default="eth1")
    parser.add_argument(
        "--metrics-max-age-sec",
        type=float,
        default=float(os.environ.get("UCS_MESH_ROUTING_METRICS_MAX_AGE_SEC", "15")),
    )
    args = parser.parse_args()

    with open(args.topology, "r", encoding="utf-8") as f:
        topo = json.load(f)

    globals_ = topo.get("globals", {})
    gs_id = args.gs_id or str(globals_.get("gs_id", "gs"))
    air_port = resolve_air_port(topo)

    programmable = topo.get("programmable_net", globals_.get("programmable_net", {}))
    routing = programmable.get("routing", {}) if isinstance(programmable, dict) else {}
    routing_mode = normalize_routing_mode(args.routing_mode or routing.get("mode", "cluster_heads"))
    configured_heads = routing.get("cluster_heads", {}) if isinstance(routing, dict) else {}

    cluster_heads = {int(k): str(v) for k, v in configured_heads.items()}
    cluster_heads.update(parse_cluster_heads(args.cluster_heads))

    instances = topo.get("instances", [])
    gs_inst = next((inst for inst in instances if inst.get("id") == gs_id), None)
    if not gs_inst:
        raise SystemExit(f"[cluster-entries][ERR] GS instance not found: {gs_id}")

    uavs = [inst for inst in instances if inst.get("type") == "uav"]
    by_id = {str(inst.get("id")): inst for inst in uavs}

    gs_ip = cidr_ip(str(gs_inst.get("exp_ip") or gs_inst.get("exp_ips", ["10.10.0.254/24"])[0]))
    gs_mac = read_host_mac(args.gs_app_if)

    endpoint_mac: dict[str, str] = {gs_id: gs_mac}
    endpoint_ip: dict[str, str] = {gs_id: gs_ip}
    endpoint_cluster: dict[str, int] = {gs_id: int(gs_inst.get("cluster_id", 0))}

    for inst in uavs:
        uav_id = str(inst.get("id"))
        container = str(inst.get("container_name", uav_id))
        exp_if = str(inst.get("exp_if", args.uav_exp_if))
        endpoint_mac[uav_id] = read_container_mac(container, exp_if)
        endpoint_ip[uav_id] = cidr_ip(str(inst["exp_ip"]))
        endpoint_cluster[uav_id] = int(inst.get("cluster_id", 1))

    target = args.target_id
    link_costs: list[dict[str, Any]] = []
    if routing_mode == "cluster_heads":
        entries, routes = cluster_head_route_entries(
            target,
            gs_id,
            uavs,
            by_id,
            cluster_heads,
            endpoint_cluster,
            endpoint_ip,
            endpoint_mac,
            air_port,
        )
    else:
        entries, routes, link_costs = adaptive_prior_route_entries_from_topology(
            topo,
            target,
            gs_id,
            instances,
            uavs,
            by_id,
            endpoint_cluster,
            endpoint_ip,
            endpoint_mac,
            air_port,
            args.metrics_max_age_sec,
            routing_mode,
        )

    payload = {
        "mode": routing_mode,
        "target_id": target,
        "cluster_heads": {str(k): v for k, v in sorted(cluster_heads.items())},
        "air_port": air_port,
        "routes": routes,
        "link_costs": link_costs,
        "metrics_max_age_sec": args.metrics_max_age_sec,
        "resource_nodes": [
            node_id
            for node_id, profile in node_resource_profiles(
                topo,
                instances,
                globals_.get("link_simulation", {}) if isinstance(globals_.get("link_simulation", {}), dict) else {},
            ).items()
            if profile.get("is_resource")
        ],
        "entries": entries,
    }

    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(
        f"[cluster-entries] wrote {output} mode={routing_mode} "
        f"entries={len(entries)} target={target}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
