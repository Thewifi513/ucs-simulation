#!/usr/bin/env bash
set -u -o pipefail

# Read-only deployment preflight for Ubuntu 20 GPU servers.
# It reports readiness for the UCS BMv2 mesh stack without installing packages,
# pulling images, changing network state, or touching old deployments.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
GZ_ENV_SH_INPUT_SET="${GZ_ENV_SH+x}"
PX4_GZ_MODELS_INPUT_SET="${PX4_GZ_MODELS+x}"
PX4_GZ_WORLDS_INPUT_SET="${PX4_GZ_WORLDS+x}"
# shellcheck disable=SC1091
source "${REPO_DIR}/fleet/env_defaults.sh"
if [[ -f "${SCRIPT_DIR}/docker_images.env" ]]; then
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/docker_images.env"
fi

DEFAULT_TOPOLOGY="${REPO_DIR}/topology/wifi_adhoc_matrix_2x3_6uav.json"
TOPOLOGY_FILE="${TOPOLOGY_FILE:-$DEFAULT_TOPOLOGY}"
GZ_ENV_SH_EXPLICIT="$GZ_ENV_SH_INPUT_SET"
PX4_GZ_MODELS_EXPLICIT="$PX4_GZ_MODELS_INPUT_SET"
PX4_GZ_WORLDS_EXPLICIT="$PX4_GZ_WORLDS_INPUT_SET"

CHECK_PORTS=1
CHECK_IMAGES=1
STRICT=0

OK_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Read-only checks for deploying this UCS BMv2 mesh platform on a shared Ubuntu 20
GPU server. The script does not install packages, pull Docker images, create
interfaces, or stop existing services.

Options:
  --topology FILE     Topology JSON. Default: ${DEFAULT_TOPOLOGY}
  --px4-dir DIR       PX4-Autopilot path. Default: ${PX4_DIR}
  --ns3-dir DIR       ns-3 path. Default: ${NS3_DIR}
  --gz-env FILE       PX4 Gazebo environment file. Default: ${GZ_ENV_SH}
  --no-ports          Skip listening-port conflict checks.
  --no-images         Skip Docker image availability checks.
  --strict            Exit non-zero when warnings are present.
  --help              Show this help.

