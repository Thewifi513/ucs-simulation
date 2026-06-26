#!/usr/bin/env bash
set -Eeuo pipefail

# UCS mesh one-shot launcher
#
# 职责：
#   - 读取 topology JSON
#   - 确保所需 UAV 容器存在
#   - 启动 world / PX4 helper
#   - 启动 ns-3 live + host/container net plumbing
#   - 启动 metrics worker
#
# 修正版说明：
#   - 保留现有外层终端包装，避免改动已跑通启动链
#   - 为外层 world / PX4 / ns-3 launcher 终端记录 PID，便于 fleet_down 回收
#   - 建立 scenario 级 PID_DIR 账本目录
#   - metrics_up.sh 放后台，日志落盘
#
# 用法：
#   ./fleet/fleet_up.sh
#   ./fleet/fleet_up.sh --topology ./topology/wifi_adhoc_matrix_2x3_6uav.json
#   ./fleet/fleet_up.sh --verbose

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/env_defaults.sh"
MESH_DIR="$UCS_MESH_DIR"
DEFAULT_TOPOLOGY="${MESH_DIR}/topology/wifi_adhoc_matrix_2x3_6uav.json"

TOPOLOGY_FILE="${TOPOLOGY_FILE:-$DEFAULT_TOPOLOGY}"
VERBOSE=0
WAIT_READY_TIMEOUT_SEC="${WAIT_READY_TIMEOUT_SEC:-90}"
TERMINAL_MODE="${UCS_MESH_TERMINAL_MODE:-minimal}"
WORLD_GUI="${UCS_GZ_GUI:-0}"
VIDEO_MODE="${UCS_MESH_VIDEO_MODE:-auto}"
VIDEO_MAIN_MODE="${UCS_MESH_VIDEO_MAIN_MODE:-off}"
VIDEO_BITRATE_KBPS="${VIDEO_BITRATE_KBPS:-}"
VIDEO_FPS="${VIDEO_FPS:-}"
VIDEO_BITRATE_KBPS_EXPLICIT=0
VIDEO_FPS_EXPLICIT=0
VIDEO_ENCODER_EXPLICIT=0
[[ -n "$VIDEO_BITRATE_KBPS" ]] && VIDEO_BITRATE_KBPS_EXPLICIT=1
[[ -n "$VIDEO_FPS" ]] && VIDEO_FPS_EXPLICIT=1
[[ -n "${VIDEO_ENCODER:-}" ]] && VIDEO_ENCODER_EXPLICIT=1
VIDEO_ENCODER="${VIDEO_ENCODER:-auto}"
DASHBOARD_VIDEO_DECODER_EXPLICIT=0
[[ -n "${DASHBOARD_VIDEO_DECODER:-}" ]] && DASHBOARD_VIDEO_DECODER_EXPLICIT=1
DASHBOARD_MODE="${UCS_MESH_DASHBOARD_MODE:-auto}"
DASHBOARD_HOST="${DASHBOARD_HOST:-0.0.0.0}"
DASHBOARD_PORT="${DASHBOARD_PORT:-8088}"
CONTROL_MODE="${UCS_MESH_CONTROL_MODE:-auto}"
CONTROL_UAV="${CONTROL_UAV:-all}"
CONTROL_CORE_PORT="${CONTROL_CORE_PORT:-9001}"
CONTROL_RELAY_PORT="${CONTROL_RELAY_PORT:-8765}"
CONTROL_MAVSDK_SERVER_PORT="${CONTROL_MAVSDK_SERVER_PORT:-50051}"
CONTROL_CORE_PORT_BASE="${CONTROL_CORE_PORT_BASE:-9010}"
CONTROL_RELAY_PORT_BASE="${CONTROL_RELAY_PORT_BASE:-8770}"
CONTROL_MAVSDK_SERVER_PORT_BASE="${CONTROL_MAVSDK_SERVER_PORT_BASE:-50100}"
BMV2_MODE="${UCS_MESH_BMV2_MODE:-auto}"
UCS_GAZEBO_BACKEND="${UCS_GAZEBO_BACKEND:-host}"
UCS_GAZEBO_CAMERA_PROFILE_EXPLICIT=0
[[ -n "${UCS_GAZEBO_CAMERA_PROFILE+x}" ]] && UCS_GAZEBO_CAMERA_PROFILE_EXPLICIT=1
UCS_GAZEBO_CAMERA_PROFILE="${UCS_GAZEBO_CAMERA_PROFILE:-}"
UCS_GAZEBO_CAMERA_PROFILE_AUTO=0
UCS_GAZEBO_CAMERA_SETTINGS_EXPLICIT=0
if [[ -n "${UCS_GAZEBO_CAMERA_WIDTH:-}${UCS_GAZEBO_CAMERA_HEIGHT:-}${UCS_GAZEBO_CAMERA_UPDATE_RATE:-}${UCS_GAZEBO_CAMERA_VISUALIZE:-}" ]]; then
  UCS_GAZEBO_CAMERA_SETTINGS_EXPLICIT=1
fi

WORLD_UP_SH="${MESH_DIR}/px4_gazebo/world_up.sh"
PX4_UP_SH="${MESH_DIR}/px4_gazebo/px4_up.sh"
NET_UP_SH="${MESH_DIR}/network/net_up.sh"
METRICS_UP_SH="${MESH_DIR}/network/metrics_up.sh"
ENSURE_CONTAINER_SH="${SCRIPT_DIR}/ensure_container.sh"
RTP_CAMERA_FLOW_SH="${MESH_DIR}/video/run_rtp_camera_flow.sh"
DASHBOARD_UP_SH="${MESH_DIR}/frontend/dashboard_up.sh"
CONTROL_UP_SH="${MESH_DIR}/control/control_up.sh"
CONTROL_DOWN_SH="${MESH_DIR}/control/control_down.sh"

