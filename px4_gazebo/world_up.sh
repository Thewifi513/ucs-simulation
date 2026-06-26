#!/usr/bin/env bash
set -Eeuo pipefail

# UCS mesh world launcher
# 只负责启动场景级 Gazebo world，不启动任何单架 UAV/PX4。

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MESH_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${MESH_DIR}/fleet/env_defaults.sh"

WORLD_SDF_EXPLICIT="${WORLD_SDF+x}"
WORLD_SDF="${WORLD_SDF:-$PX4_DIR/Tools/simulation/gz/worlds/default.sdf}"
SCRIPTS_ROOT="$UCS_SCRIPTS_ROOT"
DEFAULT_TOPOLOGY="${MESH_DIR}/topology/wifi_adhoc_matrix_2x3_6uav.json"
TOPOLOGY_FILE="${TOPOLOGY_FILE:-$DEFAULT_TOPOLOGY}"
PID_DIR="${PID_DIR:-}"

UCS_GZ_GUI="${UCS_GZ_GUI:-0}"
UCS_GAZEBO_BACKEND="${UCS_GAZEBO_BACKEND:-host}"
UCS_GAZEBO_IMAGE="${UCS_GAZEBO_IMAGE:-ucs-gazebo-runtime:20260625}"
UCS_GAZEBO_CONTAINER_NAME="${UCS_GAZEBO_CONTAINER_NAME:-}"
UCS_GAZEBO_DOCKER_ARGS="${UCS_GAZEBO_DOCKER_ARGS:-}"
UCS_GAZEBO_DOCKER_GPU="${UCS_GAZEBO_DOCKER_GPU:-0}"
UCS_GAZEBO_DOCKER_HOST_LIBS="${UCS_GAZEBO_DOCKER_HOST_LIBS:-auto}"
UCS_GAZEBO_DOCKER_SOFTWARE_RENDER="${UCS_GAZEBO_DOCKER_SOFTWARE_RENDER:-auto}"
UCS_GAZEBO_RENDER_ENGINE="${UCS_GAZEBO_RENDER_ENGINE:-}"
UCS_GAZEBO_DISABLE_GST_CAMERA_SYSTEM="${UCS_GAZEBO_DISABLE_GST_CAMERA_SYSTEM:-auto}"
UCS_GAZEBO_DISABLE_OPTICAL_FLOW_SYSTEM="${UCS_GAZEBO_DISABLE_OPTICAL_FLOW_SYSTEM:-auto}"
UCS_GAZEBO_CAMERA_PROFILE="${UCS_GAZEBO_CAMERA_PROFILE:-}"
UCS_GAZEBO_CAMERA_WIDTH="${UCS_GAZEBO_CAMERA_WIDTH:-}"
UCS_GAZEBO_CAMERA_HEIGHT="${UCS_GAZEBO_CAMERA_HEIGHT:-}"
UCS_GAZEBO_CAMERA_UPDATE_RATE="${UCS_GAZEBO_CAMERA_UPDATE_RATE:-}"
UCS_GAZEBO_CAMERA_VISUALIZE="${UCS_GAZEBO_CAMERA_VISUALIZE:-}"
LAUNCH_VERIFY=0
NO_TERMINAL="${UCS_MESH_NO_TERMINALS:-0}"

usage() {
  cat <<EOF2
Usage: $(basename "$0") [--topology FILE] [--gui|--headless] [--backend host|docker] [--with-verify] [--no-terminal] [--help]

--topology FILE  JSON topology file.
--gui            Run Gazebo with GUI (gz sim -r).
--headless       Run Gazebo server-only (gz sim -s -r). This is the default.
--backend MODE   Gazebo backend: host or docker. Default: ${UCS_GAZEBO_BACKEND}.
--gazebo-image I Docker image for --backend docker. Default: ${UCS_GAZEBO_IMAGE}.
                  Set UCS_GAZEBO_DOCKER_HOST_LIBS=off to disable host library bridge.
                  Set UCS_GAZEBO_DOCKER_GPU=1 to run Docker headless rendering on NVIDIA.
                  Set UCS_GAZEBO_CAMERA_PROFILE=lite for a generated low-load camera overlay.
--with-verify    Also open verification terminal.
--no-terminal    Start helpers in the background and write logs under PID_DIR/cache.
--help           Show this help.

Examples:
  $(basename "$0")
  $(basename "$0") --gui
  $(basename "$0") --headless
  $(basename "$0") --backend docker --headless
  $(basename "$0") --topology ./topology/wifi_adhoc_matrix_2x3_6uav.json --with-verify
EOF2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --topology)
      [[ $# -ge 2 ]] || { echo "[ERR] --topology requires a path"; exit 1; }
      TOPOLOGY_FILE="$2"
      shift 2
      ;;
    --gui) UCS_GZ_GUI=1; shift ;;
    --headless|--no-gui) UCS_GZ_GUI=0; shift ;;
    --backend)
      [[ $# -ge 2 ]] || { echo "[ERR] --backend requires host or docker"; exit 1; }
      UCS_GAZEBO_BACKEND="$2"
      shift 2
      ;;
    --gazebo-image)
      [[ $# -ge 2 ]] || { echo "[ERR] --gazebo-image requires an image tag"; exit 1; }
      UCS_GAZEBO_IMAGE="$2"
      shift 2
      ;;
    --with-verify) LAUNCH_VERIFY=1; shift ;;
    --no-terminal) NO_TERMINAL=1; shift ;;
    --terminal) NO_TERMINAL=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "[ERR] Unknown argument: $1"
      usage
      exit 1
      ;;
  esac