Useful overrides:
  PX4_DIR=/path/to/PX4-Autopilot
  NS3_DIR=/path/to/ns-3
  MAVSDK_SERVER_BIN=/path/to/mavsdk_server
  PYTHON_BIN=/path/to/venv/bin/python
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --topology)
      [[ $# -ge 2 ]] || { echo "[preflight][ERR] --topology requires a file" >&2; exit 2; }
      TOPOLOGY_FILE="$2"
      shift 2
      ;;
    --px4-dir)
      [[ $# -ge 2 ]] || { echo "[preflight][ERR] --px4-dir requires a directory" >&2; exit 2; }
      PX4_DIR="$2"
      [[ -z "${GZ_ENV_SH_EXPLICIT:-}" ]] && GZ_ENV_SH="$PX4_DIR/build/px4_sitl_default/rootfs/gz_env.sh"
      [[ -z "${PX4_GZ_MODELS_EXPLICIT:-}" ]] && PX4_GZ_MODELS="$PX4_DIR/Tools/simulation/gz/models"
      [[ -z "${PX4_GZ_WORLDS_EXPLICIT:-}" ]] && PX4_GZ_WORLDS="$PX4_DIR/Tools/simulation/gz/worlds"
      shift 2
      ;;
    --ns3-dir)
      [[ $# -ge 2 ]] || { echo "[preflight][ERR] --ns3-dir requires a directory" >&2; exit 2; }
      NS3_DIR="$2"
      shift 2
      ;;
    --gz-env)
      [[ $# -ge 2 ]] || { echo "[preflight][ERR] --gz-env requires a file" >&2; exit 2; }
      GZ_ENV_SH="$2"
      GZ_ENV_SH_EXPLICIT=1
      shift 2
      ;;
    --no-ports)
      CHECK_PORTS=0
      shift
      ;;
    --no-images)
      CHECK_IMAGES=0
      shift
      ;;
    --strict)
      STRICT=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[preflight][ERR] unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

section() {
  printf '\n== %s ==\n' "$*"
}

ok() {
  OK_COUNT=$((OK_COUNT + 1))
  printf '[OK]   %s\n' "$*"
}

warn() {
  WARN_COUNT=$((WARN_COUNT + 1))
  printf '[WARN] %s\n' "$*"
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  printf '[FAIL] %s\n' "$*"
}

info() {
  printf '[INFO] %s\n' "$*"
}

check_cmd() {
  local cmd="$1"
  local severity="${2:-fail}"
  local label="${3:-$cmd}"

  if command -v "$cmd" >/dev/null 2>&1; then
    ok "${label}: $(command -v "$cmd")"
  elif [[ "$severity" == "warn" ]]; then
    warn "missing optional command: ${label}"
  else
    fail "missing required command: ${label}"
  fi
}

check_file() {
  local path="$1"
  local severity="${2:-fail}"
  local label="${3:-$path}"

  if [[ -f "$path" ]]; then
    ok "${label}: ${path}"
  elif [[ "$severity" == "warn" ]]; then
    warn "missing optional file: ${label} (${path})"
  else
    fail "missing required file: ${label} (${path})"
  fi
}

check_dir() {
  local path="$1"
  local severity="${2:-fail}"
  local label="${3:-$path}"

  if [[ -d "$path" ]]; then
    ok "${label}: ${path}"
  elif [[ "$severity" == "warn" ]]; then
    warn "missing optional directory: ${label} (${path})"
  else
    fail "missing required directory: ${label} (${path})"
  fi
}

check_python_import() {
  local python_bin="$1"
  local module="$2"
  local severity="${3:-warn}"
  local label="${4:-Python module ${module}}"

  if "$python_bin" -c "import ${module}" >/dev/null 2>&1; then
    ok "${label}: import ${module}"
  elif [[ "$severity" == "fail" ]]; then
    fail "${label} not importable with ${python_bin}"
  else
    warn "${label} not importable with ${python_bin}"
  fi
}

python_import_ok() {
  local python_bin="$1"
  local module="$2"
  "$python_bin" -c "import ${module}" >/dev/null 2>&1
}

python_gst_ok() {
  local python_bin="$1"
  "$python_bin" - <<'PY' >/dev/null 2>&1
import gi
gi.require_version("Gst", "1.0")
from gi.repository import Gst
PY
}

docker_python_import_ok() {
  local image="$1"
  local module="$2"
  docker run --rm --entrypoint python3 "$image" -c "import ${module}" >/dev/null 2>&1
}

docker_python_gst_ok() {
  local image="$1"
  docker run --rm --entrypoint python3 "$image" - <<'PY' >/dev/null 2>&1
import gi
gi.require_version("Gst", "1.0")
from gi.repository import Gst
PY
}

docker_cmd_ok() {
  local image="$1"
  shift
  docker run --rm --entrypoint "$1" "$image" "${@:2}" >/dev/null 2>&1
}

docker_helper_gpu_enabled() {
  case "${UCS_GZ_HELPER_DOCKER_GPU:-0}" in
    1|true|True|TRUE|yes|Yes|YES|on|On|ON) return 0 ;;
    *) return 1 ;;
  esac
}

docker_cmd_ok_with_helper_gpu() {
  local image="$1"
  shift
  local gpu_args=()
  if docker_helper_gpu_enabled; then
    mapfile -t gpu_args < <(ucs_docker_gpu_args "compute,utility,graphics,video")
  fi
  docker run --rm "${gpu_args[@]}" --entrypoint "$1" "$image" "${@:2}" >/dev/null 2>&1
}

check_docker_image() {
  local image="$1"
  [[ -n "$image" ]] || return 0
  if docker image inspect "$image" >/dev/null 2>&1; then
    ok "Docker image available: ${image}"
  else
    warn "Docker image not available locally: ${image}"
  fi
}

port_busy() {
  local port="$1"
  local ss_out=""
  command -v ss >/dev/null 2>&1 || return 2
  if ! ss_out="$(ss -H -lntu 2>/dev/null)"; then
    return 2
  fi
  printf '%s\n' "$ss_out" | awk -v p="$port" '
    {
      local_addr = $5
      n = split(local_addr, parts, ":")
      local_port = parts[n]
      gsub(/[^0-9]/, "", local_port)
      if (local_port == p) {
        print
        found = 1
      }
    }
    END { exit found ? 0 : 1 }
  '
}