usage() {
  cat <<EOF2
Usage: $(basename "$0") [--topology FILE] [--terminal-mode MODE] [--headless|--gui] [--with-video|--no-video] [--with-video-main|--no-video-main] [--with-control|--no-control] [--with-dashboard|--no-dashboard] [--with-bmv2|--no-bmv2] [--verbose] [--help]

--topology FILE   Topology JSON file. Default: ${DEFAULT_TOPOLOGY}
--terminal-mode MODE
                  Terminal display mode: minimal or full. Default: ${TERMINAL_MODE}
--headless        Start Gazebo server-only through world_up.sh. Default when UCS_GZ_GUI is unset.
--gui             Start Gazebo with GUI through world_up.sh.
--with-video      Start topology-defined RTP camera preview streams.
--no-video        Do not start RTP camera streams.
--with-video-main Start the 1080p main RTP stream in addition to the default
                  preview substream. Default: ${VIDEO_MAIN_MODE}
--no-video-main   Keep only the default preview substream.
--video-bitrate-kbps N
                  H.264 target bitrate for each stream. Default: topology video.default_bitrate_kbps.
--video-fps N     Camera stream frame rate. Default: topology video.default_fps.
--video-encoder NAME
                  H.264 encoder: auto, hard, nvh264enc, nvautogpuh264enc,
                  nvcudah264enc, va, vaapi, v4l2, openh264enc, x264.
                  Default: ${VIDEO_ENCODER}
--with-control    Start the browser control relay/MAVSDK backend.
--no-control      Do not start the browser control backend.
--control-uav ID  UAV controlled by the browser panel, or all. Default: ${CONTROL_UAV}
                  In all mode, ports are relay/core/MAVSDK bases + topology idx:
                  relay=${CONTROL_RELAY_PORT_BASE}+idx, core=${CONTROL_CORE_PORT_BASE}+idx,
                  mavsdk_server=${CONTROL_MAVSDK_SERVER_PORT_BASE}+idx.
--with-dashboard  Start the browser dashboard/video proxy.
--no-dashboard    Do not start the browser dashboard/video proxy.
--dashboard-port N
                  Dashboard HTTP port. Default: ${DASHBOARD_PORT}
--with-bmv2       Use topology-defined BMv2 inline dataplane. Default: ${BMV2_MODE}
--no-bmv2         Bypass BMv2 and keep only Linux endpoints plus ns-3 link fabric.
--verbose         Print more details.
--help            Show this help.
EOF2
}

log() {
  echo "[mesh_up] $*"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --topology)
      [[ $# -ge 2 ]] || { echo "[mesh_up][ERR] --topology requires a path" >&2; exit 1; }
      TOPOLOGY_FILE="$2"
      shift 2
      ;;
    --verbose)
      VERBOSE=1
      shift
      ;;
    --terminal-mode)
      [[ $# -ge 2 ]] || { echo "[mesh_up][ERR] --terminal-mode requires a value" >&2; exit 1; }
      TERMINAL_MODE="$2"
      shift 2
      ;;
    --show-terminals|--full-terminals)
      TERMINAL_MODE="full"
      shift
      ;;
    --minimal-terminals|--no-helper-terminals)
      TERMINAL_MODE="minimal"
      shift
      ;;
    --headless|--no-gui)
      WORLD_GUI=0
      shift
      ;;
    --gui)
      WORLD_GUI=1
      shift
      ;;
    --with-video)
      VIDEO_MODE="on"
      shift
      ;;
    --no-video)
      VIDEO_MODE="off"
      shift
      ;;
    --with-video-main)
      VIDEO_MAIN_MODE="on"
      shift
      ;;
    --no-video-main)
      VIDEO_MAIN_MODE="off"
      shift
      ;;
    --video-bitrate-kbps)
      [[ $# -ge 2 ]] || { echo "[mesh_up][ERR] --video-bitrate-kbps requires a value" >&2; exit 1; }
      VIDEO_BITRATE_KBPS="$2"
      VIDEO_BITRATE_KBPS_EXPLICIT=1
      shift 2
      ;;
    --video-fps)
      [[ $# -ge 2 ]] || { echo "[mesh_up][ERR] --video-fps requires a value" >&2; exit 1; }
      VIDEO_FPS="$2"
      VIDEO_FPS_EXPLICIT=1
      shift 2
      ;;
    --video-encoder|--encoder)
      [[ $# -ge 2 ]] || { echo "[mesh_up][ERR] --video-encoder requires a value" >&2; exit 1; }
      VIDEO_ENCODER="$2"
      VIDEO_ENCODER_EXPLICIT=1
      shift 2
      ;;
    --with-control)
      CONTROL_MODE="on"
      shift
      ;;
    --no-control)
      CONTROL_MODE="off"
      shift
      ;;
    --control-uav)
      [[ $# -ge 2 ]] || { echo "[mesh_up][ERR] --control-uav requires a value" >&2; exit 1; }
      CONTROL_UAV="$2"
      shift 2
      ;;
    --with-dashboard)
      DASHBOARD_MODE="on"
      shift
      ;;
    --no-dashboard)
      DASHBOARD_MODE="off"
      shift
      ;;
    --dashboard-port)
      [[ $# -ge 2 ]] || { echo "[mesh_up][ERR] --dashboard-port requires a value" >&2; exit 1; }
      DASHBOARD_PORT="$2"
      shift 2
      ;;
    --with-bmv2)
      BMV2_MODE="on"
      shift
      ;;
    --no-bmv2|--bypass-bmv2)
      BMV2_MODE="off"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[mesh_up][ERR] unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

case "$TERMINAL_MODE" in
  minimal|full) ;;
  *)
    echo "[mesh_up][ERR] unsupported terminal mode: $TERMINAL_MODE" >&2
    echo "[mesh_up][ERR] expected: minimal or full" >&2
    exit 1
    ;;
esac

case "$WORLD_GUI" in
  0|false|False|FALSE|no|No|NO|off|Off|OFF)
    WORLD_GUI=0
    ;;
  1|true|True|TRUE|yes|Yes|YES|on|On|ON)
    WORLD_GUI=1
    ;;
  *)
    echo "[mesh_up][ERR] unsupported Gazebo GUI mode: ${WORLD_GUI}" >&2
    echo "[mesh_up][ERR] expected 0/1, true/false, yes/no, or on/off" >&2
    exit 1
    ;;
esac

case "$VIDEO_MODE" in
  auto|on|off) ;;
  *)
    echo "[mesh_up][ERR] unsupported video mode: $VIDEO_MODE" >&2
    echo "[mesh_up][ERR] expected: auto, on, or off" >&2
    exit 1
    ;;
esac

case "$VIDEO_MAIN_MODE" in
  on|off) ;;
  *)
    echo "[mesh_up][ERR] unsupported video main mode: $VIDEO_MAIN_MODE" >&2
    echo "[mesh_up][ERR] expected: on or off" >&2
    exit 1
    ;;
esac

case "$DASHBOARD_MODE" in
  auto|on|off) ;;
  *)
    echo "[mesh_up][ERR] unsupported dashboard mode: $DASHBOARD_MODE" >&2
    echo "[mesh_up][ERR] expected: auto, on, or off" >&2
    exit 1
    ;;
esac

case "$CONTROL_MODE" in
  auto|on|off) ;;
  *)
    echo "[mesh_up][ERR] unsupported control mode: $CONTROL_MODE" >&2
    echo "[mesh_up][ERR] expected: auto, on, or off" >&2
    exit 1
    ;;
esac