done

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "[ERR] '$1' not found."; exit 1; }; }
need_cmd ip
need_cmd awk
need_cmd cut
need_cmd "$PYTHON_BIN"

case "$UCS_GAZEBO_BACKEND" in
  host)
    need_cmd gz
    ;;
  docker)
    need_cmd docker
    if [[ "$UCS_GZ_GUI" -eq 1 ]]; then
      echo "[ERR] docker Gazebo backend currently supports headless mode only." >&2
      exit 1
    fi
    if ! docker image inspect "$UCS_GAZEBO_IMAGE" >/dev/null 2>&1; then
      echo "[ERR] Gazebo Docker image not found: $UCS_GAZEBO_IMAGE" >&2
      echo "[ERR] build it first: ${MESH_DIR}/deploy/docker/gazebo-runtime/build_image.sh" >&2
      exit 1
    fi
    ;;
  *)
    echo "[ERR] unsupported Gazebo backend: $UCS_GAZEBO_BACKEND" >&2
    echo "[ERR] expected: host or docker" >&2
    exit 1
    ;;
esac

[[ -d "$PX4_DIR" ]] || { echo "[ERR] PX4_DIR not found: $PX4_DIR"; exit 1; }
[[ -f "$GZ_ENV_SH" ]] || { echo "[ERR] gz_env.sh not found: $GZ_ENV_SH"; exit 1; }
[[ -f "$TOPOLOGY_FILE" ]] || { echo "[ERR] topology file not found: $TOPOLOGY_FILE"; exit 1; }

TOPOLOGY_FILE="$("$PYTHON_BIN" -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$TOPOLOGY_FILE")"

HOST_DOCKER0_IP="$(ip -4 -o addr show docker0 | awk '{print $4}' | cut -d/ -f1 || true)"
[[ -n "$HOST_DOCKER0_IP" ]] || { echo "[ERR] docker0 has no IPv4. Is Docker running?"; exit 1; }

if command -v gnome-terminal >/dev/null 2>&1; then
  TERMINAL="gnome-terminal"
elif command -v x-terminal-emulator >/dev/null 2>&1; then
  TERMINAL="x-terminal-emulator"
else
  echo "[ERR] No supported terminal launcher found (need gnome-terminal or x-terminal-emulator)."
  exit 1
fi

open_terminal() {
  local title="$1"
  local script_path="$2"
  local pidfile="${3:-}"
  local pid_prefix=""

  if [[ -n "$pidfile" ]]; then
    mkdir -p "$(dirname -- "$pidfile")"
    pid_prefix="echo \$\$ > '$pidfile'; "
  fi

  local cmd="${pid_prefix}source '$script_path'; rc=\$?; echo; echo \"[$title] exit \$rc\"; exec bash --noprofile --norc -i"

  if [[ "$TERMINAL" == "gnome-terminal" ]]; then
    gnome-terminal --title="$title" -- bash --noprofile --norc -lc "$cmd"
  else
    x-terminal-emulator -T "$title" -e bash --noprofile --norc -lc "$cmd"
  fi
}

start_background() {
  local title="$1"
  local script_path="$2"
  local pidfile="${3:-}"
  local logfile="${4:-}"

  if [[ -z "$logfile" ]]; then
    logfile="$CACHE_DIR/${title}.log"
  fi
  mkdir -p "$(dirname -- "$logfile")"

  nohup "$script_path" >"$logfile" 2>&1 &
  local pid="$!"
  if [[ -n "$pidfile" ]]; then
    mkdir -p "$(dirname -- "$pidfile")"
    printf '%s\n' "$pid" > "$pidfile"
  fi
  echo "[OK] Started ${title} in background pid=${pid}"
  echo "     log: ${logfile}"
}

TOPOLOGY_EXPORTS="$(
"$PYTHON_BIN" - "$TOPOLOGY_FILE" "$MESH_DIR" "$SCRIPTS_ROOT" <<'PY'
import json, os, shlex, sys
path, mesh_dir, scripts_root = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, "r", encoding="utf-8") as f:
    topo = json.load(f)
g = topo.get("globals", {})
world_sdf = str(g.get("world_sdf", ""))
if world_sdf and not os.path.isabs(world_sdf):
    candidates = [
        os.path.abspath(os.path.join(mesh_dir, world_sdf)),
        os.path.abspath(os.path.join(scripts_root, world_sdf)),
    ]
    world_sdf = next((p for p in candidates if os.path.exists(p)), candidates[0])
pairs = {
    "TOPOLOGY_FILE": path,
    "SCENARIO_ID": topo.get("scenario_id", ""),
    "GZ_PARTITION_NAME": g.get("gz_partition", "ucs"),
    "PX4_GZ_WORLD_NAME": g.get("px4_gz_world_name", "default"),
    "PX4_SIM_MODEL_NAME": g.get("px4_sim_model_name", "gz_x500"),
    "WORLD_SDF_TOPOLOGY": world_sdf,
    "GS_IP": g.get("gs_ip", "10.10.0.254/24"),
    "TAP_LEFT": g.get("tap_left", "tap-gs"),
    "NS3_TIME_FILE": g.get("time_file", "/tmp/ucs_sim_time.txt"),
}
for k, v in pairs.items():
    print(f"export {k}={shlex.quote(str(v))}")
