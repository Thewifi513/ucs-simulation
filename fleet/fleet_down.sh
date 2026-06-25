#!/usr/bin/env bash
set -Eeuo pipefail

# UCS mesh shutdown / cleanup helper
#
# 职责：
#   - 停掉 pairwise impairment worker 并清理 tc qdisc
#   - 停掉 metrics worker
#   - 停掉 ns-3 live helper
#   - 停掉 world / PX4 helper 终端（基于 PID_DIR 账本）
#   - 清理宿主 bridge / veth
#   - 清理容器内残留 eth1
#   - 停掉 UAV 容器
#
# 说明：
#   - 保留当前启动结构，仅补对称回收
#   - 若某些 pidfile 不存在，按 best-effort 处理，不报错退出
#
# 用法：
#   ./fleet/fleet_down.sh
#   ./fleet/fleet_down.sh --topology ./topology/wifi_adhoc_matrix_2x3_6uav.json
#   ./fleet/fleet_down.sh --verbose

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/env_defaults.sh"
MESH_DIR="$UCS_MESH_DIR"
DEFAULT_TOPOLOGY="${MESH_DIR}/topology/wifi_adhoc_matrix_2x3_6uav.json"

TOPOLOGY_FILE="${TOPOLOGY_FILE:-$DEFAULT_TOPOLOGY}"
VERBOSE=0

METRICS_UP_SH="${MESH_DIR}/network/metrics_up.sh"
PAIRWISE_IMPAIR_UP_SH="${MESH_DIR}/network/pairwise_impair_up.sh"
CONTROL_DOWN_SH="${MESH_DIR}/control/control_down.sh"
RTP_CAMERA_FLOW_SH="${MESH_DIR}/video/run_rtp_camera_flow.sh"
RTP_BRIDGE_PY="${MESH_DIR}/video/rtp_camera_bridge.py"

usage() {
  cat <<EOF2
Usage: $(basename "$0") [--topology FILE] [--verbose] [--help]

--topology FILE   Topology JSON file. Default: ${DEFAULT_TOPOLOGY}
--verbose         Print more details.
--help            Show this help.
EOF2
}

log() {
  echo "[mesh_down] $*"
}

vlog() {
  if [[ "$VERBOSE" -eq 1 ]]; then
    echo "[mesh_down] $*"
  fi
}

s() {
  sudo -n "$@"
}

pid_is_alive() {
  local pid="$1"
  kill -0 "$pid" 2>/dev/null || s kill -0 "$pid" 2>/dev/null
}

send_signal() {
  local signal="$1"
  local pid="$2"
  kill -s "$signal" "$pid" 2>/dev/null || s kill -s "$signal" "$pid" 2>/dev/null || true
}

request_sudo_once() {
  log "validating sudo once in fleet_down.sh ..."
  if sudo -n true 2>/dev/null; then
    return 0
  fi
  sudo -v
}

signal_pid_tree() {
  local signal="$1"
  local pid="$2"
  local child

  if command -v pgrep >/dev/null 2>&1; then
    while read -r child; do
      [[ -n "$child" ]] || continue
      signal_pid_tree "$signal" "$child"
    done < <(pgrep -P "$pid" 2>/dev/null || true)
  fi

  send_signal "$signal" "$pid"
}

signal_session() {
  local signal="$1"
  local sid="$2"
  local member

  if command -v pgrep >/dev/null 2>&1; then
    while read -r member; do
      [[ -n "$member" ]] || continue
      send_signal "$signal" "$member"
    done < <(pgrep -s "$sid" 2>/dev/null || true)
    return 0
  fi

  while read -r member; do
    [[ -n "$member" ]] || continue
    send_signal "$signal" "$member"
  done < <(ps -s "$sid" -o pid= 2>/dev/null || true)
}

signal_pid_or_terminal_session() {
  local signal="$1"
  local pid="$2"
  local sid=""
  local tty=""

  sid="$(ps -o sid= -p "$pid" 2>/dev/null | tr -d '[:space:]' || true)"
  tty="$(ps -o tty= -p "$pid" 2>/dev/null | tr -d '[:space:]' || true)"

  if [[ -n "$sid" && "$sid" == "$pid" && -n "$tty" && "$tty" != "?" ]]; then
    vlog "signaling terminal session sid=${sid} signal=${signal}"
    signal_session "$signal" "$sid"
    return 0
  fi

  signal_pid_tree "$signal" "$pid"
}