case "$BMV2_MODE" in
  auto|on|off) ;;
  *)
    echo "[mesh_up][ERR] unsupported BMv2 mode: $BMV2_MODE" >&2
    echo "[mesh_up][ERR] expected: auto, on, or off" >&2
    exit 1
    ;;
esac

for f in "$WORLD_UP_SH" "$PX4_UP_SH" "$NET_UP_SH" "$METRICS_UP_SH" "$ENSURE_CONTAINER_SH" "$RTP_CAMERA_FLOW_SH" "$DASHBOARD_UP_SH" "$CONTROL_UP_SH" "$CONTROL_DOWN_SH"; do
  [[ -f "$f" ]] || { echo "[mesh_up][ERR] required file not found: $f" >&2; exit 1; }
done

TOPOLOGY_FILE="$("$PYTHON_BIN" -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$TOPOLOGY_FILE")"
[[ -f "$TOPOLOGY_FILE" ]] || { echo "[mesh_up][ERR] topology file not found: $TOPOLOGY_FILE" >&2; exit 1; }

readarray -t META < <("$PYTHON_BIN" - "$TOPOLOGY_FILE" <<'PY'
import json
import re
import sys

topo_file = sys.argv[1]
with open(topo_file, "r", encoding="utf-8") as f:
    topo = json.load(f)

scenario_id = topo.get("scenario_id")
if not scenario_id:
    raise SystemExit("[mesh_up][ERR] missing scenario_id")

instances = topo.get("instances", [])
flows = topo.get("globals", {}).get("business_flows", {})
video = flows.get("video", {})
video_main = flows.get("video_main", {})
control = flows.get("control", {})
mavsdk = control.get("mavsdk", {}) if isinstance(control, dict) else {}

def derive_idx(inst):
    if "idx" in inst:
        return int(inst["idx"])
    m = re.search(r"(\d+)$", str(inst.get("id", "")))
    if m:
        return int(m.group(1))
    raise SystemExit(f"[mesh_up][ERR] cannot derive idx from instance: {inst}")

idxs = []
for inst in instances:
    if inst.get("type") != "uav":
        continue
    idxs.append(derive_idx(inst))

idxs = sorted(set(idxs))
print(scenario_id)
print(1 if isinstance(video, dict) and video.get("enabled", False) else 0)
print(1 if isinstance(mavsdk, dict) and mavsdk.get("enabled", False) else 0)
print(int(video.get("default_bitrate_kbps", 4000)) if isinstance(video, dict) else 4000)
print(video.get("default_fps", 30) if isinstance(video, dict) else 30)
print(1 if isinstance(video_main, dict) and video_main.get("enabled", False) else 0)
print(int(video_main.get("default_bitrate_kbps", 8000)) if isinstance(video_main, dict) else 8000)
print(video_main.get("default_fps", 30) if isinstance(video_main, dict) else 30)
print(video.get("default_resolution", "960x540") if isinstance(video, dict) else "960x540")
print(video_main.get("default_resolution", "1920x1080") if isinstance(video_main, dict) else "1920x1080")
for idx in idxs:
    print(idx)
PY
)

SCENARIO_ID="${META[0]}"
TOPOLOGY_VIDEO_ENABLED="${META[1]}"
TOPOLOGY_CONTROL_ENABLED="${META[2]}"
TOPOLOGY_VIDEO_BITRATE_KBPS="${META[3]}"
TOPOLOGY_VIDEO_FPS="${META[4]}"
TOPOLOGY_VIDEO_MAIN_ENABLED="${META[5]}"
TOPOLOGY_VIDEO_MAIN_BITRATE_KBPS="${META[6]}"
TOPOLOGY_VIDEO_MAIN_FPS="${META[7]}"
TOPOLOGY_VIDEO_RESOLUTION="${META[8]}"
TOPOLOGY_VIDEO_MAIN_RESOLUTION="${META[9]}"
IDXS=("${META[@]:10}")
VIDEO_BITRATE_KBPS="${VIDEO_BITRATE_KBPS:-$TOPOLOGY_VIDEO_BITRATE_KBPS}"
VIDEO_FPS="${VIDEO_FPS:-$TOPOLOGY_VIDEO_FPS}"
VIDEO_MAIN_RUNTIME_ENABLED=0
if [[ "$TOPOLOGY_VIDEO_MAIN_ENABLED" == "1" && "$VIDEO_MAIN_MODE" == "on" ]]; then
  VIDEO_MAIN_RUNTIME_ENABLED=1
fi

GAZEBO_DOCKER_GPU_ENABLED=0
if [[ "${UCS_GAZEBO_DOCKER_GPU:-0}" =~ ^(1|true|True|TRUE|yes|Yes|YES|on|On|ON)$ ]]; then
  GAZEBO_DOCKER_GPU_ENABLED=1
fi

if [[ "$UCS_GAZEBO_BACKEND" == "docker" && "$WORLD_GUI" != "1" && "$UCS_GAZEBO_CAMERA_PROFILE_EXPLICIT" -eq 0 && "$GAZEBO_DOCKER_GPU_ENABLED" -eq 0 ]]; then
  UCS_GAZEBO_CAMERA_PROFILE="lite"
  UCS_GAZEBO_CAMERA_PROFILE_AUTO=1
  VIDEO_MAIN_RUNTIME_ENABLED=0
  if [[ "$VIDEO_FPS_EXPLICIT" -eq 0 ]]; then
    VIDEO_FPS=10
  fi
  if [[ "$VIDEO_BITRATE_KBPS_EXPLICIT" -eq 0 ]]; then
    VIDEO_BITRATE_KBPS=800
  fi
fi
if [[ "$UCS_GAZEBO_BACKEND" == "docker" && "$WORLD_GUI" != "1" && "$UCS_GAZEBO_CAMERA_PROFILE_EXPLICIT" -eq 0 && "$GAZEBO_DOCKER_GPU_ENABLED" -eq 1 && "$VIDEO_MAIN_RUNTIME_ENABLED" == "1" ]]; then
  UCS_GAZEBO_CAMERA_PROFILE="1080p"
  UCS_GAZEBO_CAMERA_PROFILE_AUTO=1
