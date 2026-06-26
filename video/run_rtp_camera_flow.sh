#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MESH_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${MESH_DIR}/fleet/env_defaults.sh"
DEFAULT_TOPOLOGY="${MESH_DIR}/topology/wifi_adhoc_matrix_2x3_6uav.json"
BRIDGE_PY="${MESH_DIR}/video/rtp_camera_bridge.py"

TOPOLOGY_FILE="${TOPOLOGY_FILE:-$DEFAULT_TOPOLOGY}"
SELECT_UAV=""
SELECT_IDX=""
ALL_STREAMS=0
DRY_RUN=0
DURATION_SEC="${DURATION_SEC:-0}"
BITRATE_KBPS="${BITRATE_KBPS:-}"
FPS="${FPS:-}"
VIDEO_ENCODER="${VIDEO_ENCODER:-auto}"
REPORT_SEC="${REPORT_SEC:-1}"
DST_IP_OVERRIDE=""
PORT_OVERRIDE=""
PRINT_PIPELINE=0
FLOW_KEYS=()
GZ_HELPER_BACKEND="${UCS_GZ_HELPER_BACKEND:-auto}"
GZ_HELPER_IMAGE="${UCS_GZ_HELPER_IMAGE:-$UCS_GAZEBO_IMAGE}"
GZ_HELPER_DOCKER_GPU="${UCS_GZ_HELPER_DOCKER_GPU:-0}"

usage() {
  cat <<EOF
Usage: $(basename "$0") (--uav uavNN | --idx N | --all) [options]

Streams real Gazebo camera frames as RTP/H.264 from the selected UAV network
namespace to the GS experiment IP. The sender is entered with nsenter so the
UDP source address is the UAV eth1 address and packets traverse BMv2/ns-3.
Run `sudo -v` first if your user cannot enter container network namespaces
without sudo.

Options:
  --topology FILE        Topology JSON. Default: ${DEFAULT_TOPOLOGY}
  --uav uavNN           Select one UAV by id/name.
  --idx N               Select one UAV by topology idx.
  --all                 Start one stream for every UAV.
  --duration-sec N      Stop after N seconds. Default: 0, run until Ctrl+C.
  --flow KEY            Business flow key under globals.business_flows. May be
                        repeated. Default: video. Example: --flow video_main.
  --bitrate-kbps N      H.264 target bitrate. Default: selected flow default_bitrate_kbps.
  --fps N               Stream frame rate. Default: selected flow default_fps.
  --encoder NAME        H.264 encoder: auto, hard, nvh264enc,
                        nvautogpuh264enc, nvcudah264enc, va, vaapi, v4l2,
                        openh264enc, x264. Default: ${VIDEO_ENCODER}.
  --dst-ip IP           Override GS destination IP.
  --port N              Override UDP port. Only valid for one selected UAV.
  --print-pipeline      Print the GStreamer pipeline used by each bridge.
  --dry-run             Resolve and print commands without starting streams.
  --help                Show this help.

Environment:
  UCS_GZ_HELPER_BACKEND=auto|host|docker  Default: ${GZ_HELPER_BACKEND}
  UCS_GZ_HELPER_IMAGE=IMAGE               Default: ${GZ_HELPER_IMAGE}
  UCS_GZ_HELPER_DOCKER_GPU=0|1            Default: ${GZ_HELPER_DOCKER_GPU}

Viewer example for uav04:
  gst-launch-1.0 udpsrc address=10.10.0.254 port=5604 \\
    caps="application/x-rtp,media=video,clock-rate=90000,encoding-name=H264,payload=96" \\
    ! rtph264depay ! avdec_h264 ! videoconvert ! autovideosink sync=false
EOF
}