PY
)"
eval "$TOPOLOGY_EXPORTS"
unset TOPOLOGY_EXPORTS

if [[ -z "$WORLD_SDF_EXPLICIT" && -n "${WORLD_SDF_TOPOLOGY:-}" ]]; then
  WORLD_SDF="$WORLD_SDF_TOPOLOGY"
fi
[[ -f "$WORLD_SDF" ]] || { echo "[ERR] World SDF not found: $WORLD_SDF"; exit 1; }

export PX4_DIR GZ_ENV_SH WORLD_SDF PX4_GZ_MODELS PX4_GZ_WORLDS
export TOPOLOGY_FILE SCENARIO_ID
export GZ_PARTITION_NAME PX4_GZ_WORLD_NAME PX4_SIM_MODEL_NAME
export GS_IP TAP_LEFT NS3_TIME_FILE
export UCS_GZ_GUI PID_DIR SCRIPT_DIR MESH_DIR UCS_MESH_DIR UCS_ROOT UCS_WORKSPACE_ROOT
export UCS_GAZEBO_BACKEND UCS_GAZEBO_IMAGE UCS_GAZEBO_CONTAINER_NAME
export UCS_GAZEBO_DOCKER_ARGS UCS_GAZEBO_DOCKER_GPU UCS_GAZEBO_DOCKER_HOST_LIBS
export UCS_GAZEBO_DOCKER_SOFTWARE_RENDER
export UCS_GAZEBO_RENDER_ENGINE
export UCS_GAZEBO_DISABLE_GST_CAMERA_SYSTEM UCS_GAZEBO_DISABLE_OPTICAL_FLOW_SYSTEM
export UCS_GAZEBO_CAMERA_PROFILE UCS_GAZEBO_CAMERA_WIDTH UCS_GAZEBO_CAMERA_HEIGHT
export UCS_GAZEBO_CAMERA_UPDATE_RATE UCS_GAZEBO_CAMERA_VISUALIZE

CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/ucs-mesh"
mkdir -p "$CACHE_DIR"
[[ -n "$PID_DIR" ]] && mkdir -p "$PID_DIR"

A_SH="$CACHE_DIR/world-A-gz.sh"
B_SH="$CACHE_DIR/world-B-verify.sh"

cat >"$A_SH" <<'EOF2'
#!/usr/bin/env bash
set -Eeuo pipefail

WORLD_DOCKER_CONTAINER="${UCS_GAZEBO_CONTAINER_NAME:-ucs-gazebo-${SCENARIO_ID:-default}}"

world_cleanup() {
  local rc=$?
  if [[ "${UCS_GAZEBO_BACKEND:-host}" == "docker" ]]; then
    docker rm -f "$WORLD_DOCKER_CONTAINER" >/dev/null 2>&1 || true
  fi
  echo "[A] world script exit trap rc=$rc at $(date -Is)"
}

trap world_cleanup EXIT
trap 'echo "[A][ERR] world script received SIGHUP at $(date -Is)"; exit 129' HUP
trap 'echo "[A][ERR] world script received SIGINT at $(date -Is)"; exit 130' INT
trap 'echo "[A][ERR] world script received SIGTERM at $(date -Is)"; exit 143' TERM

if [[ "${UCS_GAZEBO_BACKEND:-host}" == "docker" ]]; then
  echo "[A] Remove leftover Gazebo container (if any): $WORLD_DOCKER_CONTAINER"
  docker rm -f "$WORLD_DOCKER_CONTAINER" >/dev/null 2>&1 || true
else
  echo "[A] Kill leftover gz/ign (if any) ..."
  pkill -f "gz sim" 2>/dev/null || true
  pkill -f "ign gazebo" 2>/dev/null || true
  sleep 1
  pgrep -af "gz sim|ign gazebo" || true
fi

cd "$PX4_DIR"

if [[ "${UCS_GAZEBO_BACKEND:-host}" == "host" ]]; then
  set +u
  source "$GZ_ENV_SH"
  set -u
fi

HOST_DOCKER0_IP="$(ip -4 -o addr show docker0 | awk '{print $4}' | cut -d/ -f1)"
export GZ_PARTITION="$GZ_PARTITION_NAME"
export GZ_IP="$HOST_DOCKER0_IP"

echo "[A] TOPOLOGY_FILE=$TOPOLOGY_FILE"
echo "[A] SCENARIO_ID=$SCENARIO_ID"
echo "[A] UCS_GAZEBO_BACKEND=${UCS_GAZEBO_BACKEND:-host}"
echo "[A] UCS_GAZEBO_IMAGE=${UCS_GAZEBO_IMAGE:-}"
echo "[A] PX4_DIR=$PX4_DIR"
echo "[A] WORLD_SDF=$WORLD_SDF"
echo "[A] GZ_PARTITION=$GZ_PARTITION"
echo "[A] GZ_IP=$GZ_IP"
echo "[A] GZ_SIM_SYSTEM_PLUGIN_PATH=${GZ_SIM_SYSTEM_PLUGIN_PATH:-}"
echo "[A] GZ_SIM_RESOURCE_PATH=${GZ_SIM_RESOURCE_PATH:-}"