kill_pidfile() {
  local label="$1"
  local pidfile="$2"
  local force="${3:-1}"

  [[ -f "$pidfile" ]] || {
    vlog "no pidfile for ${label}: ${pidfile}"
    return 0
  }

  local pid
  pid="$(cat "$pidfile" 2>/dev/null || true)"
  [[ -n "$pid" ]] || {
    rm -f "$pidfile"
    return 0
  }

  if pid_is_alive "$pid"; then
    log "stopping ${label} pid=${pid}"
    signal_pid_or_terminal_session TERM "$pid"
    sleep 0.8
    if [[ "$force" -eq 1 ]] && pid_is_alive "$pid"; then
      signal_pid_or_terminal_session KILL "$pid"
    fi
  fi
  rm -f "$pidfile"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --topology)
      [[ $# -ge 2 ]] || { echo "[mesh_down][ERR] --topology requires a path" >&2; exit 1; }
      TOPOLOGY_FILE="$2"
      shift 2
      ;;
    --verbose)
      VERBOSE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[mesh_down][ERR] unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

[[ -f "$TOPOLOGY_FILE" ]] || { echo "[mesh_down][ERR] topology file not found: $TOPOLOGY_FILE" >&2; exit 1; }
[[ -f "$METRICS_UP_SH" ]] || { echo "[mesh_down][ERR] metrics_up.sh not found: $METRICS_UP_SH" >&2; exit 1; }

TOPOLOGY_FILE="$("$PYTHON_BIN" -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$TOPOLOGY_FILE")"

RUNTIME_SH="$(mktemp /tmp/ucs_mesh_down.XXXXXX.sh)"
cleanup_runtime() {
  rm -f "$RUNTIME_SH"
}
trap cleanup_runtime EXIT

"$PYTHON_BIN" - "$TOPOLOGY_FILE" > "$RUNTIME_SH" <<'PY'
import json
import os
import re
import shlex
import sys

topo_file = sys.argv[1]
with open(topo_file, "r", encoding="utf-8") as f:
    topo = json.load(f)

scenario_id = topo.get("scenario_id")
if not scenario_id:
    raise SystemExit("[mesh_down][ERR] missing scenario_id")

instances = topo.get("instances", [])
globals_ = topo.get("globals", {})
default_exp_if = str(globals_.get("exp_if", "eth1"))
gs_id = globals_.get("gs_id")
if not gs_id:
    raise SystemExit("[mesh_down][ERR] missing globals.gs_id")
business_flows = globals_.get("business_flows", {})
video_flows = []
if isinstance(business_flows, dict):
    for key in ("video", "video_main"):
        flow = business_flows.get(key, {})
        if not flow:
            continue
        if not isinstance(flow, dict):
            raise SystemExit(f"[mesh_down][ERR] globals.business_flows.{key} must be an object if present")
        if flow.get("enabled", False):
            video_flows.append((key, int(flow.get("port_base", 5600 if key == "video" else 5700))))
tap_left = globals_.get("tap_left", "tap-gs")
programmable = topo.get("programmable_net", globals_.get("programmable_net", {}))
if programmable and not isinstance(programmable, dict):
    raise SystemExit("[mesh_down][ERR] programmable_net must be an object if present")
gs_edge = programmable.get("gs_edge", {}) if programmable else {}
if gs_edge and not isinstance(gs_edge, dict):
    raise SystemExit("[mesh_down][ERR] programmable_net.gs_edge must be an object if present")
ports = programmable.get("ports", {}) if programmable else {}
if ports and not isinstance(ports, dict):
    raise SystemExit("[mesh_down][ERR] programmable_net.ports must be an object if present")
local_port = ports.get("local", {}) if ports else {}
air_port = ports.get("air", {}) if ports else {}
cpu_port = ports.get("cpu", {}) if ports else {}
for label, cfg in (("local", local_port), ("air", air_port), ("cpu", cpu_port)):
    if cfg and not isinstance(cfg, dict):
        raise SystemExit(f"[mesh_down][ERR] programmable_net.ports.{label} must be an object if present")