check_port() {
  local port="$1"
  local label="$2"
  local out=""

  if out="$(port_busy "$port")"; then
    warn "port ${port} is already listening (${label}): ${out}"
  else
    local rc=$?
    if [[ "$rc" -eq 1 ]]; then
      ok "port ${port} free (${label})"
    else
      warn "could not inspect port ${port} (${label}); ss may be restricted"
    fi
  fi
}

join_unique_words() {
  awk '
    {
      for (i = 1; i <= NF; i++) {
        if (!seen[$i]++) {
          out = out ? out " " $i : $i
        }
      }
    }
    END { print out }
  '
}

section "Host"
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  info "OS: ${PRETTY_NAME:-unknown}"
  if [[ "${ID:-}" == "ubuntu" && "${VERSION_ID:-}" == "20.04" ]]; then
    ok "target profile matches Ubuntu 20.04"
  else
    warn "this script is tuned for Ubuntu 20.04; detected ID=${ID:-unknown} VERSION_ID=${VERSION_ID:-unknown}"
  fi
else
  warn "/etc/os-release is not readable"
fi
info "kernel: $(uname -srmo 2>/dev/null || uname -a)"
info "repo: ${REPO_DIR}"

section "Required Host Commands"
check_cmd bash
check_cmd python3
check_cmd docker
check_cmd ip
check_cmd tc
check_cmd awk
check_cmd cut
check_cmd timeout
check_cmd sudo warn
check_cmd ss warn
check_cmd nsenter warn
check_cmd ethtool warn
check_cmd tcpdump warn
check_cmd iptables warn
check_cmd realpath warn
check_cmd setsid warn
check_cmd pgrep warn
check_cmd x-terminal-emulator warn
check_cmd gnome-terminal warn

section "Topology And Repository"
check_file "$TOPOLOGY_FILE" fail "topology"
check_file "${REPO_DIR}/fleet/fleet_up.sh" fail "fleet launcher"
check_file "${REPO_DIR}/fleet/fleet_down.sh" fail "fleet cleanup"
check_file "${REPO_DIR}/network/net_up.sh" fail "ns-3/network launcher"
check_file "${REPO_DIR}/px4_gazebo/world_up.sh" fail "Gazebo world launcher"
check_file "${REPO_DIR}/px4_gazebo/px4_up.sh" fail "PX4 launcher"
check_file "${REPO_DIR}/p4/ucs_edge_cluster_route.p4" fail "active P4 source"
check_file "${REPO_DIR}/p4/build/ucs_edge_cluster_route.json" warn "compiled BMv2 JSON"
check_file "${REPO_DIR}/p4/build/ucs_edge_cluster_route.p4info.txt" warn "compiled P4Info"
check_file "${REPO_DIR}/px4_gazebo/worlds/ucs_obstacle_field.sdf" fail "scenario world"
check_file "${REPO_DIR}/network/ns3/ucs_fleet_l2_mesh_topology.cc" fail "repo ns-3 scratch source"

SCENARIO_ID="unknown"
UAV_COUNT="6"
UAV_IDS="uav01 uav02 uav03 uav04 uav05 uav06"
VIDEO_PORTS="5601 5602 5603 5604 5605 5606"
QGC_PORTS="18570 18571 18572 18573 18574 18575"
MAVSDK_REMOTE_PORTS="14601 14602 14603 14604 14605 14606"
MAVSDK_LOCAL_PORTS="18601 18602 18603 18604 18605 18606"
P4_GRPC_PORTS="9560"
TOPOLOGY_IMAGES="${UCS_RUNTIME_IMAGE_LIST:-ucs-uav-base-gz-bmv2:20260625 ucs-gazebo-runtime:20260625 ucs-p4runtime-sh:20260625}"
NS3_SCRATCH="ucs_fleet_l2_mesh_topology"

if [[ -f "$TOPOLOGY_FILE" ]] && [[ -n "${PYTHON_BIN:-}" ]] && command -v "$PYTHON_BIN" >/dev/null 2>&1; then
  TOPOLOGY_EXPORTS="$(
    "$PYTHON_BIN" - "$TOPOLOGY_FILE" <<'PY'
import json
import shlex
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    topo = json.load(f)

globals_ = topo.get("globals", {})
instances = [i for i in topo.get("instances", []) if i.get("type") == "uav"]
business = globals_.get("business_flows", {})
control_cfg = business.get("control", {})
programmable = topo.get("programmable_net", {})
gs_edge = programmable.get("gs_edge", {})

def emit(key, value):
    print(f"{key}={shlex.quote(str(value))}")