if [[ "${UCS_GZ_GUI:-0}" -eq 1 ]]; then
  echo "[A] Starting gz sim with GUI: gz sim -r $WORLD_SDF"
  set +e
  gz sim -r "$WORLD_SDF"
  rc=$?
  set -e
else
  GAZEBO_DOCKER_GPU_ENABLED=0
  case "${UCS_GAZEBO_DOCKER_GPU:-0}" in
    1|true|True|TRUE|yes|Yes|YES|on|On|ON)
      GAZEBO_DOCKER_GPU_ENABLED=1
      ;;
  esac

  HEADLESS_SOFTWARE_RENDER=1
  case "${UCS_GAZEBO_DOCKER_SOFTWARE_RENDER:-auto}" in
    auto|"")
      if [[ "${UCS_GAZEBO_BACKEND:-host}" == "docker" && "$GAZEBO_DOCKER_GPU_ENABLED" -eq 1 ]]; then
        HEADLESS_SOFTWARE_RENDER=0
      else
        HEADLESS_SOFTWARE_RENDER=1
      fi
      ;;
    0|false|False|FALSE|no|No|NO|off|Off|OFF)
      HEADLESS_SOFTWARE_RENDER=0
      ;;
    1|true|True|TRUE|yes|Yes|YES|on|On|ON)
      HEADLESS_SOFTWARE_RENDER=1
      ;;
    *)
      echo "[A][ERR] unsupported UCS_GAZEBO_DOCKER_SOFTWARE_RENDER=${UCS_GAZEBO_DOCKER_SOFTWARE_RENDER}" >&2
      exit 1
      ;;
  esac

  if [[ "$HEADLESS_SOFTWARE_RENDER" -eq 1 ]]; then
    export LIBGL_ALWAYS_SOFTWARE="${LIBGL_ALWAYS_SOFTWARE:-1}"
    export MESA_LOADER_DRIVER_OVERRIDE="${MESA_LOADER_DRIVER_OVERRIDE:-llvmpipe}"
    export GALLIUM_DRIVER="${GALLIUM_DRIVER:-llvmpipe}"
  else
    unset LIBGL_ALWAYS_SOFTWARE MESA_LOADER_DRIVER_OVERRIDE GALLIUM_DRIVER || true
  fi

  if [[ -n "${UCS_GAZEBO_RENDER_ENGINE:-}" ]]; then
    HEADLESS_RENDER_ENGINE="$UCS_GAZEBO_RENDER_ENGINE"
  elif [[ "${UCS_GAZEBO_BACKEND:-host}" == "docker" ]]; then
    HEADLESS_RENDER_ENGINE="ogre2"
  else
    HEADLESS_RENDER_ENGINE="ogre"
  fi
  HEADLESS_CONFIG_DIR="${PID_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/ucs-mesh}"
  HEADLESS_SERVER_CONFIG="${HEADLESS_CONFIG_DIR}/gz-server-headless-${HEADLESS_RENDER_ENGINE}.config"
  BASE_SERVER_CONFIG="${PX4_GZ_SERVER_CONFIG:-${GZ_SIM_SERVER_CONFIG_PATH:-$PX4_DIR/Tools/simulation/gz/server.config}}"
  [[ -f "$BASE_SERVER_CONFIG" ]] || BASE_SERVER_CONFIG="$PX4_DIR/Tools/simulation/gz/server.config"
  mkdir -p "$HEADLESS_CONFIG_DIR"
  DISABLE_GST_CAMERA_SYSTEM=0
  case "${UCS_GAZEBO_DISABLE_GST_CAMERA_SYSTEM:-auto}" in
    auto|"")
      [[ "${UCS_GAZEBO_BACKEND:-host}" == "docker" ]] && DISABLE_GST_CAMERA_SYSTEM=1
      ;;
    1|true|True|TRUE|yes|Yes|YES|on|On|ON)
      DISABLE_GST_CAMERA_SYSTEM=1
      ;;
    0|false|False|FALSE|no|No|NO|off|Off|OFF)
      ;;
    *)
      echo "[A][ERR] unsupported UCS_GAZEBO_DISABLE_GST_CAMERA_SYSTEM=${UCS_GAZEBO_DISABLE_GST_CAMERA_SYSTEM}" >&2
      exit 1
      ;;
  esac
  DISABLE_OPTICAL_FLOW_SYSTEM=0
  case "${UCS_GAZEBO_DISABLE_OPTICAL_FLOW_SYSTEM:-auto}" in
    auto|"")
      [[ "${UCS_GAZEBO_BACKEND:-host}" == "docker" ]] && DISABLE_OPTICAL_FLOW_SYSTEM=1
      ;;
    1|true|True|TRUE|yes|Yes|YES|on|On|ON)
      DISABLE_OPTICAL_FLOW_SYSTEM=1
      ;;
    0|false|False|FALSE|no|No|NO|off|Off|OFF)
      ;;
    *)
      echo "[A][ERR] unsupported UCS_GAZEBO_DISABLE_OPTICAL_FLOW_SYSTEM=${UCS_GAZEBO_DISABLE_OPTICAL_FLOW_SYSTEM}" >&2
      exit 1
      ;;
  esac
  "$PYTHON_BIN" - "$BASE_SERVER_CONFIG" "$HEADLESS_SERVER_CONFIG" "$HEADLESS_RENDER_ENGINE" "$DISABLE_GST_CAMERA_SYSTEM" "$DISABLE_OPTICAL_FLOW_SYSTEM" <<'PY'