fi
if [[ "$UCS_GAZEBO_BACKEND" == "docker" && "$WORLD_GUI" != "1" && "$UCS_GAZEBO_CAMERA_PROFILE_EXPLICIT" -eq 0 && "$GAZEBO_DOCKER_GPU_ENABLED" -eq 1 && "$VIDEO_MAIN_RUNTIME_ENABLED" != "1" ]]; then
  UCS_GAZEBO_CAMERA_PROFILE="custom"
  UCS_GAZEBO_CAMERA_PROFILE_AUTO=1
  if [[ "$UCS_GAZEBO_CAMERA_SETTINGS_EXPLICIT" -eq 0 && "$TOPOLOGY_VIDEO_RESOLUTION" =~ ^([0-9]+)x([0-9]+)$ ]]; then
    UCS_GAZEBO_CAMERA_WIDTH="${BASH_REMATCH[1]}"
    UCS_GAZEBO_CAMERA_HEIGHT="${BASH_REMATCH[2]}"
    UCS_GAZEBO_CAMERA_UPDATE_RATE="$VIDEO_FPS"
    UCS_GAZEBO_CAMERA_VISUALIZE="${UCS_GAZEBO_CAMERA_VISUALIZE:-false}"
  fi
fi
if [[ "$UCS_GAZEBO_BACKEND" == "docker" && "$GAZEBO_DOCKER_GPU_ENABLED" -eq 1 ]]; then
  if [[ "$VIDEO_ENCODER_EXPLICIT" -eq 0 ]]; then
    VIDEO_ENCODER="hard"
  fi
  if [[ "$DASHBOARD_VIDEO_DECODER_EXPLICIT" -eq 0 ]]; then
    export DASHBOARD_VIDEO_DECODER="hard"
  fi
fi
export UCS_GAZEBO_CAMERA_PROFILE UCS_GAZEBO_CAMERA_WIDTH UCS_GAZEBO_CAMERA_HEIGHT
export UCS_GAZEBO_CAMERA_UPDATE_RATE UCS_GAZEBO_CAMERA_VISUALIZE
UCS_GAZEBO_CAMERA_PROFILE_LABEL="${UCS_GAZEBO_CAMERA_PROFILE:-off}"
if [[ "$UCS_GAZEBO_CAMERA_PROFILE_AUTO" == "1" ]]; then
  UCS_GAZEBO_CAMERA_PROFILE_LABEL="${UCS_GAZEBO_CAMERA_PROFILE_LABEL}, auto"
fi