def words(values):
    return " ".join(str(v) for v in values if str(v))

uav_ids = [inst.get("id") or inst.get("name") for inst in instances]
idxs = [int(inst.get("idx", pos + 1)) for pos, inst in enumerate(instances)]
video_ports = []
if isinstance(business, dict):
    for key in ("video", "video_main"):
        flow = business.get(key, {})
        if isinstance(flow, dict) and flow.get("enabled", False):
            base = int(flow.get("port_base", 5600 if key == "video" else 5700))
            video_ports.extend(base + idx for idx in idxs)
qgc_ports = [inst.get("qgc_port", 18570 + int(inst.get("px4_instance", pos))) for pos, inst in enumerate(instances)]
mavsdk = control_cfg.get("mavsdk", {})
remote_base = int(mavsdk.get("gs_remote_port_base", 14600))
local_base = int(mavsdk.get("uav_local_port_base", 18600))
mavsdk_remote_ports = [remote_base + idx for idx in idxs]
mavsdk_local_ports = [local_base + idx for idx in idxs]
p4_ports = []
grpc_addr = str(gs_edge.get("grpc_addr", "127.0.0.1:9560"))
if ":" in grpc_addr:
    p4_ports.append(grpc_addr.rsplit(":", 1)[1])

images = []
if gs_edge.get("runtime_image"):
    images.append(gs_edge["runtime_image"])

emit("SCENARIO_ID", topo.get("scenario_id", "unknown"))
emit("UAV_COUNT", len(instances) or 0)
emit("UAV_IDS", words(uav_ids))
emit("VIDEO_PORTS", words(video_ports))
emit("QGC_PORTS", words(qgc_ports))
emit("MAVSDK_REMOTE_PORTS", words(mavsdk_remote_ports))
emit("MAVSDK_LOCAL_PORTS", words(mavsdk_local_ports))
emit("P4_GRPC_PORTS", words(p4_ports))
emit("TOPOLOGY_IMAGES", words(dict.fromkeys(images)))
emit("NS3_SCRATCH", "ucs_fleet_l2_mesh_topology" if globals_.get("fabric_mode") == "l2_link_mesh" else "ucs_fleet_topology")
PY
  )"
  if [[ $? -eq 0 ]]; then
    eval "$TOPOLOGY_EXPORTS"
    ok "topology parsed: scenario=${SCENARIO_ID}, uavs=${UAV_COUNT} (${UAV_IDS})"
  else
    fail "topology JSON could not be parsed: ${TOPOLOGY_FILE}"
  fi
  unset TOPOLOGY_EXPORTS
fi

section "Docker"
if command -v docker >/dev/null 2>&1; then
  if docker info >/dev/null 2>&1; then
    ok "Docker daemon reachable by current user"
    info "Docker server: $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo unknown)"
  else
    fail "Docker daemon is not reachable by current user"
  fi
  if ip -4 -o addr show docker0 >/dev/null 2>&1; then
    ok "docker0 has IPv4 address"
    info "docker0: $(ip -4 -o addr show docker0 2>/dev/null | awk '{print $4}' | paste -sd, -)"
  else
    warn "docker0 IPv4 address not visible; Docker may be stopped or sandboxed"
  fi
  if [[ "$CHECK_IMAGES" -eq 1 ]]; then
    for image in $(printf '%s\n%s\n' "${UCS_RUNTIME_IMAGE_LIST:-}" "$TOPOLOGY_IMAGES" | join_unique_words); do
      check_docker_image "$image"
    done
  fi
else
  fail "Docker command not available"
fi

section "GPU"
if command -v nvidia-smi >/dev/null 2>&1; then
  if nvidia-smi -L >/dev/null 2>&1; then
    ok "NVIDIA GPU visible"
    nvidia-smi -L 2>/dev/null | sed 's/^/[INFO] /'
  else
    warn "nvidia-smi exists but no GPU is visible"
  fi
else
  warn "nvidia-smi not found; Gazebo/video may need software rendering or toolkit install"
fi
if command -v nvidia-container-cli >/dev/null 2>&1; then
  ok "NVIDIA Container Toolkit CLI present"
else
  warn "nvidia-container-cli not found; Docker GPU passthrough may be unavailable"
fi
check_file "/usr/share/glvnd/egl_vendor.d/10_nvidia.json" warn "NVIDIA EGL vendor JSON"