import sys
import xml.etree.ElementTree as ET

src, dst, render_engine_value = sys.argv[1], sys.argv[2], sys.argv[3]
disable_gst_camera = sys.argv[4] == "1"
disable_optical_flow = sys.argv[5] == "1"
tree = ET.parse(src)
root = tree.getroot()
changed = False
for parent in root.findall(".//plugins"):
    for plugin in list(parent.findall("plugin")):
        filename = plugin.get("filename") or ""
        if disable_gst_camera and filename == "libGstCameraSystem.so":
            parent.remove(plugin)
            continue
        if disable_optical_flow and filename == "libOpticalFlowSystem.so":
            parent.remove(plugin)
            continue
for plugin in root.findall(".//plugin"):
    if plugin.get("filename") != "gz-sim-sensors-system":
        continue
    render_engine = plugin.find("render_engine")
    if render_engine is None:
        render_engine = ET.SubElement(plugin, "render_engine")
    render_engine.text = render_engine_value
    changed = True
if not changed:
    raise SystemExit(f"no gz-sim-sensors-system plugin found in {src}")
ET.indent(tree, space="  ")
tree.write(dst, encoding="unicode", xml_declaration=False)
with open(dst, "a", encoding="utf-8") as f:
    f.write("\n")
PY
  export GZ_SIM_SERVER_CONFIG_PATH="$HEADLESS_SERVER_CONFIG"
  echo "[A] PX4 custom world plugins: GstCameraSystem=$([[ "$DISABLE_GST_CAMERA_SYSTEM" == "1" ]] && echo disabled || echo enabled) OpticalFlowSystem=$([[ "$DISABLE_OPTICAL_FLOW_SYSTEM" == "1" ]] && echo disabled || echo enabled)"
  UCS_GAZEBO_RESOURCE_PATH_PREFIX=""
  CAMERA_PROFILE="${UCS_GAZEBO_CAMERA_PROFILE:-}"
  CAMERA_WIDTH="${UCS_GAZEBO_CAMERA_WIDTH:-}"
  CAMERA_HEIGHT="${UCS_GAZEBO_CAMERA_HEIGHT:-}"
  CAMERA_UPDATE_RATE="${UCS_GAZEBO_CAMERA_UPDATE_RATE:-}"
  CAMERA_VISUALIZE="${UCS_GAZEBO_CAMERA_VISUALIZE:-}"
  camera_overlay_requested=0
  case "$CAMERA_PROFILE" in
    ""|0|false|False|FALSE|no|No|NO|off|Off|OFF)
      ;;
    lite|low|lowres|headless)
      CAMERA_WIDTH="${CAMERA_WIDTH:-640}"
      CAMERA_HEIGHT="${CAMERA_HEIGHT:-360}"
      CAMERA_UPDATE_RATE="${CAMERA_UPDATE_RATE:-10}"
      CAMERA_VISUALIZE="${CAMERA_VISUALIZE:-false}"
      camera_overlay_requested=1
      ;;
    720p)
      CAMERA_WIDTH="${CAMERA_WIDTH:-1280}"
      CAMERA_HEIGHT="${CAMERA_HEIGHT:-720}"
      CAMERA_UPDATE_RATE="${CAMERA_UPDATE_RATE:-30}"
      CAMERA_VISUALIZE="${CAMERA_VISUALIZE:-false}"
      camera_overlay_requested=1
      ;;
    1080p)
      CAMERA_WIDTH="${CAMERA_WIDTH:-1920}"
      CAMERA_HEIGHT="${CAMERA_HEIGHT:-1080}"
      CAMERA_UPDATE_RATE="${CAMERA_UPDATE_RATE:-30}"
      CAMERA_VISUALIZE="${CAMERA_VISUALIZE:-false}"
      camera_overlay_requested=1
      ;;
    custom)
      camera_overlay_requested=1
      ;;
    *)
      echo "[A][ERR] unsupported UCS_GAZEBO_CAMERA_PROFILE=${CAMERA_PROFILE}" >&2
      echo "[A][ERR] expected: lite, 720p, 1080p, custom, or off" >&2
      exit 1
      ;;
  esac
  if [[ -n "$CAMERA_WIDTH$CAMERA_HEIGHT$CAMERA_UPDATE_RATE$CAMERA_VISUALIZE" ]]; then
    camera_overlay_requested=1
  fi

  if [[ "$camera_overlay_requested" -eq 1 ]]; then
    GIMBAL_SRC="${PX4_DIR}/Tools/simulation/gz/models/gimbal"
    GIMBAL_OVERLAY_ROOT="${HEADLESS_CONFIG_DIR}/model-overrides"
    GIMBAL_OVERLAY="${GIMBAL_OVERLAY_ROOT}/gimbal"
    [[ -d "$GIMBAL_SRC" ]] || { echo "[A][ERR] gimbal model not found: $GIMBAL_SRC" >&2; exit 1; }
    rm -rf "$GIMBAL_OVERLAY"
    mkdir -p "$GIMBAL_OVERLAY"
    cp -R "$GIMBAL_SRC/." "$GIMBAL_OVERLAY/"
    "$PYTHON_BIN" - "$GIMBAL_OVERLAY/model.sdf" "$CAMERA_WIDTH" "$CAMERA_HEIGHT" "$CAMERA_UPDATE_RATE" "$CAMERA_VISUALIZE" <<'PY'