gs_app_if = str(os.environ.get("UCS_MESH_GS_APP_IF", gs_edge.get("app_if", "gs0")))
gs_local_if = str(os.environ.get("UCS_MESH_GS_LOCAL_IF", gs_edge.get("local_if", "p4gs-local")))
gs_bmv2_container = str(os.environ.get("UCS_MESH_GS_BMV2_CONTAINER", gs_edge.get("container_name", f"ucs-bmv2-gs-{scenario_id}")))
bmv2_local_if = str(os.environ.get("UCS_MESH_BMV2_LOCAL_IF", local_port.get("iface", "p4local")))
bmv2_air_if = str(os.environ.get("UCS_MESH_BMV2_AIR_IF", air_port.get("iface", "air0")))
bmv2_cpu_port = int(os.environ.get("UCS_MESH_BMV2_CPU_PORT", cpu_port.get("port_id", 255)))

def derive_uav_num(inst: dict) -> str:
    if "uav_num" in inst:
        return str(inst["uav_num"]).zfill(2)
    if "idx" in inst:
        try:
            return f"{int(inst['idx']):02d}"
        except Exception:
            pass
    inst_id = str(inst.get("id", ""))
    m = re.search(r"(\d+)$", inst_id)
    if m:
        return f"{int(m.group(1)):02d}"
    raise SystemExit(f"[mesh_down][ERR] cannot derive UAV number from instance: {inst}")

resolved = []
gs_exp_ip = ""
for inst in instances:
    if inst.get("id") == gs_id or inst.get("type") == "ground_station":
        gs_exp_ip = str(inst.get("exp_ip", "")).split("/", 1)[0]
        break

for inst in instances:
    if inst.get("type") != "uav":
        continue

    uav_num = derive_uav_num(inst)
    idx = int(inst.get("idx", int(uav_num)))
    default_name = str(inst.get("id", f"uav{uav_num}"))
    default_container = default_name

    resolved.append({
        "uav_id": default_name,
        "uav_num": uav_num,
        "idx": idx,
        "video_ports": " ".join(str(port_base + idx) for _key, port_base in video_flows),
        "container_name": inst.get("container_name", default_container),
        "bridge": inst.get("bridge_name", f"br-{default_name}"),
        "veth_host": inst.get("veth_host", f"veth-{default_name}-host"),
        "exp_if": inst.get("exp_if", default_exp_if),
    })

def emit(name, value):
    print(f"{name}={shlex.quote(str(value))}")

emit("SCENARIO_ID", scenario_id)
emit("TAP_LEFT", tap_left)
emit("GS_APP_IF", gs_app_if)
emit("GS_LOCAL_IF", gs_local_if)
emit("GS_BMV2_CONTAINER", gs_bmv2_container)
emit("GS_EXP_IP", gs_exp_ip)
emit("BMV2_LOCAL_IF", bmv2_local_if)
emit("BMV2_AIR_IF", bmv2_air_if)
emit("BMV2_CPU_PORT", bmv2_cpu_port)
emit("UAV_COUNT", len(resolved))

for i, item in enumerate(resolved):
    emit(f"UAV_ID_{i}", item["uav_id"])
    emit(f"UAV_NUM_{i}", item["uav_num"])
    emit(f"VIDEO_PORTS_{i}", item["video_ports"])
    emit(f"UAV_CONTAINER_{i}", item["container_name"])
    emit(f"BRIDGE_{i}", item["bridge"])
    emit(f"VETH_HOST_{i}", item["veth_host"])
    emit(f"EXP_IF_{i}", item["exp_if"])
PY

# shellcheck disable=SC1090
source "$RUNTIME_SH"