[[ ${#IDXS[@]} -gt 0 ]] || { echo "[mesh_up][ERR] no UAV idx resolved from topology" >&2; exit 1; }

PID_DIR="/tmp/ucs-mesh-${UID}/${SCENARIO_ID}"
mkdir -p "$PID_DIR"

NS3_PIDFILE="/tmp/ucs_mesh_ns3_${SCENARIO_ID}.pid"
NS3_LOGFILE="/tmp/ucs_mesh_ns3_${SCENARIO_ID}.launcher.log"
METRICS_LOGFILE="/tmp/ucs_mesh_metrics_${SCENARIO_ID}.launcher.log"
METRICS_RUNTIME_JSON="/tmp/ucs_mesh_metrics_${SCENARIO_ID}.runtime.json"
METRICS_PIDFILE="/tmp/ucs_mesh_metrics_${SCENARIO_ID}.pid"
NET_READY_FILE="${PID_DIR}/net.ready"
RTP_LOGFILE="/tmp/ucs_mesh_rtp_camera_${SCENARIO_ID}.launcher.log"
RTP_PIDFILE="${PID_DIR}/rtp-camera.pid"
RTP_RUN_DIR="${PID_DIR}/rtp-camera"
DASHBOARD_LOGFILE="/tmp/ucs_mesh_dashboard_${SCENARIO_ID}.launcher.log"
DASHBOARD_PIDFILE="${PID_DIR}/dashboard.pid"
CONTROL_LOGFILE="/tmp/ucs_mesh_control_${SCENARIO_ID}_${CONTROL_UAV}.launcher.log"

cat > "${PID_DIR}/meta.env" <<EOF2
SCENARIO_ID='${SCENARIO_ID}'
TOPOLOGY_FILE='${TOPOLOGY_FILE}'
PID_DIR='${PID_DIR}'
UAV_IDXS='${IDXS[*]}'
TERMINAL_MODE='${TERMINAL_MODE}'
VIDEO_MODE='${VIDEO_MODE}'
VIDEO_MAIN_MODE='${VIDEO_MAIN_MODE}'
TOPOLOGY_VIDEO_ENABLED='${TOPOLOGY_VIDEO_ENABLED}'
TOPOLOGY_VIDEO_MAIN_ENABLED='${TOPOLOGY_VIDEO_MAIN_ENABLED}'
VIDEO_MAIN_RUNTIME_ENABLED='${VIDEO_MAIN_RUNTIME_ENABLED}'
DASHBOARD_MODE='${DASHBOARD_MODE}'
CONTROL_MODE='${CONTROL_MODE}'
TOPOLOGY_CONTROL_ENABLED='${TOPOLOGY_CONTROL_ENABLED}'
CONTROL_UAV='${CONTROL_UAV}'
BMV2_MODE='${BMV2_MODE}'
CONTROL_RELAY_PORT_BASE='${CONTROL_RELAY_PORT_BASE}'
CONTROL_CORE_PORT_BASE='${CONTROL_CORE_PORT_BASE}'
CONTROL_MAVSDK_SERVER_PORT_BASE='${CONTROL_MAVSDK_SERVER_PORT_BASE}'
EOF2
printf '%s\n' "$TOPOLOGY_FILE" > "${PID_DIR}/topology.path"

TERMINAL=""
if [[ "$TERMINAL_MODE" == "full" ]]; then
  if command -v gnome-terminal >/dev/null 2>&1; then
    TERMINAL="gnome-terminal"
  elif command -v x-terminal-emulator >/dev/null 2>&1; then
    TERMINAL="x-terminal-emulator"
  else
    echo "[mesh_up][ERR] no supported terminal launcher found" >&2
    exit 1
  fi
fi

open_terminal_hold() {
  local title="$1"
  local cmd="$2"
  local pidfile="${3:-}"

  local pid_prefix=""
  if [[ -n "$pidfile" ]]; then
    mkdir -p "$(dirname -- "$pidfile")"
    pid_prefix="echo \$\$ > '$pidfile'; "
  fi

  local wrapped_cmd
  wrapped_cmd="${pid_prefix}${cmd}; rc=\$?; echo; echo '[${title}] exit '\$rc; exec bash --noprofile --norc -i"

  if [[ "$TERMINAL" == "gnome-terminal" ]]; then
    gnome-terminal --title="$title" -- bash --noprofile --norc -lc "$wrapped_cmd"
  else
    x-terminal-emulator -T "$title" -e bash --noprofile --norc -lc "$wrapped_cmd"
  fi
}

run_logged() {
  local label="$1"
  local logfile="$2"
  shift 2

  mkdir -p "$(dirname -- "$logfile")"
  log "${label} log = ${logfile}"
  "$@" >"$logfile" 2>&1
}

wait_net_ready() {
  local deadline=$((SECONDS + WAIT_READY_TIMEOUT_SEC))
  local status=""

  while (( SECONDS < deadline )); do
    if [[ -f "$NET_READY_FILE" ]]; then
      status="$(tr -d '\r\n' < "$NET_READY_FILE" 2>/dev/null || true)"
      case "$status" in
        ready)
          log "network plumbing ready"
          return 0
          ;;
        failed)
          echo "[mesh_up][ERR] network plumbing failed; check mesh-ns3-live terminal" >&2
          return 1
          ;;
      esac
    fi
    sleep 0.5
  done

  echo "[mesh_up][ERR] timed out waiting for network plumbing ready file: $NET_READY_FILE" >&2
  echo "[mesh_up][ERR] check mesh-ns3-live terminal" >&2
  return 1
}

metrics_files_ready() {
  "$PYTHON_BIN" - "$METRICS_RUNTIME_JSON" <<'PY'
import json
import sys
from pathlib import Path

runtime_file = Path(sys.argv[1])
try:
    runtime = json.loads(runtime_file.read_text(encoding="utf-8"))
except Exception:
    raise SystemExit(1)

links = runtime.get("links", [])
if not links:
    raise SystemExit(1)

for link in links:
    metrics_file = link.get("metrics_file")
    if not metrics_file:
        raise SystemExit(1)
    try:
        parts = Path(metrics_file).read_text(encoding="utf-8").strip().split()
    except OSError:
        raise SystemExit(1)
    if len(parts) < 10:
        raise SystemExit(1)

print(len(links))
PY
}

wait_metrics_ready() {
  local deadline=$((SECONDS + WAIT_READY_TIMEOUT_SEC))

  while (( SECONDS < deadline )); do
    if [[ -s "$METRICS_RUNTIME_JSON" && -s "$METRICS_PIDFILE" ]]; then
      local metrics_pid
      metrics_pid="$(cat "$METRICS_PIDFILE" 2>/dev/null || true)"
      if [[ -n "$metrics_pid" ]] && kill -0 "$metrics_pid" 2>/dev/null; then
        if metrics_files_ready >/dev/null 2>&1; then
          log "metrics runtime and samples ready"
          return 0
        fi
      fi
    fi
    sleep 0.5
  done

  echo "[mesh_up][ERR] timed out waiting for metrics runtime/samples: $METRICS_RUNTIME_JSON" >&2
  echo "[mesh_up][ERR] check metrics log: $METRICS_LOGFILE" >&2
  return 1
}

metrics_sim_time_value() {
  "$PYTHON_BIN" - "$METRICS_RUNTIME_JSON" <<'PY'
import json
import math
import sys
from pathlib import Path

runtime = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
time_file = Path(str(runtime.get("time_file", "")))
value = float(time_file.read_text(encoding="utf-8").strip())
if not math.isfinite(value):
    raise SystemExit(1)
print(f"{value:.6f}")
PY
}

sim_time_advanced() {
  "$PYTHON_BIN" - "$1" "$2" <<'PY'
import sys

before = float(sys.argv[1])
after = float(sys.argv[2])
raise SystemExit(0 if after > before + 0.02 else 1)
PY
}

sim_time_reset() {
  "$PYTHON_BIN" - "$1" "$2" <<'PY'
import sys

before = float(sys.argv[1])
after = float(sys.argv[2])
raise SystemExit(0 if after + 0.02 < before else 1)
PY
}

wait_sim_time_advancing() {
  local before=""
  local after=""
  local reset_noted=0
  local deadline=$((SECONDS + 12))

  before="$(metrics_sim_time_value 2>/dev/null || true)"
  if [[ -z "$before" ]]; then
    echo "[mesh_up][ERR] cannot read Gazebo sim time from metrics runtime: $METRICS_RUNTIME_JSON" >&2
    return 1
  fi

  while (( SECONDS < deadline )); do
    sleep 0.5
    after="$(metrics_sim_time_value 2>/dev/null || true)"
    if [[ -n "$after" ]] && sim_time_advanced "$before" "$after"; then
      log "Gazebo sim time advancing: ${before}s -> ${after}s"
      return 0
    fi
    if [[ -n "$after" ]] && sim_time_reset "$before" "$after"; then
      if [[ "$reset_noted" -eq 0 ]]; then
        log "Gazebo sim time reset observed: ${before}s -> ${after}s; waiting for new clock advance"
        reset_noted=1
      fi
      before="$after"
    fi
  done

  echo "[mesh_up][ERR] Gazebo sim time is not advancing: ${before}s -> ${after:-unreadable}s" >&2
  echo "[mesh_up][ERR] check world log: ${PID_DIR}/world-A.log" >&2
  return 1
}

request_sudo_once() {
  log "validating sudo once in fleet_up.sh ..."
  if sudo -n true 2>/dev/null; then
    return 0
  fi
  sudo -v
}

video_should_start() {
  case "$VIDEO_MODE" in
    on)
      return 0
      ;;
    off)
      return 1
      ;;
    auto)
      [[ "$TOPOLOGY_VIDEO_ENABLED" == "1" ]]
      ;;
  esac
}

dashboard_should_start() {
  case "$DASHBOARD_MODE" in
    on)
      return 0
      ;;
    off)
      return 1
      ;;
    auto)
      [[ "$TOPOLOGY_VIDEO_ENABLED" == "1" || "$TOPOLOGY_CONTROL_ENABLED" == "1" ]]
      ;;
  esac
}

control_should_start() {
  case "$CONTROL_MODE" in
    on)
      return 0
      ;;
    off)
      return 1
      ;;
    auto)
      [[ "$TOPOLOGY_CONTROL_ENABLED" == "1" ]]
      ;;
  esac
}

uav_id_for_idx() {
  printf 'uav%02d\n' "$1"
}

uav_idx_from_id() {
  local target="$1"
  if [[ "$target" =~ ([0-9]+)$ ]]; then
    printf '%d\n' "$((10#${BASH_REMATCH[1]}))"
    return 0
  fi
  echo "[mesh_up][ERR] cannot derive UAV idx from control target: ${target}" >&2
  return 1
}

control_targets() {
  if [[ "$CONTROL_UAV" == "all" ]]; then
    local idx
    for idx in "${IDXS[@]}"; do
      uav_id_for_idx "$idx"
    done
  else
    printf '%s\n' "$CONTROL_UAV"
  fi
}

control_relay_port_for() {
  local target="$1"
  if [[ "$CONTROL_UAV" == "all" ]]; then
    local idx
    idx="$(uav_idx_from_id "$target")" || return 1
    printf '%d\n' "$((CONTROL_RELAY_PORT_BASE + idx))"
  else
    printf '%d\n' "$CONTROL_RELAY_PORT"
  fi
}