import sys
import xml.etree.ElementTree as ET

path, width, height, update_rate, visualize = sys.argv[1:]
tree = ET.parse(path)
root = tree.getroot()

camera_sensor = None
for sensor in root.findall(".//sensor"):
    if sensor.get("name") == "camera":
        camera_sensor = sensor
        break
if camera_sensor is None:
    raise SystemExit(f"camera sensor not found in {path}")

camera = camera_sensor.find("camera")
if camera is None:
    raise SystemExit(f"camera element not found in {path}")
image = camera.find("image")
if image is None:
    image = ET.SubElement(camera, "image")

def set_child(parent, tag, value):
    if not value:
        return
    child = parent.find(tag)
    if child is None:
        child = ET.SubElement(parent, tag)
    child.text = str(value)

set_child(image, "width", width)
set_child(image, "height", height)
set_child(camera_sensor, "update_rate", update_rate)
set_child(camera_sensor, "visualize", visualize)

ET.indent(tree, space="  ")
tree.write(path, encoding="unicode", xml_declaration=True)
with open(path, "a", encoding="utf-8") as f:
    f.write("\n")
PY
    UCS_GAZEBO_RESOURCE_PATH_PREFIX="$GIMBAL_OVERLAY_ROOT"
    if [[ "${UCS_GAZEBO_BACKEND:-host}" == "host" ]]; then
      export GZ_SIM_RESOURCE_PATH="${UCS_GAZEBO_RESOURCE_PATH_PREFIX}${GZ_SIM_RESOURCE_PATH:+:${GZ_SIM_RESOURCE_PATH}}"
    fi
    echo "[A] Camera model overlay: ${GIMBAL_OVERLAY}"
    echo "[A] Camera override: width=${CAMERA_WIDTH:-keep} height=${CAMERA_HEIGHT:-keep} update_rate=${CAMERA_UPDATE_RATE:-keep} visualize=${CAMERA_VISUALIZE:-keep}"
  fi

  if [[ "$HEADLESS_SOFTWARE_RENDER" -eq 1 ]]; then
    echo "[A] Headless software rendering: LIBGL_ALWAYS_SOFTWARE=$LIBGL_ALWAYS_SOFTWARE MESA_LOADER_DRIVER_OVERRIDE=$MESA_LOADER_DRIVER_OVERRIDE GALLIUM_DRIVER=$GALLIUM_DRIVER"
    if [[ "${UCS_GAZEBO_BACKEND:-host}" == "docker" && "$camera_overlay_requested" -eq 0 ]]; then
      echo "[A][WARN] Docker software rendering with default 6x 1280x720 cameras is usually too slow."
      echo "[A][WARN] Use UCS_GAZEBO_DOCKER_GPU=1, or UCS_GAZEBO_CAMERA_PROFILE=lite for CPU/headless runs."
    fi
  else
    echo "[A] Headless native/GPU rendering: software rendering disabled (docker_gpu=${GAZEBO_DOCKER_GPU_ENABLED})"
  fi
  echo "[A] Headless server config: $GZ_SIM_SERVER_CONFIG_PATH (base: $BASE_SERVER_CONFIG, sensors render_engine=$HEADLESS_RENDER_ENGINE)"
  if [[ "${UCS_GAZEBO_BACKEND:-host}" == "docker" ]]; then
    docker_mount_args=()
    docker_mount_targets=":"
    add_docker_mount() {
      local requested="$1"
      local mode="$2"
      local src dst
      [[ -e "$requested" ]] || return 0
      src="$("$PYTHON_BIN" -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$requested")"
      dst="$("$PYTHON_BIN" -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$requested")"
      case "$docker_mount_targets" in
        *:"$dst":*) return 0 ;;
      esac
      docker_mount_targets="${docker_mount_targets}${dst}:"
      docker_mount_args+=(-v "${src}:${dst}:${mode}")
    }

    add_docker_mount "$PX4_DIR" ro
    add_docker_mount "$MESH_DIR" ro
    add_docker_mount "$(dirname -- "$WORLD_SDF")" ro
    add_docker_mount "$HEADLESS_CONFIG_DIR" rw

    docker_gpu_args=()
    docker_gpu_env_args=()
    docker_gpu_mount_args=()
    if [[ "$GAZEBO_DOCKER_GPU_ENABLED" -eq 1 ]]; then
      mapfile -t docker_gpu_args < <(ucs_docker_gpu_args "${NVIDIA_DRIVER_CAPABILITIES:-graphics,compute,utility,display,video}")
      docker_gpu_env_args+=(
        -e __GLX_VENDOR_LIBRARY_NAME="${__GLX_VENDOR_LIBRARY_NAME:-nvidia}"
      )
      HOST_NVIDIA_EGL_VENDOR_FILE="${UCS_GAZEBO_DOCKER_EGL_VENDOR_FILE:-/usr/share/glvnd/egl_vendor.d/10_nvidia.json}"
      CONTAINER_NVIDIA_EGL_VENDOR_FILE="/usr/share/glvnd/egl_vendor.d/10_nvidia.json"
      if [[ -f "$HOST_NVIDIA_EGL_VENDOR_FILE" ]]; then
        docker_gpu_mount_args+=(-v "${HOST_NVIDIA_EGL_VENDOR_FILE}:${CONTAINER_NVIDIA_EGL_VENDOR_FILE}:ro")
        docker_gpu_env_args+=(
          -e __EGL_VENDOR_LIBRARY_FILENAMES="${__EGL_VENDOR_LIBRARY_FILENAMES:-$CONTAINER_NVIDIA_EGL_VENDOR_FILE}"
          -e GBM_BACKEND="${GBM_BACKEND:-nvidia-drm}"
        )
        echo "[A] Docker NVIDIA EGL vendor: ${HOST_NVIDIA_EGL_VENDOR_FILE} -> ${CONTAINER_NVIDIA_EGL_VENDOR_FILE}"
      else
        echo "[A][WARN] NVIDIA EGL vendor file not found: $HOST_NVIDIA_EGL_VENDOR_FILE"
        echo "[A][WARN] Docker headless EGL may fall back to Mesa/software rendering."
      fi
    fi

    docker_render_env_args=(-e UCS_GAZEBO_SOFTWARE_RENDER="$HEADLESS_SOFTWARE_RENDER")
    if [[ "$HEADLESS_SOFTWARE_RENDER" -eq 1 ]]; then
      docker_render_env_args+=(
        -e LIBGL_ALWAYS_SOFTWARE="$LIBGL_ALWAYS_SOFTWARE"
        -e MESA_LOADER_DRIVER_OVERRIDE="$MESA_LOADER_DRIVER_OVERRIDE"
        -e GALLIUM_DRIVER="$GALLIUM_DRIVER"
      )
    fi

    docker_extra_args=()
    if [[ -n "${UCS_GAZEBO_DOCKER_ARGS:-}" ]]; then
      # shellcheck disable=SC2206
      docker_extra_args=(${UCS_GAZEBO_DOCKER_ARGS})
    fi

    docker_host_lib_args=()
    docker_host_lib_env=()
    case "${UCS_GAZEBO_DOCKER_HOST_LIBS:-auto}" in
      0|false|False|FALSE|no|No|NO|off|Off|OFF)
        ;;
      auto)
        if [[ "$DISABLE_GST_CAMERA_SYSTEM" -eq 1 && "$DISABLE_OPTICAL_FLOW_SYSTEM" -eq 1 ]]; then
          echo "[A] Docker host library bridge skipped: PX4 GstCamera/OpticalFlow plugins disabled"
        elif [[ -e /lib/x86_64-linux-gnu/libopencv_imgproc.so.406 || -e /usr/lib/x86_64-linux-gnu/libopencv_imgproc.so.406 ]]; then
          [[ -d /lib/x86_64-linux-gnu ]] && docker_host_lib_args+=(-v /lib/x86_64-linux-gnu:/ucs-host-libs/lib/x86_64-linux-gnu:ro)
          [[ -d /usr/lib/x86_64-linux-gnu ]] && docker_host_lib_args+=(-v /usr/lib/x86_64-linux-gnu:/ucs-host-libs/usr/lib/x86_64-linux-gnu:ro)
          docker_host_lib_env+=(
            -e LD_LIBRARY_PATH="/ucs-host-libs/lib/x86_64-linux-gnu:/ucs-host-libs/usr/lib/x86_64-linux-gnu"
          )
          if [[ -d /usr/lib/x86_64-linux-gnu/gstreamer-1.0 ]]; then
            docker_host_lib_env+=(-e GST_PLUGIN_PATH="/ucs-host-libs/usr/lib/x86_64-linux-gnu/gstreamer-1.0")
          fi
          echo "[A] Docker host library bridge enabled: /ucs-host-libs"
        fi
        ;;
      1|true|True|TRUE|yes|Yes|YES|on|On|ON)
        [[ -d /lib/x86_64-linux-gnu ]] && docker_host_lib_args+=(-v /lib/x86_64-linux-gnu:/ucs-host-libs/lib/x86_64-linux-gnu:ro)
        [[ -d /usr/lib/x86_64-linux-gnu ]] && docker_host_lib_args+=(-v /usr/lib/x86_64-linux-gnu:/ucs-host-libs/usr/lib/x86_64-linux-gnu:ro)
        docker_host_lib_env+=(
          -e LD_LIBRARY_PATH="/ucs-host-libs/lib/x86_64-linux-gnu:/ucs-host-libs/usr/lib/x86_64-linux-gnu"
        )
        if [[ -d /usr/lib/x86_64-linux-gnu/gstreamer-1.0 ]]; then
          docker_host_lib_env+=(-e GST_PLUGIN_PATH="/ucs-host-libs/usr/lib/x86_64-linux-gnu/gstreamer-1.0")
        fi
        echo "[A] Docker host library bridge forced: /ucs-host-libs"
        ;;
      *)
        echo "[A][ERR] unsupported UCS_GAZEBO_DOCKER_HOST_LIBS=${UCS_GAZEBO_DOCKER_HOST_LIBS}" >&2
        exit 1
        ;;
    esac

    echo "[A] Starting gz sim HEADLESS in Docker: image=${UCS_GAZEBO_IMAGE} container=${WORLD_DOCKER_CONTAINER}"
    echo "[A] Docker network=host GZ_PARTITION=$GZ_PARTITION GZ_IP=$GZ_IP"
    set +e
    docker run --rm \
      --name "$WORLD_DOCKER_CONTAINER" \
      --entrypoint "${MESH_DIR}/deploy/docker/gazebo-runtime/ucs-gazebo-headless" \
      --network host \
      "${docker_gpu_args[@]}" \
      "${docker_gpu_env_args[@]}" \
      "${docker_extra_args[@]}" \
      "${docker_mount_args[@]}" \
      "${docker_gpu_mount_args[@]}" \
      "${docker_host_lib_args[@]}" \
      -e PX4_DIR="$PX4_DIR" \
      -e GZ_ENV_SH="$GZ_ENV_SH" \
      -e WORLD_SDF="$WORLD_SDF" \
      -e GZ_PARTITION="$GZ_PARTITION" \
      -e GZ_IP="$GZ_IP" \
      -e GZ_SIM_SERVER_CONFIG_PATH="$GZ_SIM_SERVER_CONFIG_PATH" \
      -e UCS_GAZEBO_RESOURCE_PATH_PREFIX="$UCS_GAZEBO_RESOURCE_PATH_PREFIX" \
      -e GZ_RENDER_ENGINE="$HEADLESS_RENDER_ENGINE" \
      "${docker_render_env_args[@]}" \
      "${docker_host_lib_env[@]}" \
      "$UCS_GAZEBO_IMAGE"
    rc=$?
    set -e
  else
    echo "[A] Starting gz sim HEADLESS (server-only): setsid gz sim -s -r --headless-rendering --render-engine-server $HEADLESS_RENDER_ENGINE $WORLD_SDF"
    set +e
    setsid gz sim -s -r --headless-rendering --render-engine-server "$HEADLESS_RENDER_ENGINE" "$WORLD_SDF" &
    gz_pid=$!
    if [[ -n "${PID_DIR:-}" ]]; then
      printf '%s\n' "$gz_pid" > "${PID_DIR}/world-A.pid"
    fi
    echo "[A] gz sim pid=$gz_pid"
    wait "$gz_pid"
    rc=$?
    set -e
  fi
