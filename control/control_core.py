#!/usr/bin/env python3
"""Topology-driven MAVSDK offboard control core for the BMv2 mesh stage."""

from __future__ import annotations

import argparse
import asyncio
import contextlib
import csv
import ipaddress
import json
import signal
import time
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any, Callable, Dict, Optional, Set

from mavsdk import System
from mavsdk.action import ActionError
from mavsdk.offboard import OffboardError, VelocityBodyYawspeed


SCRIPT_DIR = Path(__file__).resolve().parents[1]
DEFAULT_TOPOLOGY = SCRIPT_DIR / "topologies" / "wifi_adhoc_matrix_2x3_6uav.json"

VALID_KEYS: Set[str] = {"w", "a", "s", "d", "q", "e", "z", "x", "c", "l", "h", "j", "k"}
HOLD_KEYS: Set[str] = {"w", "a", "s", "d", "q", "e", "z", "x"}


@dataclass
class Target:
    uav_id: str
    idx: int
    exp_ip: str
    qgc_port: int
    mavsdk_local_port: int
    mavsdk_remote_port: int
    mavsdk_remote_ip: str
    mav_sys_id: int
    model_name: str
    container_name: str
    mavsdk_url: str


@dataclass
class ControlState:
    type: str = "status"
    connected: bool = False
    armed: bool = False
    in_air: bool = False
    offboard_active: bool = False
    vx: float = 0.0
    vy: float = 0.0
    vz: float = 0.0
    yawrate: float = 0.0
    throttle: float = 0.30
    max_horizontal_speed_mps: float = 6.0
    max_vertical_speed_mps: float = 3.0
    max_yaw_rate_deg_s: float = 45.0
    target_yaw_deg: Optional[float] = None
    actual_relative_altitude_m: Optional[float] = None
    actual_abs_altitude_m: Optional[float] = None
    yaw_deg: Optional[float] = None
    battery_percent: Optional[float] = None
    health_all_ok: Optional[bool] = None
    last_event: str = "init"
    last_error: str = ""
    last_log: str = "controller init"
    target_uav: str = ""
    mavsdk_url: str = ""
    mavsdk_server: str = ""
    updated_at: float = field(default_factory=time.time)

    def snapshot(self) -> Dict[str, Any]:
        data = asdict(self)
        data["updated_at"] = time.time()
        return data


class CsvTraceWriter:
    def __init__(self, path: str, fieldnames: list[str]):
        self.path = path
        self.fieldnames = fieldnames
        self.fp = None
        self.writer = None
        if path:
            p = Path(path)
            p.parent.mkdir(parents=True, exist_ok=True)
            self.fp = p.open("w", newline="", encoding="utf-8")
            self.writer = csv.DictWriter(self.fp, fieldnames=fieldnames)
            self.writer.writeheader()
            self.fp.flush()

    def write(self, row: Dict[str, Any]) -> None:
        if not self.writer:
            return
        self.writer.writerow({key: row.get(key, "") for key in self.fieldnames})
        self.fp.flush()

    def close(self) -> None:
        if self.fp:
            self.fp.flush()
            self.fp.close()
            self.fp = None
            self.writer = None