die() {
  echo "[rtp-flow][ERR] $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --topology)
      [[ $# -ge 2 ]] || die "--topology requires a path"
      TOPOLOGY_FILE="$2"
      shift 2
      ;;
    --uav)
      [[ $# -ge 2 ]] || die "--uav requires a value"
      SELECT_UAV="$2"
      shift 2
      ;;
    --idx)
      [[ $# -ge 2 ]] || die "--idx requires a value"
      SELECT_IDX="$2"
      shift 2
      ;;
    --all)
      ALL_STREAMS=1
      shift
      ;;
    --duration-sec)
      [[ $# -ge 2 ]] || die "--duration-sec requires a value"
      DURATION_SEC="$2"
      shift 2
      ;;
    --flow|--stream)
      [[ $# -ge 2 ]] || die "--flow requires a value"
      FLOW_KEYS+=("$2")
      shift 2
      ;;
    --bitrate-kbps)
      [[ $# -ge 2 ]] || die "--bitrate-kbps requires a value"
      BITRATE_KBPS="$2"
      shift 2
      ;;
    --fps)
      [[ $# -ge 2 ]] || die "--fps requires a value"
      FPS="$2"
      shift 2
      ;;
    --encoder|--video-encoder)
      [[ $# -ge 2 ]] || die "--encoder requires a value"
      VIDEO_ENCODER="$2"
      shift 2
      ;;
    --dst-ip)
      [[ $# -ge 2 ]] || die "--dst-ip requires a value"
      DST_IP_OVERRIDE="$2"
      shift 2
      ;;
    --port)
      [[ $# -ge 2 ]] || die "--port requires a value"
      PORT_OVERRIDE="$2"
      shift 2
      ;;
    --print-pipeline)
      PRINT_PIPELINE=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[[ -f "$TOPOLOGY_FILE" ]] || die "topology file not found: $TOPOLOGY_FILE"
[[ -f "$BRIDGE_PY" ]] || die "bridge script not found: $BRIDGE_PY"

selection_count=0
[[ -n "$SELECT_UAV" ]] && selection_count=$((selection_count + 1))
[[ -n "$SELECT_IDX" ]] && selection_count=$((selection_count + 1))
[[ "$ALL_STREAMS" -eq 1 ]] && selection_count=$((selection_count + 1))
[[ "$selection_count" -eq 1 ]] || die "select exactly one of --uav, --idx, or --all"
if [[ -n "$PORT_OVERRIDE" && "$ALL_STREAMS" -eq 1 ]]; then
  die "--port can only be used with a single selected UAV"
fi
if [[ -n "$PORT_OVERRIDE" && "${#FLOW_KEYS[@]}" -gt 1 ]]; then
  die "--port can only be used with one selected flow"
fi
need_cmd "$PYTHON_BIN"
need_cmd docker
need_cmd ip

python_has_video_deps() {
  "$PYTHON_BIN" - <<'PY' >/dev/null 2>&1
import gi
import gz.transport13
import gz.msgs10
gi.require_version("Gst", "1.0")
from gi.repository import Gst
PY
}

resolve_gz_helper_backend() {
  case "$GZ_HELPER_BACKEND" in
    host)
      python_has_video_deps || die "UCS_GZ_HELPER_BACKEND=host but $PYTHON_BIN cannot import gi/Gst and gz.transport13/gz.msgs10"
      need_cmd nsenter
      need_cmd sudo
      printf '%s\n' host
      ;;
    docker)
      docker image inspect "$GZ_HELPER_IMAGE" >/dev/null 2>&1 || die "helper image not found: $GZ_HELPER_IMAGE"
      printf '%s\n' docker
      ;;
    auto)
      if python_has_video_deps && command -v nsenter >/dev/null 2>&1; then
        need_cmd sudo
        printf '%s\n' host
      else
        docker image inspect "$GZ_HELPER_IMAGE" >/dev/null 2>&1 || die "host Gazebo/GStreamer Python deps unavailable and helper image not found: $GZ_HELPER_IMAGE"
        printf '%s\n' docker
      fi
      ;;
    *)
      die "unsupported UCS_GZ_HELPER_BACKEND=$GZ_HELPER_BACKEND"
      ;;
  esac
}

HELPER_BACKEND="$(resolve_gz_helper_backend)"

TOPOLOGY_FILE="$("$PYTHON_BIN" -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$TOPOLOGY_FILE")"
BRIDGE_PY="$("$PYTHON_BIN" -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$BRIDGE_PY")"
if [[ "${#FLOW_KEYS[@]}" -eq 0 ]]; then
  FLOW_KEYS=(video)
fi

STREAMS_TSV="$(mktemp /tmp/ucs_rtp_camera_streams.XXXXXX.tsv)"
cleanup_streams_file() {
  rm -f "$STREAMS_TSV"
}

"$PYTHON_BIN" - "$TOPOLOGY_FILE" "$SELECT_UAV" "$SELECT_IDX" "$ALL_STREAMS" "$DST_IP_OVERRIDE" "$PORT_OVERRIDE" "${BITRATE_KBPS:-}" "${FPS:-}" "${FLOW_KEYS[@]}" >"$STREAMS_TSV" <<'PY'
import ipaddress
import json
import re
import sys

topology_file, select_uav, select_idx, all_streams, dst_override, port_override, bitrate_override, fps_override, *flow_keys = sys.argv[1:]
with open(topology_file, "r", encoding="utf-8") as f:
    topo = json.load(f)

scenario_id = topo.get("scenario_id") or ""
globals_ = topo.get("globals", {})
world = globals_.get("px4_gz_world_name", "default")
gz_partition = globals_.get("gz_partition", "ucs")
flows = globals_.get("business_flows", {})
payload = globals_.get("payload", {})
camera_link = payload.get("camera_link", "camera_link")
camera_sensor = payload.get("camera_sensor", "camera")

if not isinstance(flows, dict):
    raise SystemExit("[rtp-flow][ERR] globals.business_flows must be an object")

def parse_resolution(value: object) -> tuple[int, int]:
    text = str(value or "")
    m = re.match(r"^\s*(\d+)\s*x\s*(\d+)\s*$", text)
    if not m:
        return (0, 0)
    return (int(m.group(1)), int(m.group(2)))

flow_cfgs = []
for flow_key in flow_keys:
    flow = flows.get(flow_key, {})
    if not isinstance(flow, dict):
        raise SystemExit(f"[rtp-flow][ERR] globals.business_flows.{flow_key} must be an object")
    if not flow.get("enabled", False):
        continue
    if flow.get("encoding", "rtp_h264") != "rtp_h264":
        continue
    if not str(flow_key).startswith("video"):
        raise SystemExit(f"[rtp-flow][ERR] flow is not a video flow: {flow_key}")
    flow_cfgs.append((flow_key, flow))

if not flow_cfgs:
    raise SystemExit(f"[rtp-flow][ERR] no enabled video flows selected: {' '.join(flow_keys)}")

instances = topo.get("instances", [])
gs_id = globals_.get("gs_id", "gs")
gs = next((i for i in instances if i.get("id") == gs_id), None)
if not gs:
    raise SystemExit(f"[rtp-flow][ERR] GS instance not found: {gs_id}")

def ip_only(value: str) -> str:
    if "/" in value:
        return str(ipaddress.ip_interface(value).ip)
    return str(ipaddress.ip_address(value))

gs_raw = gs.get("exp_ip")
if not gs_raw:
    gs_ips = globals_.get("experiment_net", {}).get("gs_ips", [])
    if not gs_ips:
        raise SystemExit("[rtp-flow][ERR] cannot resolve GS experiment IP")
    gs_raw = gs_ips[0]
dst_ip = dst_override or ip_only(str(gs_raw))

selected = []
for inst in instances:
    if inst.get("type") != "uav":
        continue
    inst_id = str(inst.get("id", inst.get("name", "")))
    idx = int(inst.get("idx", "".join(ch for ch in inst_id if ch.isdigit()) or 0))
    if all_streams == "1":
        selected.append(inst)
    elif select_uav and select_uav in {inst_id, str(inst.get("name", "")), str(inst.get("container_name", ""))}:
        selected.append(inst)
    elif select_idx and idx == int(select_idx):
        selected.append(inst)

if not selected:
    raise SystemExit("[rtp-flow][ERR] selected UAV not found")

if port_override and len(selected) * len(flow_cfgs) != 1:
    raise SystemExit("[rtp-flow][ERR] --port can only be used with one selected UAV and one selected flow")

for flow_key, flow in flow_cfgs:
    port_base = int(flow.get("port_base", 5600))
    out_width, out_height = parse_resolution(flow.get("default_resolution"))
    bitrate = int(bitrate_override or flow.get("default_bitrate_kbps", 4000))
    fps = str(fps_override or flow.get("default_fps", 30))
    label = str(flow.get("label") or flow.get("role") or flow_key)
    for inst in selected:
        inst_id = str(inst.get("id", inst.get("name", "")))
        idx = int(inst.get("idx", "".join(ch for ch in inst_id if ch.isdigit()) or 0))
        container = str(inst.get("container_name", inst_id))
        exp_if = str(inst.get("exp_if", globals_.get("exp_if", "eth1")))
        exp_ip = ip_only(str(inst.get("exp_ip")))
        model_name = str(inst.get("model_name", f"x500_gimbal_{idx:02d}"))
        topic = f"/world/{world}/model/{model_name}/link/{camera_link}/sensor/{camera_sensor}/image"
        port = int(port_override or (port_base + idx))
        print("\t".join([
            scenario_id,
            gz_partition,
            flow_key,
            label,
            str(out_width),
            str(out_height),
            str(bitrate),
            fps,
            inst_id,
            str(idx),
            container,
            exp_if,
            exp_ip,
            dst_ip,
            str(port),
            topic,
        ]))
PY

mapfile -t STREAM_LINES <"$STREAMS_TSV"
[[ "${#STREAM_LINES[@]}" -gt 0 ]] || die "no streams resolved"

RTP_CAPS='application/x-rtp,media=video,clock-rate=90000,encoding-name=H264,payload=96'
RUN_DIR="${RTP_RUN_DIR:-/tmp/ucs-mesh-${UID}/rtp-camera/$(date +%Y%m%d_%H%M%S)}"
mkdir -p "$RUN_DIR"

declare -a CHILD_PIDS=()
declare -a CHILD_LABELS=()
declare -a CHILD_CONTAINERS=()

cleanup_children() {
  local pid
  for pid in "${CHILD_PIDS[@]:-}"; do
    kill "$pid" >/dev/null 2>&1 || true
  done
  local helper_container
  for helper_container in "${CHILD_CONTAINERS[@]:-}"; do
    docker rm -f "$helper_container" >/dev/null 2>&1 || true
  done
}

cleanup_all() {
  cleanup_children
  cleanup_streams_file
}

terminate() {
  cleanup_all
  exit 0
}

trap terminate INT TERM
trap cleanup_all EXIT

preflight_runtime() {
  local failed=0
  local docker_failed=0
  local line scenario_id gz_partition flow_key flow_label out_width out_height bitrate fps uav_id idx container exp_if bind_ip dst_ip dst_port topic
  local inspect_out running pid status

  for line in "${STREAM_LINES[@]}"; do
    IFS=$'\t' read -r scenario_id gz_partition flow_key flow_label out_width out_height bitrate fps uav_id idx container exp_if bind_ip dst_ip dst_port topic <<<"$line"
    if ! inspect_out="$(docker inspect -f '{{.State.Running}}	{{.State.Pid}}	{{.State.Status}}' "$container" 2>&1)"; then
      echo "[rtp-flow][ERR] docker inspect failed for ${container}: ${inspect_out}" >&2
      docker_failed=1
      continue
    fi
    IFS=$'\t' read -r running pid status <<<"$inspect_out"
    if [[ "$running" != "true" || "$pid" == "0" ]]; then
      echo "[rtp-flow][ERR] ${uav_id}: container=${container} status=${status} running=${running} pid=${pid}" >&2
      failed=1
    fi
  done

  if [[ "$docker_failed" -ne 0 ]]; then
    echo "[rtp-flow][ERR] cannot query Docker. Check Docker daemon/socket permissions." >&2
    return 1
  fi
  if [[ "$failed" -ne 0 ]]; then
    echo "[rtp-flow][ERR] selected UAV containers are not running; start the BMv2 fleet first:" >&2
    echo "[rtp-flow][ERR]   ${MESH_DIR}/fleet/fleet_up.sh --topology ${TOPOLOGY_FILE}" >&2
    return 1
  fi
}

safe_name() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9_.-' '_'
}

docker_gpu_args() {
  case "$GZ_HELPER_DOCKER_GPU" in
    1|true|True|TRUE|yes|Yes|YES|on|On|ON)
      printf '%s\n' "--gpus" "all" "-e" "NVIDIA_DRIVER_CAPABILITIES=compute,utility,graphics,video"
      ;;
  esac
}

start_stream() {
  local line="$1"
  local scenario_id gz_partition flow_key flow_label out_width out_height bitrate fps uav_id idx container exp_if bind_ip dst_ip dst_port topic
  IFS=$'\t' read -r scenario_id gz_partition flow_key flow_label out_width out_height bitrate fps uav_id idx container exp_if bind_ip dst_ip dst_port topic <<<"$line"

  local viewer_cmd
  viewer_cmd="gst-launch-1.0 udpsrc address=${dst_ip} port=${dst_port} caps=\"${RTP_CAPS}\" ! rtph264depay ! avdec_h264 ! videoconvert ! autovideosink sync=false"

  echo "[rtp-flow] ${uav_id}/${flow_label}: ${bind_ip} -> ${dst_ip}:${dst_port}"
  echo "[rtp-flow] ${uav_id}/${flow_label}: topic=${topic}"
  echo "[rtp-flow] ${uav_id}/${flow_label}: output=${out_width}x${out_height} bitrate_kbps=${bitrate} fps=${fps}"
  echo "[rtp-flow] ${uav_id}/${flow_label}: container=${container} exp_if=${exp_if}"
  echo "[rtp-flow] ${uav_id}/${flow_label}: viewer=${viewer_cmd}"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[rtp-flow] ${uav_id}/${flow_label}: helper=${HELPER_BACKEND} (${GZ_HELPER_IMAGE}); dry-run only"
    return 0
  fi

  local container_pid
  container_pid="$(docker inspect -f '{{.State.Pid}}' "$container" 2>/dev/null || true)"
  [[ -n "$container_pid" && "$container_pid" != "0" ]] || die "container is not running: $container"

  local gz_ip
  gz_ip="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$container" 2>/dev/null || true)"
  local nsenter_cmd=()
  if [[ "$HELPER_BACKEND" == "host" ]]; then
    nsenter_cmd=(nsenter -t "$container_pid" -n)
    if ! "${nsenter_cmd[@]}" true >/dev/null 2>&1; then
      if sudo -n true >/dev/null 2>&1; then
        nsenter_cmd=(sudo -n nsenter -t "$container_pid" -n)
      elif [[ -t 0 ]]; then
        echo "[rtp-flow] sudo credential required for nsenter; requesting sudo -v ..."
        sudo -v
        nsenter_cmd=(sudo -n nsenter -t "$container_pid" -n)
      else
        die "nsenter requires sudo for ${container}; run 'sudo -v' first or launch from a terminal with sudo"
      fi
    fi
  fi
  if [[ -z "$gz_ip" ]]; then
    if [[ "$HELPER_BACKEND" == "host" ]]; then
      gz_ip="$("${nsenter_cmd[@]}" ip -4 -o addr show eth0 | awk '{print $4}' | cut -d/ -f1)"
    else
      die "cannot resolve ${container} eth0 IP for Gazebo transport"
    fi
  fi
  [[ -n "$gz_ip" ]] || die "cannot resolve ${container} eth0 IP for Gazebo transport"

  local bridge_cmd=()
  local helper_container=""
  case "$HELPER_BACKEND" in
    host)
      bridge_cmd=(
        "${nsenter_cmd[@]}"
        env "GZ_PARTITION=${gz_partition}" "GZ_IP=${gz_ip}"
        "$PYTHON_BIN" "$BRIDGE_PY"
        --source-mode camera
      )
      ;;
    docker)
      helper_container="ucs-rtp-$(safe_name "${scenario_id}-${uav_id}-${flow_key}")"
      docker rm -f "$helper_container" >/dev/null 2>&1 || true
      local gpu_args=()
      mapfile -t gpu_args < <(docker_gpu_args)
      bridge_cmd=(
        docker run --rm
        --name "$helper_container"
        --network "container:${container}"
        --user "$(id -u):$(id -g)"
        -v "${MESH_DIR}:${MESH_DIR}:ro"
        -e "GZ_PARTITION=${gz_partition}"
        -e "GZ_IP=${gz_ip}"
        "${gpu_args[@]}"
        --entrypoint python3
        "$GZ_HELPER_IMAGE"
        "$BRIDGE_PY"
        --source-mode camera
      )
      CHILD_CONTAINERS+=("$helper_container")
      ;;
  esac
  bridge_cmd+=(
    --topic "$topic"
    --dst-ip "$dst_ip"
    --dst-port "$dst_port"
    --bind-ip "$bind_ip"
    --bitrate-kbps "$bitrate"
    --fps "$fps"
    --output-width "$out_width"
    --output-height "$out_height"
    --encoder "$VIDEO_ENCODER"
    --duration-sec "$DURATION_SEC"
    --report-sec "$REPORT_SEC"
  )
  if [[ "$PRINT_PIPELINE" -eq 1 ]]; then
    bridge_cmd+=(--print-pipeline)
  fi

  echo "[rtp-flow] ${uav_id}/${flow_label}: helper=${HELPER_BACKEND} image=${GZ_HELPER_IMAGE}"
  echo "[rtp-flow] ${uav_id}/${flow_label}: container=${container} pid=${container_pid} exp_if=${exp_if} GZ_IP=${gz_ip}"
  if [[ -n "$helper_container" ]]; then
    echo "[rtp-flow] ${uav_id}/${flow_label}: helper_container=${helper_container} network=container:${container} gpu=${GZ_HELPER_DOCKER_GPU}"
  fi

  if [[ "${#STREAM_LINES[@]}" -eq 1 ]]; then
    "${bridge_cmd[@]}"
  else
    local log_file="${RUN_DIR}/${uav_id}-${flow_key}.log"
    "${bridge_cmd[@]}" >"$log_file" 2>&1 &
    local child_pid="$!"
    CHILD_PIDS+=("$child_pid")
    CHILD_LABELS+=("${uav_id}/${flow_label}")
    printf '%s\n' "$child_pid" > "${RUN_DIR}/${uav_id}-${flow_key}.pid"
    echo "[rtp-flow] ${uav_id}/${flow_label}: pid=${child_pid} log=${log_file}"
  fi
}

echo "[rtp-flow] topology=$TOPOLOGY_FILE"
echo "[rtp-flow] run_dir=$RUN_DIR"
echo "[rtp-flow] flows=${FLOW_KEYS[*]} encoder=$VIDEO_ENCODER bitrate_override=${BITRATE_KBPS:-auto} fps_override=${FPS:-auto}"
echo "[rtp-flow] helper=${HELPER_BACKEND} image=${GZ_HELPER_IMAGE} gpu=${GZ_HELPER_DOCKER_GPU}"
if [[ "$DRY_RUN" -eq 0 ]]; then
  preflight_runtime
fi
for line in "${STREAM_LINES[@]}"; do
  start_stream "$line"
done

if [[ "$DRY_RUN" -eq 1 ]]; then
  exit 0
fi

if [[ "${#CHILD_PIDS[@]}" -gt 0 ]]; then
  rc=0
  for i in "${!CHILD_PIDS[@]}"; do
    pid="${CHILD_PIDS[$i]}"
    label="${CHILD_LABELS[$i]}"
    if ! wait "$pid"; then
      echo "[rtp-flow][ERR] ${label} bridge exited non-zero" >&2
      rc=1
    fi
  done
  exit "$rc"
fi