fi
echo "[A][ERR] gz sim exited rc=$rc at $(date -Is)"
exit "$rc"
EOF2
chmod +x "$A_SH"

cat >"$B_SH" <<'EOF2'
#!/usr/bin/env bash
set -Eeuo pipefail

HOST_DOCKER0_IP="$(ip -4 -o addr show docker0 | awk '{print $4}' | cut -d/ -f1)"
export GZ_PARTITION="$GZ_PARTITION_NAME"
export GZ_IP="$HOST_DOCKER0_IP"

echo "[B] Ready."
echo "[B] TOPOLOGY_FILE=$TOPOLOGY_FILE"
echo "[B] SCENARIO_ID=$SCENARIO_ID"
echo "[B] GZ_PARTITION=$GZ_PARTITION"
echo "[B] GZ_IP=$GZ_IP"
echo

echo "[B] Typical checks AFTER world is up:"
echo "  gz model --list"
echo "  gz topic -e -n 1 -t /world/${PX4_GZ_WORLD_NAME}/stats"
echo "  gz topic -e -n 1 -t /clock"
echo "  ./fleet/uav_profile.sh --topology \"$TOPOLOGY_FILE\" --idx 1"
echo "  ./fleet/uav_profile.sh --topology \"$TOPOLOGY_FILE\" --idx 2"
echo "  ./fleet/uav_profile.sh --topology \"$TOPOLOGY_FILE\" --idx 3"
echo "  ./fleet/uav_profile.sh --topology \"$TOPOLOGY_FILE\" --idx 4"
EOF2
chmod +x "$B_SH"