PID_DIR="/tmp/ucs-mesh-${UID}/${SCENARIO_ID}"
NS3_PIDFILE="/tmp/ucs_mesh_ns3_${SCENARIO_ID}.pid"
NS3_LOGFILE="/tmp/ucs_mesh_ns3_${SCENARIO_ID}.launcher.log"
NET_READY_FILE="${PID_DIR}/net.ready"
METRICS_RUNTIME_JSON="/tmp/ucs_mesh_metrics_${SCENARIO_ID}.runtime.json"
METRICS_LOGFILE="/tmp/ucs_mesh_metrics_${SCENARIO_ID}.launcher.log"
METRICS_PIDFILE="/tmp/ucs_mesh_metrics_${SCENARIO_ID}.pid"
BMV2_PID_PREFIX="/tmp/ucs_mesh_bmv2_${SCENARIO_ID}"
RTP_LOGFILE="/tmp/ucs_mesh_rtp_camera_${SCENARIO_ID}.launcher.log"
RTP_PIDFILE="${PID_DIR}/rtp-camera.pid"
RTP_RUN_DIR="${PID_DIR}/rtp-camera"
DASHBOARD_LOGFILE="/tmp/ucs_mesh_dashboard_${SCENARIO_ID}.launcher.log"
DASHBOARD_PIDFILE="${PID_DIR}/dashboard.pid"
DASHBOARD_PORT="${DASHBOARD_PORT:-8088}"
CONTROL_LOG_GLOB="/tmp/ucs_mesh_control_${SCENARIO_ID}_"'*.launcher.log'

log "topology = $TOPOLOGY_FILE"
log "scenario = $SCENARIO_ID"
log "pid dir   = $PID_DIR"

request_sudo_once

remove_tap_forward_rule() {
  if ! command -v iptables >/dev/null 2>&1; then
    return 0
  fi

  local comment="ucs-mesh-${SCENARIO_ID}"
  while s iptables -D FORWARD -i "$TAP_LEFT" -o "$TAP_LEFT" -m comment --comment "$comment" -j ACCEPT 2>/dev/null; do
    log "removed iptables FORWARD rule for ${TAP_LEFT}->${TAP_LEFT}"
  done
}