control_core_port_for() {
  local target="$1"
  if [[ "$CONTROL_UAV" == "all" ]]; then
    local idx
    idx="$(uav_idx_from_id "$target")" || return 1
    printf '%d\n' "$((CONTROL_CORE_PORT_BASE + idx))"
  else
    printf '%d\n' "$CONTROL_CORE_PORT"
  fi
}

control_mavsdk_server_port_for() {
  local target="$1"
  if [[ "$CONTROL_UAV" == "all" ]]; then
    local idx
    idx="$(uav_idx_from_id "$target")" || return 1
    printf '%d\n' "$((CONTROL_MAVSDK_SERVER_PORT_BASE + idx))"
  else
    printf '%d\n' "$CONTROL_MAVSDK_SERVER_PORT"
  fi
}

tcp_port_open() {
  local host="$1"
  local port="$2"
  "$PYTHON_BIN" - "$host" "$port" <<'PY'
import socket
import sys

host, port = sys.argv[1], int(sys.argv[2])
sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
sock.settimeout(0.3)
try:
    sock.connect((host, port))
except OSError:
    raise SystemExit(1)
finally:
    sock.close()
PY
}

tcp_port_pid() {
  local port="$1"
  command -v ss >/dev/null 2>&1 || return 1
  ss -ltnp "sport = :${port}" 2>/dev/null |
    sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p' |
    head -n 1
}

stop_existing_dashboard_on_port() {
  local port="$1"
  local pid cmd

  pid="$(tcp_port_pid "$port" || true)"
  [[ -n "$pid" && "$pid" =~ ^[0-9]+$ ]] || return 1

  cmd="$(tr '\0' ' ' <"/proc/${pid}/cmdline" 2>/dev/null || true)"
  [[ "$cmd" == *"frontend/dashboard_server.py"* ]] || return 1

  log "stopping existing dashboard on port ${port}: pid=${pid}"
  kill -TERM "$pid" 2>/dev/null || sudo -n kill -TERM "$pid" 2>/dev/null || true
  for _ in {1..20}; do
    if ! tcp_port_open 127.0.0.1 "$port"; then
      return 0
    fi
    sleep 0.2
  done

  kill -KILL "$pid" 2>/dev/null || sudo -n kill -KILL "$pid" 2>/dev/null || true
  for _ in {1..10}; do
    if ! tcp_port_open 127.0.0.1 "$port"; then
      return 0
    fi
    sleep 0.2
  done
  return 0
}

start_detached_logged() {
  local logfile="$1"
  shift

  if command -v setsid >/dev/null 2>&1; then
    setsid "$@" >"$logfile" 2>&1 < /dev/null &
  else
    nohup "$@" >"$logfile" 2>&1 < /dev/null &
  fi
  printf '%s\n' "$!"
}

start_session_logged() {
  local logfile="$1"
  shift

  nohup "$@" >"$logfile" 2>&1 &
  printf '%s\n' "$!"
}

start_control() {
  if ! control_should_start; then
    log "control = skipped (mode=${CONTROL_MODE}, topology_control=${TOPOLOGY_CONTROL_ENABLED})"
    return 0
  fi

  local target relay_port core_port mavsdk_port log_file
  while IFS= read -r target; do
    [[ -n "$target" ]] || continue
    relay_port="$(control_relay_port_for "$target")" || return 1
    core_port="$(control_core_port_for "$target")" || return 1
    mavsdk_port="$(control_mavsdk_server_port_for "$target")" || return 1
    log_file="/tmp/ucs_mesh_control_${SCENARIO_ID}_${target}.launcher.log"

    if tcp_port_open 127.0.0.1 "$relay_port"; then
      if tcp_port_open 127.0.0.1 "$core_port" && tcp_port_open 127.0.0.1 "$mavsdk_port"; then
        log "control backend already open: target=${target} ws://127.0.0.1:${relay_port} core=${core_port} mavsdk_server=${mavsdk_port}"
        continue
      fi
      log "control backend partially open; restarting target=${target} relay=${relay_port} core=${core_port} mavsdk_server=${mavsdk_port}"
    fi

    "$CONTROL_DOWN_SH" --scenario "$SCENARIO_ID" --uav "$target" >/dev/null 2>&1 || true
    rm -f "$log_file"
    log "launching browser control backend for ${target} ..."
    log "control log = ${log_file}"
    if ! "$CONTROL_UP_SH" \
        --topology "$TOPOLOGY_FILE" \
        --uav "$target" \
        --core-port "$core_port" \
        --relay-port "$relay_port" \
        --mavsdk-server-port "$mavsdk_port" \
        --bg \
        >"$log_file" 2>&1; then
      echo "[mesh_up][ERR] control backend failed for ${target}; check log: ${log_file}" >&2
      sed -n '1,160p' "$log_file" >&2 || true
      return 1
    fi

    if ! tcp_port_open 127.0.0.1 "$relay_port"; then
      echo "[mesh_up][ERR] control relay is not open after startup: target=${target} ws://127.0.0.1:${relay_port}" >&2
      sed -n '1,160p' "$log_file" >&2 || true
      return 1
    fi
    log "control websocket = ws://127.0.0.1:${relay_port} target=${target} core=${core_port} mavsdk_server=${mavsdk_port}"
  done < <(control_targets)
}

start_video_flow() {
  if ! video_should_start; then
    log "video stream = skipped (mode=${VIDEO_MODE}, topology_enabled=${TOPOLOGY_VIDEO_ENABLED})"
    return 0
  fi

  if [[ -f "$RTP_PIDFILE" ]]; then
    local old_pid
    old_pid="$(cat "$RTP_PIDFILE" 2>/dev/null || true)"
    if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
      log "video stream already running: pid=${old_pid}"
      return 0
    fi
    rm -f "$RTP_PIDFILE"
  fi

  mkdir -p "$RTP_RUN_DIR"
  rm -f "$RTP_LOGFILE"
  log "launching RTP camera streams ..."
  log "video log = ${RTP_LOGFILE}"
  local flow_args=(--flow video)
  if [[ "$VIDEO_MAIN_RUNTIME_ENABLED" == "1" ]]; then
    flow_args+=(--flow video_main)
  fi
  local override_args=()
  if [[ "$VIDEO_BITRATE_KBPS_EXPLICIT" -eq 1 || "$UCS_GAZEBO_CAMERA_PROFILE_AUTO" == "1" && "$GAZEBO_DOCKER_GPU_ENABLED" -eq 0 ]]; then
    override_args+=(--bitrate-kbps "$VIDEO_BITRATE_KBPS")
  fi
  if [[ "$VIDEO_FPS_EXPLICIT" -eq 1 || "$UCS_GAZEBO_CAMERA_PROFILE_AUTO" == "1" && "$GAZEBO_DOCKER_GPU_ENABLED" -eq 0 ]]; then
    override_args+=(--fps "$VIDEO_FPS")
  fi
  local rtp_pid
  rtp_pid="$(start_session_logged "$RTP_LOGFILE" \
    env RTP_RUN_DIR="$RTP_RUN_DIR" \
    "$RTP_CAMERA_FLOW_SH" \
      --topology "$TOPOLOGY_FILE" \
      --all \
      "${flow_args[@]}" \
      "${override_args[@]}" \
      --encoder "$VIDEO_ENCODER")"
  printf '%s\n' "$rtp_pid" > "$RTP_PIDFILE"
  sleep 0.5
  if ! kill -0 "$rtp_pid" 2>/dev/null; then
    echo "[mesh_up][ERR] RTP camera launcher exited early; check log: ${RTP_LOGFILE}" >&2
    sed -n '1,120p' "$RTP_LOGFILE" >&2 || true
    return 1
  fi
  log "video streams pidfile = ${RTP_PIDFILE}"
}