section "PX4 And Gazebo"
check_dir "$PX4_DIR" warn "PX4_DIR"
check_file "$GZ_ENV_SH" warn "PX4 gz_env.sh"
check_dir "$PX4_GZ_MODELS" warn "PX4 Gazebo models"
check_dir "$PX4_GZ_WORLDS" warn "PX4 Gazebo worlds"
check_cmd gz warn "Gazebo CLI"
if command -v gz >/dev/null 2>&1; then
  info "gz version: $(gz --versions 2>/dev/null | head -n 1 || echo unknown)"
fi

PYTHON_FOR_CHECK="${PYTHON_BIN:-}"
if [[ -n "$PYTHON_FOR_CHECK" && -x "$PYTHON_FOR_CHECK" ]]; then
  ok "platform Python: ${PYTHON_FOR_CHECK}"
  if "$PYTHON_FOR_CHECK" - <<'PY' >/dev/null 2>&1
import sys
from pathlib import Path

is_venv = sys.prefix != sys.base_prefix
is_conda = (Path(sys.prefix) / "conda-meta").is_dir()
raise SystemExit(0 if is_venv or is_conda else 1)
PY
  then
    ok "platform Python is an isolated environment"
  else
    warn "platform Python is not an isolated environment; create ${UCS_VENV_DIR} and set PYTHON_BIN for server migration"
  fi
else
  fail "no executable Python found for module checks"
fi

section "Gazebo Helper Runtime"
HOST_GZ_HELPER_READY=0
if [[ -n "$PYTHON_FOR_CHECK" && -x "$PYTHON_FOR_CHECK" ]] \
  && command -v gz >/dev/null 2>&1 \
  && python_import_ok "$PYTHON_FOR_CHECK" "gz.transport13" \
  && python_import_ok "$PYTHON_FOR_CHECK" "gz.msgs10" \
  && python_gst_ok "$PYTHON_FOR_CHECK"; then
  HOST_GZ_HELPER_READY=1
fi

EFFECTIVE_GZ_HELPER_BACKEND="${UCS_GZ_HELPER_BACKEND:-auto}"
case "$EFFECTIVE_GZ_HELPER_BACKEND" in
  auto)
    if [[ "$HOST_GZ_HELPER_READY" -eq 1 ]]; then
      EFFECTIVE_GZ_HELPER_BACKEND="host"
    else
      EFFECTIVE_GZ_HELPER_BACKEND="docker"
    fi
    ;;
  host|docker)
    ;;
  *)
    warn "unsupported UCS_GZ_HELPER_BACKEND=${UCS_GZ_HELPER_BACKEND}; expected auto, host, or docker"
    EFFECTIVE_GZ_HELPER_BACKEND="docker"
    ;;
esac

info "UCS_GZ_HELPER_BACKEND=${UCS_GZ_HELPER_BACKEND:-auto}; effective=${EFFECTIVE_GZ_HELPER_BACKEND}; image=${UCS_GZ_HELPER_IMAGE}"
if [[ "$EFFECTIVE_GZ_HELPER_BACKEND" == "host" ]]; then
  if [[ "$HOST_GZ_HELPER_READY" -eq 1 ]]; then
    ok "host Gazebo helper Python runtime ready"
  else
    fail "UCS_GZ_HELPER_BACKEND=host but host Python/Gazebo/GStreamer helper dependencies are incomplete"
    [[ -n "$PYTHON_FOR_CHECK" && -x "$PYTHON_FOR_CHECK" ]] && {
      check_python_import "$PYTHON_FOR_CHECK" "gz.transport13" warn "host Gazebo Python transport"
      check_python_import "$PYTHON_FOR_CHECK" "gz.msgs10" warn "host Gazebo Python messages"
      if python_gst_ok "$PYTHON_FOR_CHECK"; then
        ok "host Python GStreamer binding: gi.repository.Gst"
      else
        warn "host Python GStreamer binding not importable with ${PYTHON_FOR_CHECK}"
      fi
    }
  fi