class JsonLineServer:
    def __init__(self, host: str, port: int):
        self.host = host
        self.port = port
        self.server: Optional[asyncio.AbstractServer] = None
        self.clients = set()
        self.on_message = None

    async def start(self) -> None:
        self.server = await asyncio.start_server(self._handle_client, self.host, self.port)

    async def close(self) -> None:
        if self.server is not None:
            self.server.close()
            await self.server.wait_closed()
            self.server = None
        for writer in list(self.clients):
            with contextlib.suppress(Exception):
                writer.close()
                await writer.wait_closed()
        self.clients.clear()

    async def broadcast(self, message: Dict[str, Any]) -> None:
        raw = (json.dumps(message, ensure_ascii=False) + "\n").encode("utf-8")
        dead = []
        for writer in list(self.clients):
            try:
                writer.write(raw)
                await writer.drain()
            except Exception:
                dead.append(writer)
        for writer in dead:
            self.clients.discard(writer)
            with contextlib.suppress(Exception):
                writer.close()
                await writer.wait_closed()

    async def _handle_client(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        self.clients.add(writer)
        try:
            while True:
                raw = await reader.readline()
                if not raw:
                    break
                try:
                    payload = json.loads(raw.decode("utf-8", errors="replace").strip())
                except json.JSONDecodeError:
                    continue
                if self.on_message is not None:
                    await self.on_message(payload, writer)
        finally:
            self.clients.discard(writer)
            with contextlib.suppress(Exception):
                writer.close()
                await writer.wait_closed()


def ip_only(value: str) -> str:
    if "/" in value:
        return str(ipaddress.ip_interface(value).ip)
    return str(ipaddress.ip_address(value))


def topology_ground_station_ip(topo: Dict[str, Any]) -> str:
    globals_ = topo.get("globals", {})
    experiment_net = globals_.get("experiment_net", {}) if isinstance(globals_, dict) else {}
    if isinstance(experiment_net, dict):
        gs_ips = experiment_net.get("gs_ips", [])
        if isinstance(gs_ips, list) and gs_ips:
            return ip_only(str(gs_ips[0]))
    for inst in topo.get("instances", []):
        if inst.get("type") == "ground_station" and inst.get("exp_ip"):
            return ip_only(str(inst["exp_ip"]))
    return "10.10.0.254"


def resolve_mavsdk_endpoint(topo: Dict[str, Any], selected: Dict[str, Any], idx: int, override_url: str) -> Dict[str, Any]:
    globals_ = topo.get("globals", {})
    business_flows = globals_.get("business_flows", {}) if isinstance(globals_, dict) else {}
    control_flow = business_flows.get("control", {}) if isinstance(business_flows, dict) else {}
    mavsdk_flow = control_flow.get("mavsdk", {}) if isinstance(control_flow, dict) else {}
    if not isinstance(mavsdk_flow, dict):
        mavsdk_flow = {}

    local_port = int(selected.get("mavsdk_local_port", int(mavsdk_flow.get("uav_local_port_base", 18600)) + idx))
    remote_port = int(selected.get("mavsdk_remote_port", int(mavsdk_flow.get("gs_remote_port_base", 14600)) + idx))
    remote_ip_raw = str(selected.get("mavsdk_remote_ip") or mavsdk_flow.get("remote_ip") or topology_ground_station_ip(topo))
    if remote_ip_raw == "ground_station.exp_ip":
        remote_ip_raw = topology_ground_station_ip(topo)
    remote_ip = ip_only(remote_ip_raw)
    resolved_url = override_url or str(selected.get("mavsdk_url") or f"udpin://0.0.0.0:{remote_port}")
    return {
        "local_port": local_port,
        "remote_port": remote_port,
        "remote_ip": remote_ip,
        "url": resolved_url,
    }


def resolve_target(topology: Path, uav: str, idx: Optional[int], mavsdk_url: str) -> Target:
    topo = json.loads(topology.read_text(encoding="utf-8"))
    selected = None
    for inst in topo.get("instances", []):
        if inst.get("type") != "uav":
            continue
        inst_id = str(inst.get("id") or inst.get("name"))
        aliases = {inst_id, str(inst.get("name", "")), str(inst.get("container_name", ""))}
        if uav and uav in aliases:
            selected = inst
            break
        if idx is not None and int(inst.get("idx", 0)) == idx:
            selected = inst
            break
    if selected is None:
        raise SystemExit(f"[control_core][ERR] target UAV not found: uav={uav!r} idx={idx!r}")

    inst_id = str(selected.get("id") or selected.get("name"))
    target_idx = int(selected.get("idx", 0))
    exp_ip = ip_only(str(selected["exp_ip"]))
    qgc_port = int(selected["qgc_port"])
    mavsdk_endpoint = resolve_mavsdk_endpoint(topo, selected, target_idx, mavsdk_url)
    return Target(
        uav_id=inst_id,
        idx=target_idx,
        exp_ip=exp_ip,
        qgc_port=qgc_port,
        mavsdk_local_port=int(mavsdk_endpoint["local_port"]),
        mavsdk_remote_port=int(mavsdk_endpoint["remote_port"]),
        mavsdk_remote_ip=str(mavsdk_endpoint["remote_ip"]),
        mav_sys_id=int(selected.get("mav_sys_id", target_idx)),
        model_name=str(selected.get("model_name", inst_id)),
        container_name=str(selected.get("container_name", inst_id)),
        mavsdk_url=str(mavsdk_endpoint["url"]),
    )


class ControlCore:
    def __init__(self, args: argparse.Namespace, target: Target):
        self.args = args
        self.target = target
        self.start_wall = time.time()
        self.state = ControlState(
            throttle=args.initial_throttle,
            max_horizontal_speed_mps=args.max_horizontal_speed_mps,
            max_vertical_speed_mps=args.max_vertical_speed_mps,
            max_yaw_rate_deg_s=args.max_yaw_rate_deg_s,
            target_uav=target.uav_id,
            mavsdk_url=target.mavsdk_url,
            mavsdk_server=f"{args.mavsdk_server_host}:{args.mavsdk_server_port}",
        )
        self.keys: Dict[str, bool] = {key: False for key in VALID_KEYS}
        self.msg_server = JsonLineServer(args.listen_host, args.listen_port)
        self.msg_server.on_message = self.handle_message
        self.drone = System(
            mavsdk_server_address=args.mavsdk_server_host,
            port=args.mavsdk_server_port,
        )
        self.last_telemetry_wall = 0.0
        self.shutdown_event = asyncio.Event()
        self.command_lock = asyncio.Lock()
        self.arm_offboard_task: Optional[asyncio.Task] = None
        self.last_arm_request_wall = 0.0
        self.telemetry_tasks: list[asyncio.Task] = []
        self.background_tasks: list[asyncio.Task] = []
        self.control_trace = CsvTraceWriter(args.control_trace_path, [
            "wall_time", "rel_time_s", "target_uav", "kind", "event", "key",
            "vx", "vy", "vz", "yawrate", "throttle",
            "connected", "armed", "in_air", "offboard_active",
        ])
        self.event_trace = CsvTraceWriter(args.event_trace_path, [
            "wall_time", "rel_time_s", "target_uav", "source", "event", "detail",
            "connected", "armed", "in_air", "offboard_active",
        ])

    def normalized_speed_text(self) -> str:
        return (
            f"{self.state.throttle:.2f} "
            f"(xy={self.state.throttle * self.state.max_horizontal_speed_mps:.2f}m/s "
            f"z={self.state.throttle * self.state.max_vertical_speed_mps:.2f}m/s "
            f"yaw={self.state.throttle * self.state.max_yaw_rate_deg_s:.1f}deg/s)"
        )

    def now_base(self) -> Dict[str, Any]:
        now = time.time()
        return {
            "wall_time": f"{now:.6f}",
            "rel_time_s": f"{now - self.start_wall:.6f}",
            "target_uav": self.target.uav_id,
        }

    def write_control_trace(self, *, kind: str, event: str, key: str = "") -> None:
        row = self.now_base()
        row.update({
            "kind": kind,
            "event": event,
            "key": key,
            "vx": f"{self.state.vx:.3f}",
            "vy": f"{self.state.vy:.3f}",
            "vz": f"{self.state.vz:.3f}",
            "yawrate": f"{self.state.yawrate:.3f}",
            "throttle": f"{self.state.throttle:.3f}",
            "connected": int(self.state.connected),
            "armed": int(self.state.armed),
            "in_air": int(self.state.in_air),
            "offboard_active": int(self.state.offboard_active),
        })
        self.control_trace.write(row)

    def write_event_trace(self, *, source: str, event: str, detail: str = "") -> None:
        row = self.now_base()
        row.update({
            "source": source,
            "event": event,
            "detail": detail,
            "connected": int(self.state.connected),
            "armed": int(self.state.armed),
            "in_air": int(self.state.in_air),
            "offboard_active": int(self.state.offboard_active),
        })
        self.event_trace.write(row)

    async def log(self, text: str, *, error: bool = False, source: str = "control_core", event: str = "log") -> None:
        self.state.last_log = text
        self.state.updated_at = time.time()
        if error:
            self.state.last_error = text
        await self.msg_server.broadcast({
            "type": "log",
            "level": "error" if error else "info",
            "message": text,
            "target_uav": self.target.uav_id,
            "ts": time.time(),
        })
        self.write_event_trace(source=source, event=event, detail=text)
        print(text, flush=True)

    async def publish_status(self) -> None:
        await self.msg_server.broadcast(self.state.snapshot())

    def message_targets_this_core(self, message: Dict[str, Any]) -> bool:
        requested = str(message.get("uav") or message.get("target_uav") or "")
        return not requested or requested == self.target.uav_id

    async def handle_message(self, message: Dict[str, Any], writer: asyncio.StreamWriter) -> None:
        if not self.message_targets_this_core(message):
            await self.log(
                f"[ignore] message for {message.get('uav') or message.get('target_uav')}; target is {self.target.uav_id}",
                error=True,
                event="wrong_target_ignored",
            )
            return
        mtype = str(message.get("type", "")).lower()
        if mtype == "hello":
            await self.publish_status()
            return
        if mtype == "ping":
            writer.write((json.dumps({"type": "pong", "ts": time.time()}) + "\n").encode("utf-8"))
            await writer.drain()
            return
        if mtype == "key":
            await self.handle_key_message(message)
            return
        if mtype == "command":
            await self.handle_command_message(message)

    async def handle_key_message(self, message: Dict[str, Any]) -> None:
        key = str(message.get("key", "")).lower()
        action = str(message.get("action", "")).lower()
        if key not in VALID_KEYS or action not in {"press", "release"}:
            return
        self.write_control_trace(kind="key", event=action, key=key)
        if key in HOLD_KEYS:
            self.keys[key] = action == "press"
            self.state.last_event = f"{action}:{key}"
            return
        if action != "press":
            return
        self.state.last_event = f"pulse:{key}"
        if key == "j":
            self.state.throttle = max(self.args.min_throttle, self.state.throttle - self.args.throttle_step)
            await self.log(f"[speed] decrease -> {self.normalized_speed_text()}", event="speed_decrease")
        elif key == "k":
            self.state.throttle = min(self.args.max_throttle, self.state.throttle + self.args.throttle_step)
            await self.log(f"[speed] increase -> {self.normalized_speed_text()}", event="speed_increase")
        elif key == "c":
            await self.request_arm_offboard("key:c")
        elif key == "l":
            asyncio.create_task(self.land())
        elif key == "h":
            asyncio.create_task(self.rtl())

    async def handle_command_message(self, message: Dict[str, Any]) -> None:
        name = str(message.get("name", "")).lower()
        if name == "release_all":
            self.release_all_keys()
            self.write_control_trace(kind="command", event="release_all")
            return
        if name == "set_throttle":
            value = float(message.get("value", self.state.throttle))
            self.state.throttle = max(self.args.min_throttle, min(self.args.max_throttle, value))
            self.write_control_trace(kind="command", event="set_throttle")
            await self.log(f"[speed] set -> {self.normalized_speed_text()}", event="speed_set")
            return
        if name == "sync_status":
            await self.publish_status()
            return
        if name == "arm_offboard":
            await self.request_arm_offboard("command")
            return
        if name == "land":
            asyncio.create_task(self.land())
            return
        if name == "rtl":
            asyncio.create_task(self.rtl())

    def release_all_keys(self) -> None:
        for key in HOLD_KEYS:
            self.keys[key] = False
        self.state.vx = 0.0
        self.state.vy = 0.0
        self.state.vz = 0.0
        self.state.yawrate = 0.0
        self.state.last_event = "release_all"

    async def wait_connected(self) -> None:
        first_attempt = True
        while not self.shutdown_event.is_set():
            if first_attempt:
                await self.log(
                    f"[connect] target={self.target.uav_id} mavsdk_server={self.state.mavsdk_server} system={self.target.mavsdk_url}",
                    event="connect_begin",
                )
                first_attempt = False
            try:
                if self.args.server_owns_connection:
                    await self.drone.connect()
                else:
                    await self.drone.connect(system_address=self.target.mavsdk_url)
                async for conn in self.drone.core.connection_state():
                    self.state.connected = conn.is_connected
                    if conn.is_connected:
                        self.mark_vehicle_observed()
                        await self.log("[connect] vehicle connected", event="vehicle_connected")
                        await self.refresh_speed_limits_from_px4()
                        return
                    if self.shutdown_event.is_set():
                        return
            except Exception as exc:
                self.state.connected = False
                await self.log(
                    f"[connect] waiting for MAVSDK/PX4 discovery: {type(exc).__name__}: {exc}",
                    error=True,
                    event="connect_retry",
                )
                await asyncio.sleep(self.args.connect_retry_sec)

    def mark_vehicle_observed(self) -> None:
        self.last_telemetry_wall = time.time()
        self.state.connected = True

    def vehicle_link_active(self) -> bool:
        return self.state.connected or (time.time() - self.last_telemetry_wall) < 3.0

    @staticmethod
    def is_timeout_error(exc: Exception) -> bool:
        text = f"{type(exc).__name__}: {exc}".lower()
        return "timeout" in text or "timed out" in text

    async def request_arm_offboard(self, source: str) -> None:
        if self.arm_offboard_task is not None and not self.arm_offboard_task.done():
            await self.log(
                f"[ignore] arm_offboard from {source} while previous sequence is still running",
                event="arm_offboard_busy",
            )
            return
        if self.command_lock.locked():
            await self.log(
                f"[ignore] arm_offboard from {source} while command pipeline is busy",
                event="arm_offboard_pipeline_busy",
            )
            return
        now = time.monotonic()
        cooldown = max(0.0, self.args.arm_command_cooldown_sec)
        if cooldown and (now - self.last_arm_request_wall) < cooldown:
            await self.log(
                f"[ignore] arm_offboard from {source} within {cooldown:.1f}s cooldown",
                event="arm_offboard_cooldown",
            )
            return
        self.last_arm_request_wall = now
        self.arm_offboard_task = asyncio.create_task(self.arm_takeoff_and_start_offboard())
        self.arm_offboard_task.add_done_callback(self._arm_offboard_task_done)

    def _arm_offboard_task_done(self, task: asyncio.Task) -> None:
        if self.arm_offboard_task is task:
            self.arm_offboard_task = None

    async def px4_param_float(self, name: str) -> Optional[float]:
        try:
            value = await self.drone.param.get_param_float(name)
            value = float(value)
            if value > 0.0:
                return value
        except Exception:
            return None
        return None

    async def refresh_speed_limits_from_px4(self) -> None:
        xy = await self.px4_param_float("MPC_XY_VEL_MAX")
        z_up = await self.px4_param_float("MPC_Z_VEL_MAX_UP")
        z_dn = await self.px4_param_float("MPC_Z_VEL_MAX_DN")

        updated = []
        if xy is not None:
            self.state.max_horizontal_speed_mps = xy
            updated.append(f"xy={xy:.2f}m/s")
        z_values = [value for value in (z_up, z_dn) if value is not None]
        if z_values:
            z = max(z_values)
            self.state.max_vertical_speed_mps = z
            updated.append(f"z={z:.2f}m/s")

        if updated:
            await self.log(f"[speed] PX4 limits loaded: {' '.join(updated)}", event="speed_limits_px4")
        else:
            await self.log(
                "[speed] using configured limits: "
                f"xy={self.state.max_horizontal_speed_mps:.2f}m/s "
                f"z={self.state.max_vertical_speed_mps:.2f}m/s",
                event="speed_limits_configured",
            )

    async def telemetry_watch_connection(self) -> None:
        async for conn in self.drone.core.connection_state():
            if conn.is_connected:
                self.mark_vehicle_observed()
            elif (time.time() - self.last_telemetry_wall) >= 3.0:
                self.state.connected = False

    async def telemetry_watch_armed(self) -> None:
        async for value in self.drone.telemetry.armed():
            self.mark_vehicle_observed()
            self.state.armed = value

    async def telemetry_watch_in_air(self) -> None:
        async for value in self.drone.telemetry.in_air():
            self.mark_vehicle_observed()
            self.state.in_air = value
            if not value and self.state.offboard_active:
                self.state.offboard_active = False

    async def telemetry_watch_position(self) -> None:
        async for pos in self.drone.telemetry.position():
            self.mark_vehicle_observed()
            self.state.actual_relative_altitude_m = pos.relative_altitude_m
            self.state.actual_abs_altitude_m = pos.absolute_altitude_m

    async def telemetry_watch_attitude(self) -> None:
        async for angle in self.drone.telemetry.attitude_euler():
            self.mark_vehicle_observed()
            self.state.yaw_deg = angle.yaw_deg

    async def telemetry_watch_battery(self) -> None:
        async for battery in self.drone.telemetry.battery():
            self.mark_vehicle_observed()
            self.state.battery_percent = battery.remaining_percent * 100.0

    async def telemetry_watch_health(self) -> None:
        async for ok in self.drone.telemetry.health_all_ok():
            self.mark_vehicle_observed()
            self.state.health_all_ok = ok

    async def start_telemetry_tasks(self) -> None:
        self.telemetry_tasks = [
            asyncio.create_task(self.telemetry_watch_connection()),
            asyncio.create_task(self.telemetry_watch_armed()),
            asyncio.create_task(self.telemetry_watch_in_air()),
            asyncio.create_task(self.telemetry_watch_position()),
            asyncio.create_task(self.telemetry_watch_attitude()),
            asyncio.create_task(self.telemetry_watch_battery()),
            asyncio.create_task(self.telemetry_watch_health()),
        ]

    @staticmethod
    def wrap_angle_deg(angle_deg: float) -> float:
        return ((angle_deg + 180.0) % 360.0) - 180.0

    @staticmethod
    def clamp(value: float, lower: float, upper: float) -> float:
        return max(lower, min(upper, value))

    def ensure_target_yaw(self) -> None:
        if self.state.target_yaw_deg is None and self.state.yaw_deg is not None:
            self.state.target_yaw_deg = self.state.yaw_deg

    def emitted_yawrate(self) -> float:
        manual = self.state.yawrate
        self.ensure_target_yaw()
        if self.state.target_yaw_deg is None or self.state.yaw_deg is None:
            return manual
        err = self.wrap_angle_deg(self.state.target_yaw_deg - self.state.yaw_deg)
        hold = 0.0 if abs(err) < self.args.yaw_hold_deadband_deg else self.args.yaw_hold_kp * err
        return self.clamp(manual + hold, -self.args.max_yaw_rate_deg_s, self.args.max_yaw_rate_deg_s)

    def update_setpoint_from_keys(self) -> None:
        norm = self.clamp(self.state.throttle, 0.0, 1.0)
        horizontal_step = norm * self.state.max_horizontal_speed_mps
        vertical_step = norm * self.state.max_vertical_speed_mps
        yaw_step = norm * self.state.max_yaw_rate_deg_s
        self.state.vx = 0.0
        self.state.vy = 0.0
        self.state.vz = 0.0
        self.state.yawrate = 0.0
        if self.keys["w"]:
            self.state.vx += horizontal_step
        if self.keys["s"]:
            self.state.vx -= horizontal_step
        if self.keys["d"]:
            self.state.vy += horizontal_step
        if self.keys["a"]:
            self.state.vy -= horizontal_step
        if self.keys["z"]:
            self.state.vz -= vertical_step
        if self.keys["x"]:
            self.state.vz += vertical_step
        if self.keys["q"]:
            self.state.yawrate -= yaw_step
        if self.keys["e"]:
            self.state.yawrate += yaw_step
        if self.state.yawrate and self.state.target_yaw_deg is not None:
            self.state.target_yaw_deg = self.wrap_angle_deg(
                self.state.target_yaw_deg + self.state.yawrate * self.args.control_period_sec
            )

    async def arm_takeoff_and_start_offboard(self) -> None:
        async with self.command_lock:
            try:
                if not self.vehicle_link_active():
                    await self.log("[ignore] arm_offboard while vehicle not connected", error=True, event="arm_offboard_ignored")
                    return
                if self.state.offboard_active:
                    await self.log("[offboard] already active", event="offboard_already_active")
                    return
                self.state.target_yaw_deg = self.state.yaw_deg
                with contextlib.suppress(Exception):
                    await self.drone.param.set_param_float("COM_OF_LOSS_T", self.args.offboard_loss_timeout_sec)
                if not await self.arm_and_confirm():
                    return
                try:
                    await self.drone.action.set_takeoff_altitude(self.args.takeoff_altitude_m)
                except Exception as exc:
                    await self.log(
                        f"[warn] set takeoff altitude failed: {exc}",
                        error=True,
                        event="takeoff_altitude_failed",
                    )
                if not self.state.in_air:
                    if not await self.takeoff_and_confirm():
                        return
                if not await self.start_offboard_with_retries():
                    return
            except OffboardError as exc:
                self.state.offboard_active = False
                await self.log(f"[error] offboard start failed: {exc}", error=True, event="offboard_start_failed")
            except Exception as exc:
                self.state.offboard_active = False
                await self.log(f"[error] arm/takeoff/offboard failed: {exc}", error=True, event="arm_offboard_failed")

    async def arm_and_confirm(self) -> bool:
        if self.state.armed:
            await self.log("[action] already armed", event="arm_already_confirmed")
            return True
        await self.log("[action] arming...", event="arm_cmd")
        try:
            await self.drone.action.arm()
        except ActionError as exc:
            if not self.is_timeout_error(exc):
                await self.log(f"[error] arm failed: {exc}", error=True, event="arm_failed")
                return False
            await self.log(
                f"[warn] arm ACK timed out; waiting for armed telemetry: {exc}",
                error=True,
                event="arm_ack_timeout",
            )
        except Exception as exc:
            if not self.is_timeout_error(exc):
                await self.log(f"[error] arm failed: {exc}", error=True, event="arm_failed")
                return False
            await self.log(
                f"[warn] arm result timed out; waiting for armed telemetry: {exc}",
                error=True,
                event="arm_ack_timeout",
            )
        if not await self.wait_for_state(
            lambda: self.state.armed,
            timeout_sec=self.args.arm_wait_sec,
            event="arm_wait_timeout",
            label="armed",
        ):
            return False
        await self.log("[action] armed confirmed", event="arm_confirmed")
        return True

    async def takeoff_and_confirm(self) -> bool:
        await self.log(f"[action] takeoff to {self.args.takeoff_altitude_m:.1f}m", event="takeoff_cmd")
        try:
            await self.drone.action.takeoff()
        except Exception as exc:
            if not self.is_timeout_error(exc):
                await self.log(f"[error] takeoff failed: {exc}", error=True, event="takeoff_failed")
                return False
            await self.log(
                f"[warn] takeoff ACK timed out; waiting for in_air telemetry: {exc}",
                error=True,
                event="takeoff_ack_timeout",
            )
        if not await self.wait_for_state(
            lambda: self.state.in_air,
            timeout_sec=self.args.takeoff_wait_sec,
            event="takeoff_wait_timeout",
            label="in_air",
        ):
            return False
        await self.log("[action] takeoff confirmed", event="takeoff_confirmed")
        return True

    async def start_offboard_with_retries(self) -> bool:
        attempts = max(1, int(self.args.offboard_start_retries) + 1)
        for attempt in range(1, attempts + 1):
            try:
                await self.prime_offboard_setpoints()
                await self.drone.offboard.start()
                self.state.offboard_active = True
                await self.log("[offboard] started", event="offboard_started")
                return True
            except Exception as exc:
                self.state.offboard_active = False
                last = attempt >= attempts
                level = "error" if last else "warn"
                event = "offboard_start_failed" if last else "offboard_start_retry"
                await self.log(
                    f"[{level}] offboard start attempt {attempt}/{attempts} failed: {exc}",
                    error=last,
                    event=event,
                )
                if not last:
                    await asyncio.sleep(max(0.0, self.args.offboard_retry_delay_sec))
        return False

    async def wait_for_state(
        self,
        predicate: Callable[[], bool],
        *,
        timeout_sec: float,
        event: str,
        label: str,
    ) -> bool:
        deadline = time.monotonic() + max(0.0, timeout_sec)
        while time.monotonic() < deadline:
            if predicate():
                return True
            await asyncio.sleep(min(0.1, max(0.02, self.args.control_period_sec)))
        if predicate():
            return True
        await self.log(f"[warn] timed out waiting for {label}", error=True, event=event)
        return False

    async def prime_offboard_setpoints(self) -> None:
        interval = min(0.1, max(0.02, self.args.control_period_sec))
        deadline = time.monotonic() + max(interval, self.args.offboard_prime_sec)
        count = 0
        failures = 0
        first_error: Optional[Exception] = None
        while time.monotonic() < deadline:
            try:
                await self.drone.offboard.set_velocity_body(VelocityBodyYawspeed(0.0, 0.0, 0.0, 0.0))
                count += 1
            except Exception as exc:
                failures += 1
                if first_error is None:
                    first_error = exc
            await asyncio.sleep(interval)
        try:
            await self.drone.offboard.set_velocity_body(VelocityBodyYawspeed(0.0, 0.0, 0.0, 0.0))
            count += 1
        except Exception as exc:
            failures += 1
            if first_error is None:
                first_error = exc
        if count <= 0 and first_error is not None:
            raise first_error
        await self.log(f"[offboard] primed {count} neutral setpoints", event="offboard_primed")
        if failures:
            await self.log(
                f"[warn] ignored {failures} transient offboard setpoint failures during prime",
                error=True,
                event="offboard_prime_partial",
            )

    async def stop_offboard_if_needed(self, reason: str) -> None:
        if not self.state.offboard_active:
            return
        with contextlib.suppress(Exception):
            await self.drone.offboard.stop()
        self.state.offboard_active = False
        self.release_all_keys()
        self.write_event_trace(source="control_core", event="offboard_stopped", detail=reason)

    async def land(self) -> None:
        async with self.command_lock:
            await self.log("[action] land", event="land_cmd")
            await self.stop_offboard_if_needed("land")
            with contextlib.suppress(Exception):
                await self.drone.action.land()

    async def rtl(self) -> None:
        async with self.command_lock:
            await self.log("[action] rtl", event="rtl_cmd")
            await self.stop_offboard_if_needed("rtl")
            with contextlib.suppress(Exception):
                await self.drone.action.return_to_launch()

    async def control_loop(self) -> None:
        while not self.shutdown_event.is_set():
            if self.state.offboard_active:
                self.update_setpoint_from_keys()
                try:
                    await self.drone.offboard.set_velocity_body(
                        VelocityBodyYawspeed(self.state.vx, self.state.vy, self.state.vz, self.emitted_yawrate())
                    )
                    self.write_control_trace(kind="setpoint", event="emit")
                except Exception as exc:
                    self.state.offboard_active = False
                    await self.log(f"[error] setpoint failed: {exc}", error=True, event="setpoint_failed")
            await asyncio.sleep(self.args.control_period_sec)

    async def status_loop(self) -> None:
        while not self.shutdown_event.is_set():
            await self.publish_status()
            await asyncio.sleep(self.args.status_period_sec)

    async def run(self) -> None:
        await self.msg_server.start()
        await self.log(
            f"[server] control_core listen on {self.args.listen_host}:{self.args.listen_port} target={self.target.uav_id}",
            event="server_started",
        )
        await self.wait_connected()
        await self.start_telemetry_tasks()
        self.background_tasks = [
            asyncio.create_task(self.control_loop()),
            asyncio.create_task(self.status_loop()),
        ]
        await self.shutdown_event.wait()

    async def shutdown(self) -> None:
        if self.shutdown_event.is_set():
            return
        self.shutdown_event.set()
        with contextlib.suppress(Exception):
            await self.log("[shutdown] stopping control_core", event="shutdown")
        for task in self.background_tasks + self.telemetry_tasks:
            task.cancel()
        if self.arm_offboard_task is not None and not self.arm_offboard_task.done():
            self.arm_offboard_task.cancel()
        for task in self.background_tasks + self.telemetry_tasks:
            with contextlib.suppress(asyncio.CancelledError, Exception):
                await task
        if self.arm_offboard_task is not None:
            with contextlib.suppress(asyncio.CancelledError, Exception):
                await self.arm_offboard_task
        with contextlib.suppress(Exception):
            await self.stop_offboard_if_needed("shutdown")
        await self.msg_server.close()
        self.control_trace.close()
        self.event_trace.close()


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--topology", default=str(DEFAULT_TOPOLOGY))
    parser.add_argument("--uav", default="uav04")
    parser.add_argument("--idx", type=int)
    parser.add_argument("--mavsdk-url", default="")
    parser.add_argument("--server-owns-connection", action="store_true")
    parser.add_argument("--listen-host", default="127.0.0.1")
    parser.add_argument("--listen-port", type=int, default=9001)
    parser.add_argument("--mavsdk-server-host", default="127.0.0.1")
    parser.add_argument("--mavsdk-server-port", type=int, default=50051)
    parser.add_argument("--connect-retry-sec", type=float, default=2.0)
    parser.add_argument("--initial-throttle", type=float, default=0.30)
    parser.add_argument("--min-throttle", type=float, default=0.05)
    parser.add_argument("--max-throttle", type=float, default=1.00)
    parser.add_argument("--throttle-step", type=float, default=0.05)
    parser.add_argument("--max-horizontal-speed-mps", type=float, default=6.0)
    parser.add_argument("--max-vertical-speed-mps", type=float, default=3.0)
    parser.add_argument("--yaw-step-deg", type=float, default=10.0)
    parser.add_argument("--yaw-hold-kp", type=float, default=2.2)
    parser.add_argument("--max-yaw-rate-deg-s", type=float, default=45.0)
    parser.add_argument("--yaw-hold-deadband-deg", type=float, default=0.5)
    parser.add_argument("--takeoff-altitude-m", type=float, default=3.0)
    parser.add_argument("--arm-wait-sec", type=float, default=8.0)
    parser.add_argument("--takeoff-wait-sec", type=float, default=10.0)
    parser.add_argument("--offboard-prime-sec", type=float, default=1.2)
    parser.add_argument("--offboard-start-retries", type=int, default=2)
    parser.add_argument("--offboard-retry-delay-sec", type=float, default=0.7)
    parser.add_argument("--arm-command-cooldown-sec", type=float, default=2.0)
    parser.add_argument("--offboard-loss-timeout-sec", type=float, default=5.0)
    parser.add_argument("--control-period-sec", type=float, default=0.10)
    parser.add_argument("--status-period-sec", type=float, default=0.20)
    parser.add_argument("--control-trace-path", default="")
    parser.add_argument("--event-trace-path", default="")
    return parser


async def async_main(args: argparse.Namespace) -> None:
    topology = Path(args.topology).expanduser().resolve()
    target = resolve_target(topology, args.uav, args.idx, args.mavsdk_url)
    core = ControlCore(args, target)
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        with contextlib.suppress(NotImplementedError):
            loop.add_signal_handler(sig, lambda: asyncio.create_task(core.shutdown()))
    try:
        await core.run()
    finally:
        await core.shutdown()


def main() -> None:
    args = build_arg_parser().parse_args()
    asyncio.run(async_main(args))


if __name__ == "__main__":
    main()