start_dashboard() {
  if ! dashboard_should_start; then
    log "dashboard = skipped (mode=${DASHBOARD_MODE}, topology_video=${TOPOLOGY_VIDEO_ENABLED})"
    return 0
  fi

  if [[ -f "$DASHBOARD_PIDFILE" ]]; then
    local old_pid
    old_pid="$(cat "$DASHBOARD_PIDFILE" 2>/dev/null || true)"
    if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
      log "dashboard already running: pid=${old_pid} url=http://127.0.0.1:${DASHBOARD_PORT}"
      return 0
    fi
    rm -f "$DASHBOARD_PIDFILE"
  fi

  local probe_host="$DASHBOARD_HOST"
  if [[ "$probe_host" == "0.0.0.0" || "$probe_host" == "::" ]]; then
    probe_host="127.0.0.1"
  fi

  if tcp_port_open "$probe_host" "$DASHBOARD_PORT"; then
    if stop_existing_dashboard_on_port "$DASHBOARD_PORT"; then
      if tcp_port_open "$probe_host" "$DASHBOARD_PORT"; then
        log "dashboard port still open after stopping old dashboard: http://127.0.0.1:${DASHBOARD_PORT}"
        return 0
      fi
    else
      log "dashboard port already open: http://127.0.0.1:${DASHBOARD_PORT}"
      return 0
    fi
  fi

  if tcp_port_open "$probe_host" "$DASHBOARD_PORT"; then
    log "dashboard port already open: http://127.0.0.1:${DASHBOARD_PORT}"
    return 0
  fi

  rm -f "$DASHBOARD_LOGFILE"
  log "launching dashboard/video proxy ..."
  log "dashboard log = ${DASHBOARD_LOGFILE}"
  local dashboard_args=(
    "$DASHBOARD_UP_SH"
    --topology "$TOPOLOGY_FILE"
    --host "$DASHBOARD_HOST"
    --port "$DASHBOARD_PORT"
    --control-protocol relay
  )
  if [[ "$CONTROL_UAV" != "all" ]]; then
    dashboard_args+=(--control-ws "ws://127.0.0.1:${CONTROL_RELAY_PORT}")
  fi
  local dashboard_pid
  dashboard_pid="$(start_detached_logged "$DASHBOARD_LOGFILE" \
    "${dashboard_args[@]}")"
  printf '%s\n' "$dashboard_pid" > "$DASHBOARD_PIDFILE"
  sleep 0.5
  if ! kill -0 "$dashboard_pid" 2>/dev/null; then
    echo "[mesh_up][ERR] dashboard exited early; check log: ${DASHBOARD_LOGFILE}" >&2
    sed -n '1,120p' "$DASHBOARD_LOGFILE" >&2 || true
    return 1
  fi
  log "dashboard url = http://127.0.0.1:${DASHBOARD_PORT}"
}

log "topology = $TOPOLOGY_FILE"
log "scenario = $SCENARIO_ID"
log "uav idxs = ${IDXS[*]}"
log "pid dir   = $PID_DIR"
log "net ready = $NET_READY_FILE"
log "terminals = $TERMINAL_MODE"
log "gazebo   = $([[ "$WORLD_GUI" == "1" ]] && echo gui || echo headless) (backend=${UCS_GAZEBO_BACKEND}, camera_profile=${UCS_GAZEBO_CAMERA_PROFILE_LABEL})"
VIDEO_STREAM_SUMMARY="sub=${TOPOLOGY_VIDEO_RESOLUTION}@${VIDEO_FPS}/${VIDEO_BITRATE_KBPS}kbps port=5600+idx"
if [[ "$TOPOLOGY_VIDEO_MAIN_ENABLED" == "1" ]]; then
  VIDEO_MAIN_STATE="available/off"
  if [[ "$VIDEO_MAIN_RUNTIME_ENABLED" == "1" ]]; then
    VIDEO_MAIN_STATE="active"
  fi
  VIDEO_STREAM_SUMMARY="${VIDEO_STREAM_SUMMARY}, main=${TOPOLOGY_VIDEO_MAIN_RESOLUTION}@${TOPOLOGY_VIDEO_MAIN_FPS}/${TOPOLOGY_VIDEO_MAIN_BITRATE_KBPS}kbps port=5700+idx (${VIDEO_MAIN_STATE}, mode=${VIDEO_MAIN_MODE})"
fi
log "video    = ${VIDEO_MODE} (topology_enabled=${TOPOLOGY_VIDEO_ENABLED}, encoder=${VIDEO_ENCODER}, decoder=${DASHBOARD_VIDEO_DECODER:-auto}, ${VIDEO_STREAM_SUMMARY})"
log "bmv2     = ${BMV2_MODE}"
if [[ "$CONTROL_UAV" == "all" ]]; then
  log "control  = ${CONTROL_MODE} (topology_enabled=${TOPOLOGY_CONTROL_ENABLED}, target=all, relay_base=${CONTROL_RELAY_PORT_BASE}, core_base=${CONTROL_CORE_PORT_BASE}, mavsdk_base=${CONTROL_MAVSDK_SERVER_PORT_BASE})"
else
  log "control  = ${CONTROL_MODE} (topology_enabled=${TOPOLOGY_CONTROL_ENABLED}, target=${CONTROL_UAV}, ws=${CONTROL_RELAY_PORT}, core=${CONTROL_CORE_PORT})"
fi
log "dashboard = ${DASHBOARD_MODE} (host=${DASHBOARD_HOST}, port=${DASHBOARD_PORT})"