else
  if docker image inspect "$UCS_GZ_HELPER_IMAGE" >/dev/null 2>&1; then
    ok "Gazebo helper Docker image available: ${UCS_GZ_HELPER_IMAGE}"
    if docker_python_import_ok "$UCS_GZ_HELPER_IMAGE" "gz.transport13"; then
      ok "helper image Gazebo Python transport: import gz.transport13"
    else
      fail "helper image cannot import gz.transport13: ${UCS_GZ_HELPER_IMAGE}"
    fi
    if docker_python_import_ok "$UCS_GZ_HELPER_IMAGE" "gz.msgs10"; then
      ok "helper image Gazebo Python messages: import gz.msgs10"
    else
      fail "helper image cannot import gz.msgs10: ${UCS_GZ_HELPER_IMAGE}"
    fi
    if docker_python_gst_ok "$UCS_GZ_HELPER_IMAGE"; then
      ok "helper image Python GStreamer binding: gi.repository.Gst"
    else
      fail "helper image cannot import gi.repository.Gst: ${UCS_GZ_HELPER_IMAGE}"
    fi
    if docker_cmd_ok "$UCS_GZ_HELPER_IMAGE" bash -lc "command -v gz"; then
      ok "helper image Gazebo CLI: gz"
    else
      fail "helper image missing Gazebo CLI: ${UCS_GZ_HELPER_IMAGE}"
    fi
    if docker_cmd_ok "$UCS_GZ_HELPER_IMAGE" gst-inspect-1.0 x264enc; then
      ok "helper image GStreamer software H.264 encoder: x264enc"
    else
      warn "helper image missing x264enc; install gstreamer1.0-plugins-ugly in ${UCS_GZ_HELPER_IMAGE}"
    fi
    helper_hw_encoder_found=0
    if docker_helper_gpu_enabled; then
      info "checking helper hardware encoders with Docker GPU passthrough"
    else
      info "checking helper hardware encoders without Docker GPU passthrough"
    fi
    for plugin in nvautogpuh264enc nvh264enc nvcudah264enc vah264enc vaapih264enc v4l2h264enc; do
      if docker_cmd_ok_with_helper_gpu "$UCS_GZ_HELPER_IMAGE" gst-inspect-1.0 "$plugin"; then
        ok "helper image GStreamer hardware H.264 encoder: ${plugin}"
        helper_hw_encoder_found=1
      fi
    done
    if [[ "$helper_hw_encoder_found" -eq 0 ]]; then
      warn "helper image has no visible hardware H.264 encoder; VIDEO_ENCODER=hard will fail unless NVIDIA/VAAPI plugins are present at runtime"
    fi
  else
    fail "Gazebo helper Docker image not available: ${UCS_GZ_HELPER_IMAGE}"
  fi
fi

section "ns-3"
check_dir "$NS3_DIR" warn "NS3_DIR"
check_file "${NS3_DIR}/ns3" warn "ns-3 frontend"
if [[ -f "${NS3_DIR}/scratch/${NS3_SCRATCH}.cc" ]]; then
  ok "ns-3 scratch installed: ${NS3_DIR}/scratch/${NS3_SCRATCH}.cc"
else
  warn "ns-3 scratch missing in NS3_DIR: copy ${REPO_DIR}/network/ns3/${NS3_SCRATCH}.cc to ${NS3_DIR}/scratch/"
fi
if [[ -d "${NS3_DIR}/build/scratch" ]]; then
  ok "ns-3 build/scratch exists"
else
  warn "ns-3 build/scratch missing; run ./ns3 build after installing scratch source"
fi

section "Network Privileges"
if command -v sudo >/dev/null 2>&1; then
  if sudo -n true >/dev/null 2>&1; then
    ok "passwordless sudo available for current shell"
  else
    warn "sudo exists but is not currently non-interactive; run sudo -v before fleet_up.sh"
  fi
else
  fail "sudo not available"
fi
if [[ -c /dev/net/tun ]]; then
  ok "/dev/net/tun is available"
else
  fail "/dev/net/tun is missing; ns-3 TapBridge cannot create TAP interfaces"
fi
if ip netns list >/dev/null 2>&1; then
  ok "ip netns can be queried"
else
  warn "ip netns query failed; current shell may lack permission"
fi
if [[ -r /proc/sys/net/ipv4/ip_forward ]]; then
  info "net.ipv4.ip_forward=$(cat /proc/sys/net/ipv4/ip_forward)"
fi

