#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MESH_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${MESH_DIR}/fleet/env_defaults.sh"
DEFAULT_TOPOLOGY="${MESH_DIR}/topology/wifi_adhoc_matrix_2x3_6uav.json"

TOPOLOGY_FILE="${TOPOLOGY_FILE:-$DEFAULT_TOPOLOGY}"
TARGET_UAV="${TARGET_UAV:-uav04}"
TARGET_IDX=""
HOST="${HOST:-127.0.0.1}"
CORE_PORT="${CORE_PORT:-9001}"
RELAY_HOST="${RELAY_HOST:-0.0.0.0}"
RELAY_PORT="${RELAY_PORT:-8765}"
MAVSDK_SERVER_PORT="${MAVSDK_SERVER_PORT:-50051}"
MAVSDK_URL="${MAVSDK_URL:-}"
MAX_HORIZONTAL_SPEED_MPS="${MAX_HORIZONTAL_SPEED_MPS:-6.0}"
MAX_VERTICAL_SPEED_MPS="${MAX_VERTICAL_SPEED_MPS:-3.0}"
MAX_YAW_RATE_DEG_S="${MAX_YAW_RATE_DEG_S:-45.0}"
BG=0
STARTUP_DONE=0

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --topology FILE          Topology JSON. Default: ${DEFAULT_TOPOLOGY}
  --uav uavNN             Target UAV. Default: ${TARGET_UAV}
  --idx N                 Target UAV by topology idx.
  --host HOST             control_core listen host. Default: ${HOST}
  --core-port PORT        control_core JSON-line port. Default: ${CORE_PORT}
  --relay-host HOST       browser WebSocket host. Default: ${RELAY_HOST}
  --relay-port PORT       browser WebSocket port. Default: ${RELAY_PORT}
  --mavsdk-server-port P  MAVSDK gRPC port. Default: ${MAVSDK_SERVER_PORT}
  --mavsdk-url URL        Override MAVSDK connection URL.
  --max-horizontal-speed M Normalized speed 1.0 horizontal cap in m/s. Default: ${MAX_HORIZONTAL_SPEED_MPS}
  --max-vertical-speed M   Normalized speed 1.0 vertical cap in m/s. Default: ${MAX_VERTICAL_SPEED_MPS}
  --max-yaw-rate D         Normalized speed 1.0 yaw-rate cap in deg/s. Default: ${MAX_YAW_RATE_DEG_S}
  --bg                    Start processes in background and exit.
  --help                  Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --topology)
      [[ $# -ge 2 ]] || { echo "[control_up][ERR] --topology requires a path" >&2; exit 1; }
      TOPOLOGY_FILE="$2"
      shift 2
      ;;
    --uav)
      [[ $# -ge 2 ]] || { echo "[control_up][ERR] --uav requires a value" >&2; exit 1; }
      TARGET_UAV="$2"
      shift 2
      ;;
    --idx)
      [[ $# -ge 2 ]] || { echo "[control_up][ERR] --idx requires a value" >&2; exit 1; }
      TARGET_IDX="$2"
      TARGET_UAV=""
      shift 2
      ;;
    --host)
      [[ $# -ge 2 ]] || { echo "[control_up][ERR] --host requires a value" >&2; exit 1; }
      HOST="$2"
      shift 2
      ;;
    --core-port)
      [[ $# -ge 2 ]] || { echo "[control_up][ERR] --core-port requires a value" >&2; exit 1; }
      CORE_PORT="$2"
      shift 2
      ;;
    --relay-host)
      [[ $# -ge 2 ]] || { echo "[control_up][ERR] --relay-host requires a value" >&2; exit 1; }
      RELAY_HOST="$2"
      shift 2
      ;;
    --relay-port)
      [[ $# -ge 2 ]] || { echo "[control_up][ERR] --relay-port requires a value" >&2; exit 1; }
      RELAY_PORT="$2"
      shift 2
      ;;
    --mavsdk-server-port)
      [[ $# -ge 2 ]] || { echo "[control_up][ERR] --mavsdk-server-port requires a value" >&2; exit 1; }
      MAVSDK_SERVER_PORT="$2"
      shift 2
      ;;
    --mavsdk-url)
      [[ $# -ge 2 ]] || { echo "[control_up][ERR] --mavsdk-url requires a URL" >&2; exit 1; }
      MAVSDK_URL="$2"
      shift 2
      ;;
    --max-horizontal-speed)
      [[ $# -ge 2 ]] || { echo "[control_up][ERR] --max-horizontal-speed requires a value" >&2; exit 1; }
      MAX_HORIZONTAL_SPEED_MPS="$2"
      shift 2
      ;;
    --max-vertical-speed)
      [[ $# -ge 2 ]] || { echo "[control_up][ERR] --max-vertical-speed requires a value" >&2; exit 1; }
      MAX_VERTICAL_SPEED_MPS="$2"
      shift 2
      ;;
    --max-yaw-rate)
      [[ $# -ge 2 ]] || { echo "[control_up][ERR] --max-yaw-rate requires a value" >&2; exit 1; }
      MAX_YAW_RATE_DEG_S="$2"
      shift 2
      ;;
    --bg)
      BG=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[control_up][ERR] unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

[[ -f "$TOPOLOGY_FILE" ]] || { echo "[control_up][ERR] topology not found: $TOPOLOGY_FILE" >&2; exit 1; }

resolve_python() {
  [[ -n "${PYTHON_BIN:-}" && -x "${PYTHON_BIN}" ]] || return 1
  printf '%s\n' "${PYTHON_BIN}"
}

resolve_mavsdk_server() {
  if [[ -n "${MAVSDK_SERVER_BIN:-}" && -x "${MAVSDK_SERVER_BIN}" ]]; then
    printf '%s\n' "${MAVSDK_SERVER_BIN}"
    return
  fi
  for candidate in \
    "${MESH_DIR}/control/mavsdk_server" \
    "${MESH_DIR}/control/mavsdk_server_musl_x86_64" \
    "mavsdk_server"; do
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return
    fi
    if command -v "$candidate" >/dev/null 2>&1; then
      command -v "$candidate"
      return
    fi
  done
}

PYTHON_BIN_RESOLVED="$(resolve_python || true)"
MAVSDK_SERVER_BIN_RESOLVED="$(resolve_mavsdk_server || true)"
[[ -n "$PYTHON_BIN_RESOLVED" ]] || { echo "[control_up][ERR] no Python found" >&2; exit 1; }
[[ -n "$MAVSDK_SERVER_BIN_RESOLVED" ]] || { echo "[control_up][ERR] mavsdk_server binary not found; put it under control/ or set MAVSDK_SERVER_BIN" >&2; exit 1; }

"$PYTHON_BIN_RESOLVED" - <<'PY'
import mavsdk
import websockets
PY

TOPOLOGY_FILE="$("$PYTHON_BIN_RESOLVED" -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$TOPOLOGY_FILE")"

TARGET_JSON="$("$PYTHON_BIN_RESOLVED" - "$TOPOLOGY_FILE" "$TARGET_UAV" "$TARGET_IDX" "$MAVSDK_URL" <<'PY'
import ipaddress
import json
import sys

topology_file, target_uav, target_idx, mavsdk_url = sys.argv[1:]
topo = json.load(open(topology_file, encoding="utf-8"))
selected = None
for inst in topo.get("instances", []):
    if inst.get("type") != "uav":
        continue
    inst_id = str(inst.get("id") or inst.get("name"))
    aliases = {inst_id, str(inst.get("name", "")), str(inst.get("container_name", ""))}
    if target_uav and target_uav in aliases:
        selected = inst
        break
    if target_idx and int(inst.get("idx", 0)) == int(target_idx):
        selected = inst
        break
if selected is None:
    raise SystemExit("[control_up][ERR] target UAV not found")

def ip_only(value):
    if "/" in value:
        return str(ipaddress.ip_interface(value).ip)
    return str(ipaddress.ip_address(value))

def gs_ip(topo):
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

def mavsdk_endpoint(topo, inst, idx, override_url):
    globals_ = topo.get("globals", {})
    business_flows = globals_.get("business_flows", {}) if isinstance(globals_, dict) else {}
    control_flow = business_flows.get("control", {}) if isinstance(business_flows, dict) else {}
    mavsdk_flow = control_flow.get("mavsdk", {}) if isinstance(control_flow, dict) else {}
    if not isinstance(mavsdk_flow, dict):
        mavsdk_flow = {}
    local_port = int(inst.get("mavsdk_local_port", int(mavsdk_flow.get("uav_local_port_base", 18600)) + idx))
    remote_port = int(inst.get("mavsdk_remote_port", int(mavsdk_flow.get("gs_remote_port_base", 14600)) + idx))
    remote_ip_raw = str(inst.get("mavsdk_remote_ip") or mavsdk_flow.get("remote_ip") or gs_ip(topo))
    if remote_ip_raw == "ground_station.exp_ip":
        remote_ip_raw = gs_ip(topo)
    remote_ip = ip_only(remote_ip_raw)
    url = override_url or str(inst.get("mavsdk_url") or f"udpin://0.0.0.0:{remote_port}")
    return local_port, remote_port, remote_ip, url

uav_id = str(selected.get("id") or selected.get("name"))
idx = int(selected.get("idx", 0))
exp_ip = ip_only(str(selected["exp_ip"]))
qgc_port = int(selected["qgc_port"])
mavsdk_local_port, mavsdk_remote_port, mavsdk_remote_ip, resolved_url = mavsdk_endpoint(topo, selected, idx, mavsdk_url)
payload = {
    "scenario_id": topo.get("scenario_id", "unknown"),
    "uav_id": uav_id,
    "idx": idx,
    "exp_ip": exp_ip,
    "qgc_port": qgc_port,
    "mavsdk_local_port": mavsdk_local_port,
    "mavsdk_remote_port": mavsdk_remote_port,
    "mavsdk_remote_ip": mavsdk_remote_ip,
    "mavsdk_url": resolved_url,
}
print(json.dumps(payload, sort_keys=True))
PY
)"

SCENARIO_ID="$("$PYTHON_BIN_RESOLVED" -c 'import json,sys; print(json.loads(sys.argv[1])["scenario_id"])' "$TARGET_JSON")"
TARGET_UAV_ID="$("$PYTHON_BIN_RESOLVED" -c 'import json,sys; print(json.loads(sys.argv[1])["uav_id"])' "$TARGET_JSON")"
TARGET_IDX_RESOLVED="$("$PYTHON_BIN_RESOLVED" -c 'import json,sys; print(json.loads(sys.argv[1])["idx"])' "$TARGET_JSON")"
TARGET_EXP_IP="$("$PYTHON_BIN_RESOLVED" -c 'import json,sys; print(json.loads(sys.argv[1])["exp_ip"])' "$TARGET_JSON")"
TARGET_QGC_PORT="$("$PYTHON_BIN_RESOLVED" -c 'import json,sys; print(json.loads(sys.argv[1])["qgc_port"])' "$TARGET_JSON")"
MAVSDK_LOCAL_PORT_RESOLVED="$("$PYTHON_BIN_RESOLVED" -c 'import json,sys; print(json.loads(sys.argv[1])["mavsdk_local_port"])' "$TARGET_JSON")"
MAVSDK_REMOTE_PORT_RESOLVED="$("$PYTHON_BIN_RESOLVED" -c 'import json,sys; print(json.loads(sys.argv[1])["mavsdk_remote_port"])' "$TARGET_JSON")"
MAVSDK_REMOTE_IP_RESOLVED="$("$PYTHON_BIN_RESOLVED" -c 'import json,sys; print(json.loads(sys.argv[1])["mavsdk_remote_ip"])' "$TARGET_JSON")"
MAVSDK_URL_RESOLVED="$("$PYTHON_BIN_RESOLVED" -c 'import json,sys; print(json.loads(sys.argv[1])["mavsdk_url"])' "$TARGET_JSON")"

RUN_ROOT="/tmp/ucs-mesh-${UID}/control/${SCENARIO_ID}/${TARGET_UAV_ID}"
RUN_DIR="${RUN_ROOT}/$(date +%Y%m%d_%H%M%S)"
mkdir -p "$RUN_DIR"
RUNTIME_FILE="/tmp/ucs_mesh_control_${SCENARIO_ID}_${TARGET_UAV_ID}.runtime.json"

MAVSDK_PIDFILE="${RUN_DIR}/mavsdk_server.pid"
CORE_PIDFILE="${RUN_DIR}/control_core.pid"
RELAY_PIDFILE="${RUN_DIR}/remote_web.pid"
MAVSDK_LOG="${RUN_DIR}/mavsdk_server.log"
CORE_LOG="${RUN_DIR}/control_core.log"
RELAY_LOG="${RUN_DIR}/remote_web.log"
CONTROL_TRACE="${RUN_DIR}/control_trace.csv"
EVENT_TRACE="${RUN_DIR}/event_trace.csv"

wait_tcp() {
  local host="$1"
  local port="$2"
  local label="$3"
  "$PYTHON_BIN_RESOLVED" - "$host" "$port" "$label" <<'PY'
import socket
import sys
import time

host, port, label = sys.argv[1], int(sys.argv[2]), sys.argv[3]
deadline = time.time() + 12
while time.time() < deadline:
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.settimeout(0.3)
    try:
        sock.connect((host, port))
        print(f"[control_up] {label} ready: {host}:{port}")
        sys.exit(0)
    except OSError:
        time.sleep(0.2)
    finally:
        sock.close()
print(f"[control_up][ERR] timed out waiting for {label}: {host}:{port}", file=sys.stderr)
sys.exit(1)
PY
}

wait_ws() {
  local host="$1"
  local port="$2"
  local label="$3"
  "$PYTHON_BIN_RESOLVED" - "$host" "$port" "$label" <<'PY'
import asyncio
import sys
import time

import websockets

host, port, label = sys.argv[1], int(sys.argv[2]), sys.argv[3]

async def probe():
    uri = f"ws://{host}:{port}"
    deadline = time.time() + 12
    last_error = None
    while time.time() < deadline:
        try:
            async with websockets.connect(uri, open_timeout=0.5):
                print(f"[control_up] {label} ready: {host}:{port}")
                return 0
        except Exception as exc:
            last_error = exc
            await asyncio.sleep(0.2)
    print(f"[control_up][ERR] timed out waiting for {label}: {host}:{port} ({last_error})", file=sys.stderr)
    return 1

raise SystemExit(asyncio.run(probe()))
PY
}

write_runtime() {
  "$PYTHON_BIN_RESOLVED" - "$RUNTIME_FILE" "$TARGET_JSON" "$RUN_DIR" "$MAVSDK_SERVER_PORT" "$CORE_PORT" "$RELAY_PORT" "$MAVSDK_PIDFILE" "$CORE_PIDFILE" "$RELAY_PIDFILE" "$MAVSDK_LOG" "$CORE_LOG" "$RELAY_LOG" <<'PY'
import json
import os
import sys

runtime_file, target_json, run_dir, mavsdk_port, core_port, relay_port, mavsdk_pid, core_pid, relay_pid, mavsdk_log, core_log, relay_log = sys.argv[1:]
payload = json.loads(target_json)
payload.update({
    "run_dir": run_dir,
    "mavsdk_server_port": int(mavsdk_port),
    "core_port": int(core_port),
    "relay_port": int(relay_port),
    "pidfiles": {
        "mavsdk_server": mavsdk_pid,
        "control_core": core_pid,
        "remote_web": relay_pid,
    },
    "logs": {
        "mavsdk_server": mavsdk_log,
        "control_core": core_log,
        "remote_web": relay_log,
    },
    "updated_at": __import__("time").time(),
})
tmp = runtime_file + ".tmp"
with open(tmp, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
    handle.write("\n")
os.replace(tmp, runtime_file)
PY
}

cleanup() {
  if [[ "$BG" -eq 1 && "$STARTUP_DONE" -eq 1 ]]; then
    return
  fi
  for pidfile in "$RELAY_PIDFILE" "$CORE_PIDFILE" "$MAVSDK_PIDFILE"; do
    if [[ -s "$pidfile" ]]; then
      kill "$(cat "$pidfile")" >/dev/null 2>&1 || true
    fi
  done
}
trap cleanup INT TERM EXIT

start_logged() {
  local pidfile="$1"
  local logfile="$2"
  shift 2

  if [[ "$BG" -eq 1 ]]; then
    if command -v setsid >/dev/null 2>&1; then
      setsid "$@" >"$logfile" 2>&1 < /dev/null &
    else
      nohup "$@" >"$logfile" 2>&1 < /dev/null &
    fi
  else
    "$@" >"$logfile" 2>&1 &
  fi
  printf '%s\n' "$!" > "$pidfile"
}

echo "[control_up] topology=${TOPOLOGY_FILE}"
echo "[control_up] target=${TARGET_UAV_ID} idx=${TARGET_IDX_RESOLVED} mavsdk=${MAVSDK_URL_RESOLVED}"
echo "[control_up] px4 mavlink endpoint=${TARGET_EXP_IP}:${MAVSDK_LOCAL_PORT_RESOLVED} -> ${MAVSDK_REMOTE_IP_RESOLVED}:${MAVSDK_REMOTE_PORT_RESOLVED}"
echo "[control_up] normalized speed caps: xy=${MAX_HORIZONTAL_SPEED_MPS}m/s z=${MAX_VERTICAL_SPEED_MPS}m/s yaw=${MAX_YAW_RATE_DEG_S}deg/s"
echo "[control_up] run_dir=${RUN_DIR}"

start_logged "$MAVSDK_PIDFILE" "$MAVSDK_LOG" "$MAVSDK_SERVER_BIN_RESOLVED" -p "$MAVSDK_SERVER_PORT" "$MAVSDK_URL_RESOLVED"
sleep 0.3
if ! kill -0 "$(cat "$MAVSDK_PIDFILE")" >/dev/null 2>&1; then
  echo "[control_up][ERR] mavsdk_server exited early; log=${MAVSDK_LOG}" >&2
  sed -n '1,80p' "$MAVSDK_LOG" >&2 || true
  exit 1
fi
echo "[control_up] mavsdk_server started; waiting for PX4 discovery on ${MAVSDK_URL_RESOLVED}"
if ! wait_tcp 127.0.0.1 "$MAVSDK_SERVER_PORT" mavsdk_server; then
  echo "[control_up][ERR] mavsdk_server gRPC port is not open: 127.0.0.1:${MAVSDK_SERVER_PORT}" >&2
  sed -n '1,120p' "$MAVSDK_LOG" >&2 || true
  exit 1
fi

core_args=(
  "$PYTHON_BIN_RESOLVED" "$SCRIPT_DIR/control_core.py"
  --topology "$TOPOLOGY_FILE"
  --uav "$TARGET_UAV_ID"
  --mavsdk-url "$MAVSDK_URL_RESOLVED"
  --server-owns-connection
  --listen-host "$HOST"
  --listen-port "$CORE_PORT"
  --mavsdk-server-host 127.0.0.1
  --mavsdk-server-port "$MAVSDK_SERVER_PORT"
  --max-horizontal-speed-mps "$MAX_HORIZONTAL_SPEED_MPS"
  --max-vertical-speed-mps "$MAX_VERTICAL_SPEED_MPS"
  --max-yaw-rate-deg-s "$MAX_YAW_RATE_DEG_S"
  --control-trace-path "$CONTROL_TRACE"
  --event-trace-path "$EVENT_TRACE"
)
start_logged "$CORE_PIDFILE" "$CORE_LOG" "${core_args[@]}"
wait_tcp "$HOST" "$CORE_PORT" control_core

relay_args=(
  "$PYTHON_BIN_RESOLVED" "$SCRIPT_DIR/remote_web.py"
  --listen-host "$RELAY_HOST"
  --listen-port "$RELAY_PORT"
  --core-host "$HOST"
  --core-port "$CORE_PORT"
)
start_logged "$RELAY_PIDFILE" "$RELAY_LOG" "${relay_args[@]}"
wait_ws 127.0.0.1 "$RELAY_PORT" remote_web

write_runtime
STARTUP_DONE=1

echo "[control_up] runtime=${RUNTIME_FILE}"
echo "[control_up] logs:"
echo "  mavsdk_server=${MAVSDK_LOG}"
echo "  control_core=${CORE_LOG}"
echo "  remote_web=${RELAY_LOG}"
echo "[control_up] dashboard control websocket: ws://127.0.0.1:${RELAY_PORT}"

if [[ "$BG" -eq 1 ]]; then
  exit 0
fi

echo "[control_up] running in foreground; Ctrl+C stops control processes."
while true; do
  for pidfile in "$MAVSDK_PIDFILE" "$CORE_PIDFILE" "$RELAY_PIDFILE"; do
    if [[ ! -s "$pidfile" ]] || ! kill -0 "$(cat "$pidfile")" >/dev/null 2>&1; then
      echo "[control_up][ERR] process exited; check logs under ${RUN_DIR}" >&2
      exit 1
    fi
  done
  sleep 2
done