stop_bmv2_switches() {
  local uav_id container pid_file
  docker rm -f "$GS_BMV2_CONTAINER" >/dev/null 2>&1 || true

  for ((i=0; i<UAV_COUNT; ++i)); do
    eval "uav_id=\${UAV_ID_${i}}"
    eval "container=\${UAV_CONTAINER_${i}}"
    pid_file="${BMV2_PID_PREFIX}_${uav_id}.pid"

    docker exec "$container" bash -lc "
set +e
if [[ -f '$pid_file' ]]; then
  pid=\"\$(cat '$pid_file' 2>/dev/null || true)\"
  if [[ -n \"\$pid\" ]] && kill -0 \"\$pid\" 2>/dev/null; then
    kill \"\$pid\" 2>/dev/null || true
    sleep 0.3
    kill -0 \"\$pid\" 2>/dev/null && kill -9 \"\$pid\" 2>/dev/null || true
  fi
  rm -f '$pid_file'
fi
" >/dev/null 2>&1 || true
  done
}

stop_rtp_residual_processes() {
  command -v pgrep >/dev/null 2>&1 || return 0

  local pid cmd matched video_port video_ports
  local -a pids=()
  while read -r pid cmd; do
    [[ -n "${pid:-}" && -n "${cmd:-}" ]] || continue
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    [[ "$pid" == "$$" ]] && continue

    matched=0
    if [[ "$cmd" == *"$RTP_CAMERA_FLOW_SH"* && "$cmd" == *"$TOPOLOGY_FILE"* ]]; then
      matched=1
    elif [[ "$cmd" == *"rtp_camera_bridge.py"* ]]; then
      for ((i=0; i<UAV_COUNT; ++i)); do
        eval "video_ports=\${VIDEO_PORTS_${i}:-}"
        for video_port in $video_ports; do
          if [[ -n "$video_port" ]] &&
            { [[ "$cmd" == *"--dst-port ${video_port}"* ]] ||
              [[ "$cmd" == *"--dst-port=${video_port}"* ]]; }; then
            matched=1
            break
          fi
        done
        [[ "$matched" -eq 1 ]] && break
      done
    fi

    if [[ "$matched" -eq 1 ]] && pid_is_alive "$pid"; then
      log "stopping residual RTP bridge pid=${pid}"
      signal_pid_or_terminal_session TERM "$pid"
      pids+=("$pid")
    fi
  done < <(pgrep -af 'rtp_camera_bridge\.py|run_rtp_camera_flow\.sh' 2>/dev/null || true)

  if [[ "${#pids[@]}" -gt 0 ]]; then
    sleep 0.5
    for pid in "${pids[@]}"; do
      if pid_is_alive "$pid"; then
        signal_pid_or_terminal_session KILL "$pid"
      fi
    done
  fi
}

tcp_port_pid() {
  local port="$1"
  command -v ss >/dev/null 2>&1 || return 1
  ss -ltnp "sport = :${port}" 2>/dev/null |
    sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p' |
    head -n 1
}

stop_residual_dashboard_process() {
  local pid cmd

  pid="$(tcp_port_pid "$DASHBOARD_PORT" || true)"
  [[ -n "$pid" && "$pid" =~ ^[0-9]+$ ]] || return 0

  cmd="$(tr '\0' ' ' <"/proc/${pid}/cmdline" 2>/dev/null || true)"
  [[ "$cmd" == *"frontend/dashboard_server.py"* ]] || return 0

  if pid_is_alive "$pid"; then
    log "stopping residual dashboard on port ${DASHBOARD_PORT} pid=${pid}"
    signal_pid_or_terminal_session TERM "$pid"
    sleep 0.5
    if pid_is_alive "$pid"; then
      signal_pid_or_terminal_session KILL "$pid"
    fi
  fi
}

stop_residual_gazebo() {
  command -v pgrep >/dev/null 2>&1 || return 0

  local pid cmd
  local -a pids=()
  while read -r pid cmd; do
    [[ -n "${pid:-}" && -n "${cmd:-}" ]] || continue
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    [[ "$pid" == "$$" ]] && continue
    if pid_is_alive "$pid"; then
      log "stopping residual Gazebo pid=${pid} cmd=${cmd}"
      signal_pid_or_terminal_session TERM "$pid"
      pids+=("$pid")
    fi
  done < <(pgrep -af 'gz sim|ign gazebo' 2>/dev/null || true)

  if [[ "${#pids[@]}" -gt 0 ]]; then
    sleep 0.5
    for pid in "${pids[@]}"; do
      if pid_is_alive "$pid"; then
        signal_pid_or_terminal_session KILL "$pid"
      fi
    done
  fi
}

stop_px4_inside_containers() {
  local uav_id container

  for ((i=0; i<UAV_COUNT; ++i)); do
    eval "uav_id=\${UAV_ID_${i}}"
    eval "container=\${UAV_CONTAINER_${i}}"
    log "stopping PX4 inside ${container} (${uav_id}) ..."
    docker exec "$container" bash -lc '
set +e
if [[ -x /px4/bin/px4-logger ]]; then
  for pid_file in /tmp/ucs-mesh-px4-*.pid; do
    [[ -e "$pid_file" ]] || continue
    instance="${pid_file##*/ucs-mesh-px4-}"
    instance="${instance%.pid}"
    timeout 2s /px4/bin/px4-logger --instance "$instance" stop >/dev/null 2>&1 || true
  done
fi
for pid_file in /tmp/ucs-mesh-px4-*.pid; do
  [[ -e "$pid_file" ]] || continue
  pid="$(cat "$pid_file" 2>/dev/null || true)"
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    sleep 0.3
    kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
  fi
  rm -f "$pid_file"
done
pkill -TERM -f "./bin/px4 .*etc/init.d-posix/rcS" 2>/dev/null || true
sleep 0.2
pkill -KILL -f "./bin/px4 .*etc/init.d-posix/rcS" 2>/dev/null || true
rm -f /tmp/ucs-mesh-px4-*.pid /tmp/ucs-mesh-px4-*.log 2>/dev/null || true
rm -rf /px4/log/* 2>/dev/null || true
mkdir -p /px4/log 2>/dev/null || true
' >/dev/null 2>&1 || true
  done
}

log "stopping dashboard/video proxy ..."
kill_pidfile "dashboard" "$DASHBOARD_PIDFILE" || true
stop_residual_dashboard_process

if [[ -f "$CONTROL_DOWN_SH" ]]; then
  log "stopping browser control backend ..."
  "$CONTROL_DOWN_SH" --scenario "$SCENARIO_ID" --all || true
fi

log "stopping RTP camera streams ..."
if [[ -d "$RTP_RUN_DIR" ]]; then
  for child_pidfile in "$RTP_RUN_DIR"/*.pid; do
    [[ -e "$child_pidfile" ]] || continue
    kill_pidfile "RTP camera child $(basename "$child_pidfile" .pid)" "$child_pidfile" || true
  done
fi
kill_pidfile "RTP camera flow" "$RTP_PIDFILE" || true
stop_rtp_residual_processes

log "stopping metrics worker ..."
"$METRICS_UP_SH" --topology "$TOPOLOGY_FILE" --stop || true

stop_bmv2_switches

kill_pidfile "ns-3 live helper" "${PID_DIR}/ns3.pid" || true
kill_pidfile "ns-3 log terminal" "${PID_DIR}/ns3-log-launcher.pid" || true
if [[ -f "$NS3_PIDFILE" ]]; then
  rm -f "$NS3_PIDFILE"
fi

for ((i=0; i<UAV_COUNT; ++i)); do
  eval "UAV_NUM=\${UAV_NUM_${i}}"
  kill_pidfile "px4 helper uav${UAV_NUM}" "${PID_DIR}/px4-uav${UAV_NUM}-launcher.pid" || true
  eval "UAV_ID=\${UAV_ID_${i}}"
  kill_pidfile "px4 inner helper ${UAV_ID}" "${PID_DIR}/px4-${UAV_ID}.pid" || true
done
stop_px4_inside_containers

kill_pidfile "world launcher" "${PID_DIR}/world-launcher.pid" || true
kill_pidfile "world verify helper" "${PID_DIR}/world-B.pid" || true
kill_pidfile "world helper" "${PID_DIR}/world-A.pid" || true
stop_residual_gazebo

if [[ -f "$PAIRWISE_IMPAIR_UP_SH" ]]; then
  log "stopping pairwise impairment worker and cleaning tc qdiscs ..."
  "$PAIRWISE_IMPAIR_UP_SH" --topology "$TOPOLOGY_FILE" --stop || true
fi

remove_tap_forward_rule

s ip link del "$GS_APP_IF" 2>/dev/null || true
s ip link del "$GS_LOCAL_IF" 2>/dev/null || true

for ((i=0; i<UAV_COUNT; ++i)); do
  eval "UAV_ID=\${UAV_ID_${i}}"
  eval "UAV_CONTAINER=\${UAV_CONTAINER_${i}}"
  eval "BRIDGE=\${BRIDGE_${i}}"
  eval "VETH_HOST=\${VETH_HOST_${i}}"
  eval "EXP_IF=\${EXP_IF_${i}}"

  log "cleaning ${UAV_ID}: bridge=${BRIDGE} veth_host=${VETH_HOST} exp_if=${EXP_IF}"

  s ip link del "$BRIDGE" 2>/dev/null || true
  s ip link del "$VETH_HOST" 2>/dev/null || true

  PID="$(docker inspect -f '{{.State.Pid}}' "$UAV_CONTAINER" 2>/dev/null || true)"
  if [[ -n "${PID}" && "${PID}" != "0" ]]; then
    s nsenter -t "$PID" -n bash -lc "
set +e
for dev in '$EXP_IF' '$BMV2_LOCAL_IF' '$BMV2_AIR_IF'; do
  ip link show \"\$dev\" >/dev/null 2>&1 && ip link del \"\$dev\" || true
done
" || true
  fi
done

log "stopping UAV containers ..."
for ((i=0; i<UAV_COUNT; ++i)); do
  eval "UAV_CONTAINER=\${UAV_CONTAINER_${i}}"
  docker stop -t 5 "$UAV_CONTAINER" >/dev/null 2>&1 || true
done

rm -f "$NS3_LOGFILE" "$METRICS_RUNTIME_JSON" "$METRICS_LOGFILE" "$METRICS_PIDFILE" "$RTP_LOGFILE" "$DASHBOARD_LOGFILE" $CONTROL_LOG_GLOB 2>/dev/null || true
if [[ -d "$PID_DIR" ]]; then
  if [[ -d "$RTP_RUN_DIR" ]]; then
    rm -f "$RTP_RUN_DIR"/*.log "$RTP_RUN_DIR"/*.pid 2>/dev/null || true
    rmdir "$RTP_RUN_DIR" 2>/dev/null || true
  fi
  rm -f "$PID_DIR"/*.pid "$PID_DIR"/meta.env "$PID_DIR"/topology.path "$NET_READY_FILE" 2>/dev/null || true
  rmdir "$PID_DIR" 2>/dev/null || true
fi

log "done."