section "Video And Control"
check_cmd gst-launch-1.0 warn "GStreamer launcher"
check_cmd gst-inspect-1.0 warn "GStreamer plugin inspector"
if command -v gst-inspect-1.0 >/dev/null 2>&1; then
  for plugin in x264enc rtph264pay rtph264depay avdec_h264 videoconvert; do
    if gst-inspect-1.0 "$plugin" >/dev/null 2>&1; then
      ok "GStreamer plugin: ${plugin}"
    else
      warn "missing GStreamer plugin: ${plugin}"
    fi
  done
  hw_encoder_found=0
  for plugin in nvautogpuh264enc nvh264enc nvcudah264enc vah264enc vaapih264enc v4l2h264enc; do
    if gst-inspect-1.0 "$plugin" >/dev/null 2>&1; then
      ok "GStreamer hardware H.264 encoder: ${plugin}"
      hw_encoder_found=1
    fi
  done
  if [[ "$hw_encoder_found" -eq 0 ]]; then
    warn "no GStreamer hardware H.264 encoder found; RTP sender will fall back unless VIDEO_ENCODER=hard"
  fi
  hw_decoder_found=0
  for plugin in nvh264dec nvh264sldec vah264dec vaapih264dec v4l2h264dec; do
    if gst-inspect-1.0 "$plugin" >/dev/null 2>&1; then
      ok "GStreamer hardware H.264 decoder: ${plugin}"
      hw_decoder_found=1
    fi
  done
  if [[ "$hw_decoder_found" -eq 0 ]]; then
    warn "no GStreamer hardware H.264 decoder found; dashboard will fall back to avdec_h264 unless DASHBOARD_VIDEO_DECODER=hard"
  fi
fi
if [[ -n "${MAVSDK_SERVER_BIN:-}" ]]; then
  check_file "$MAVSDK_SERVER_BIN" warn "MAVSDK server binary"
elif [[ -x "${REPO_DIR}/control/mavsdk_server" ]]; then
  ok "MAVSDK server in control module: ${REPO_DIR}/control/mavsdk_server"
elif [[ -x "${REPO_DIR}/control/mavsdk_server_musl_x86_64" ]]; then
  ok "MAVSDK server in control module: ${REPO_DIR}/control/mavsdk_server_musl_x86_64"
elif command -v mavsdk_server >/dev/null 2>&1; then
  ok "MAVSDK server in PATH: $(command -v mavsdk_server)"
else
  warn "mavsdk_server not found; put it under ${REPO_DIR}/control or set MAVSDK_SERVER_BIN before enabling browser control"
fi
if [[ -n "$PYTHON_FOR_CHECK" && -x "$PYTHON_FOR_CHECK" ]]; then
  check_python_import "$PYTHON_FOR_CHECK" "mavsdk" warn "MAVSDK Python package"
  check_python_import "$PYTHON_FOR_CHECK" "websockets" warn "websockets Python package"
fi

if [[ "$CHECK_PORTS" -eq 1 ]]; then
  section "Port Conflicts"
  PORTS_TO_CHECK="$(
    printf '%s\n' \
      "8088" \
      "14550" \
      "8765 8771 8772 8773 8774 8775 8776" \
      "9001 9011 9012 9013 9014 9015 9016" \
      "50051 50101 50102 50103 50104 50105 50106" \
      "$VIDEO_PORTS" \
      "$QGC_PORTS" \
      "$MAVSDK_REMOTE_PORTS" \
      "$MAVSDK_LOCAL_PORTS" \
      "$P4_GRPC_PORTS" | join_unique_words
  )"
  for port in $PORTS_TO_CHECK; do
    case "$port" in
      8088) label="dashboard" ;;
      8765|877*) label="control relay" ;;
      9001|901*) label="control core" ;;
      50051|501*) label="MAVSDK gRPC" ;;
      560*|570*) label="RTP video" ;;
      14550|146*) label="MAVLink GS" ;;
      185*|186*) label="PX4/MAVSDK UAV side" ;;
      9560) label="GS BMv2 P4Runtime" ;;
      *) label="UCS runtime" ;;
    esac
    check_port "$port" "$label"
  done
else
  section "Port Conflicts"
  warn "port checks skipped by --no-ports"
fi

section "Summary"
info "checks: ok=${OK_COUNT} warn=${WARN_COUNT} fail=${FAIL_COUNT}"
if [[ "$FAIL_COUNT" -gt 0 ]]; then
  info "result: NOT READY for a full run; fix failed checks first"
  exit 2
fi
if [[ "$WARN_COUNT" -gt 0 ]]; then
  info "result: base host may be usable, but warnings need review before full PX4/Gazebo/video/control"
  if [[ "$STRICT" -eq 1 ]]; then
    exit 1
  fi
  exit 0
fi
info "result: ready for staged deployment checks"
exit 0