WORLD_A_PIDFILE=""
WORLD_B_PIDFILE=""
if [[ -n "$PID_DIR" ]]; then
  WORLD_A_PIDFILE="${PID_DIR}/world-A.pid"
  WORLD_B_PIDFILE="${PID_DIR}/world-B.pid"
fi

WORLD_A_LOGFILE=""
WORLD_B_LOGFILE=""
if [[ -n "$PID_DIR" ]]; then
  WORLD_A_LOGFILE="${PID_DIR}/world-A.log"
  WORLD_B_LOGFILE="${PID_DIR}/world-B.log"
fi

if [[ "$NO_TERMINAL" -eq 1 ]]; then
  start_background "mesh-world-A" "$A_SH" "$WORLD_A_PIDFILE" "$WORLD_A_LOGFILE"
else
  open_terminal "mesh-world-A" "$A_SH" "$WORLD_A_PIDFILE"
fi
sleep 0.6

if [[ "$LAUNCH_VERIFY" -eq 1 ]]; then
  if [[ "$NO_TERMINAL" -eq 1 ]]; then
    start_background "mesh-world-B" "$B_SH" "$WORLD_B_PIDFILE" "$WORLD_B_LOGFILE"
  else
    open_terminal "mesh-world-B" "$B_SH" "$WORLD_B_PIDFILE"
  fi
fi

echo "[OK] Launched helper terminal(s)."
echo "     A: mesh-world-A"
if [[ "$LAUNCH_VERIFY" -eq 1 ]]; then
  echo "     B: mesh-world-B"
fi
echo "     Helper scripts: $CACHE_DIR"
echo "     Topology file: $TOPOLOGY_FILE"
echo "     Scenario: $SCENARIO_ID"
echo "     World source: $WORLD_SDF"
if [[ -n "$PID_DIR" ]]; then
  echo "     PID_DIR: $PID_DIR"
fi