if [[ -f "$NS3_PIDFILE" ]]; then
  OLD_PID="$(cat "$NS3_PIDFILE" 2>/dev/null || true)"
  if [[ -n "$OLD_PID" ]] && kill -0 "$OLD_PID" 2>/dev/null; then
    echo "[mesh_up][ERR] ns-3 live already running: pid=$OLD_PID" >&2
    echo "[mesh_up][ERR] run fleet_down.sh first" >&2
    exit 1
  fi
  rm -f "$NS3_PIDFILE"
fi

request_sudo_once

log "ensuring containers ..."
for idx in "${IDXS[@]}"; do
  "$ENSURE_CONTAINER_SH" --topology "$TOPOLOGY_FILE" --idx "$idx"
done

log "launching world helper ..."
WORLD_VISUAL_ARG="--headless"
if [[ "$WORLD_GUI" == "1" ]]; then
  WORLD_VISUAL_ARG="--gui"
fi
if [[ "$TERMINAL_MODE" == "full" ]]; then
  WORLD_CMD="PID_DIR='$PID_DIR' UCS_GZ_GUI='$WORLD_GUI' '$WORLD_UP_SH' --topology '$TOPOLOGY_FILE' '$WORLD_VISUAL_ARG'"
  open_terminal_hold "mesh-world" "$WORLD_CMD" "${PID_DIR}/world-launcher.pid"
else
  run_logged "world launcher" "${PID_DIR}/world-launcher.log" \
    env PID_DIR="$PID_DIR" UCS_GZ_GUI="$WORLD_GUI" UCS_MESH_NO_TERMINALS=1 \
    "$WORLD_UP_SH" --topology "$TOPOLOGY_FILE" "$WORLD_VISUAL_ARG" --no-terminal
fi

sleep 0.8

log "launching PX4 helpers ..."
for idx in "${IDXS[@]}"; do
  uav_num="$(printf '%02d' "$idx")"
  if [[ "$TERMINAL_MODE" == "full" ]]; then
    PX4_CMD="PID_DIR='$PID_DIR' '$PX4_UP_SH' --topology '$TOPOLOGY_FILE' --idx '$idx'"
    open_terminal_hold "mesh-px4-uav${uav_num}" "$PX4_CMD" "${PID_DIR}/px4-uav${uav_num}-launcher.pid"
  else
    run_logged "px4 launcher uav${uav_num}" "${PID_DIR}/px4-uav${uav_num}-launcher.log" \
      env PID_DIR="$PID_DIR" UCS_MESH_NO_TERMINALS=1 \
      "$PX4_UP_SH" --topology "$TOPOLOGY_FILE" --idx "$idx" --no-terminal
  fi
  sleep 0.5
done

sleep 1.5

log "launching metrics helper before ns-3 ..."
rm -f "$METRICS_RUNTIME_JSON" "$METRICS_LOGFILE" "$METRICS_PIDFILE"
METRICS_CMD=("$METRICS_UP_SH" "--topology" "$TOPOLOGY_FILE" "--bg")
[[ "$VERBOSE" -eq 1 ]] && METRICS_CMD+=("--verbose")
nohup "${METRICS_CMD[@]}" >"$METRICS_LOGFILE" 2>&1 &
METRICS_UP_PID="$!"
printf '%s\n' "$METRICS_UP_PID" > "${PID_DIR}/metrics-launcher.pid"

log "waiting for metrics runtime ..."
wait_metrics_ready
wait_sim_time_advancing

log "launching ns-3 live + network plumbing helper ..."
rm -f "$NET_READY_FILE" "$NS3_LOGFILE"
NET_CMD=("$NET_UP_SH" "--topology" "$TOPOLOGY_FILE" "--sudo-ready" "--ready-file" "$NET_READY_FILE")
[[ "$VERBOSE" -eq 1 ]] && NET_CMD+=("--verbose")
NET_ENV=()
case "$BMV2_MODE" in
  off)
    NET_ENV+=(UCS_MESH_DISABLE_BMV2=1)
    ;;
  on)
    NET_ENV+=(UCS_MESH_DISABLE_BMV2=0 UCS_MESH_EDGE_DATAPLANE=container_bmv2_inline)
    ;;
esac
NET_UP_PID="$(start_detached_logged "$NS3_LOGFILE" \
  env "${NET_ENV[@]}" "${NET_CMD[@]}")"
printf '%s\n' "$NET_UP_PID" > "$NS3_PIDFILE"
printf '%s\n' "$NET_UP_PID" > "${PID_DIR}/ns3.pid"
if [[ "$TERMINAL_MODE" == "full" ]]; then
  open_terminal_hold "mesh-ns3-live" "tail --pid='$NET_UP_PID' -n +1 -F '$NS3_LOGFILE'" "${PID_DIR}/ns3-log-launcher.pid"
fi

log "waiting for network plumbing ..."
if ! wait_net_ready; then
  "$METRICS_UP_SH" --topology "$TOPOLOGY_FILE" --stop || true
  exit 1
fi

start_dashboard
start_control
start_video_flow
wait_sim_time_advancing

echo
log "launched."
log "pid dir        = $PID_DIR"
log "ns3 pidfile    = $NS3_PIDFILE"
log "ns3 log        = $NS3_LOGFILE"
log "net ready file = $NET_READY_FILE"
log "metrics log    = $METRICS_LOGFILE"
if video_should_start; then
  log "video pidfile  = $RTP_PIDFILE"
  log "video log      = $RTP_LOGFILE"
fi
if dashboard_should_start; then
  log "dashboard url  = http://127.0.0.1:${DASHBOARD_PORT}"
  log "dashboard log  = $DASHBOARD_LOGFILE"
fi
if control_should_start; then
  if [[ "$CONTROL_UAV" == "all" ]]; then
    log "control target = all"
    while IFS= read -r target; do
      [[ -n "$target" ]] || continue
      log "control ws     = ${target} ws://127.0.0.1:$(control_relay_port_for "$target")"
      log "control log    = /tmp/ucs_mesh_control_${SCENARIO_ID}_${target}.launcher.log"
    done < <(control_targets)
  else
    log "control ws     = ws://127.0.0.1:${CONTROL_RELAY_PORT}"
    log "control target = $CONTROL_UAV"
    log "control log    = $CONTROL_LOGFILE"
  fi
fi
log "important:"
if [[ "$TERMINAL_MODE" == "full" ]]; then
  echo "  - 终端模式 full：保留 up 外层终端 + world_up/px4_up 内层 helper 终端"
else
  echo "  - 终端模式 minimal：world/PX4/ns-3/metrics 日志落盘，默认不再展开 helper 终端"
  echo "  - PX4 日志目录：${PID_DIR}"
fi
echo "  - PID 记账供 fleet_down 对称回收"
