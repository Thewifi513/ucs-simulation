#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MESH_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${MESH_DIR}/fleet/env_defaults.sh"
DEFAULT_TOPOLOGY="${MESH_DIR}/topology/wifi_adhoc_matrix_2x3_6uav.json"
SERVER_PY="${MESH_DIR}/frontend/dashboard_server.py"

TOPOLOGY_FILE="${TOPOLOGY_FILE:-$DEFAULT_TOPOLOGY}"
HOST="${HOST:-0.0.0.0}"
PORT="${PORT:-8088}"
CONTROL_WS="${CONTROL_WS:-}"
CONTROL_PROTOCOL="${CONTROL_PROTOCOL:-relay}"
DASHBOARD_VIDEO_DECODER="${DASHBOARD_VIDEO_DECODER:-auto}"
DASHBOARD_VIDEO_ON_DEMAND="${DASHBOARD_VIDEO_ON_DEMAND:-0}"
DASHBOARD_VIDEO_PREWARM_SUBSTREAMS="${DASHBOARD_VIDEO_PREWARM_SUBSTREAMS:-0}"
DASHBOARD_VIDEO_SENDER_IDLE_SEC="${DASHBOARD_VIDEO_SENDER_IDLE_SEC:-45}"
DASHBOARD_VIDEO_SENDER_ENCODER="${DASHBOARD_VIDEO_SENDER_ENCODER:-${VIDEO_ENCODER:-auto}}"
DASHBOARD_VIDEO_SENDER_RUN_DIR="${DASHBOARD_VIDEO_SENDER_RUN_DIR:-}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --topology FILE             Topology JSON. Default: ${DEFAULT_TOPOLOGY}
  --host HOST                 HTTP listen host. Default: ${HOST}
  --port PORT                 HTTP listen port. Default: ${PORT}
  --control-ws URL            Default remote-control WebSocket URL.
  --control-protocol MODE     relay or legacy. Default: ${CONTROL_PROTOCOL}
  --video-decoder NAME        H.264 decoder: auto, hard, nvh264dec, vaapi, v4l2,
                              avdec_h264. Default: ${DASHBOARD_VIDEO_DECODER}
  --video-on-demand           Start RTP camera senders only when a video stream is requested.
  --no-video-on-demand        Keep using pre-started RTP camera senders.
  --video-prewarm-substreams  In on-demand mode, start all preview substream senders in the background.
  --no-video-prewarm-substreams
                              Do not prewarm preview substream senders.
  --video-sender-idle-sec N   Stop on-demand senders after N idle seconds.
                              Default: ${DASHBOARD_VIDEO_SENDER_IDLE_SEC}
  --video-sender-encoder NAME Encoder for on-demand senders. Default: ${DASHBOARD_VIDEO_SENDER_ENCODER}
  --video-sender-run-dir DIR  Log/pid directory for on-demand senders.
  --help                      Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --topology)
      [[ $# -ge 2 ]] || { echo "[dashboard_up][ERR] --topology requires a path" >&2; exit 1; }
      TOPOLOGY_FILE="$2"
      shift 2
      ;;
    --host)
      [[ $# -ge 2 ]] || { echo "[dashboard_up][ERR] --host requires a value" >&2; exit 1; }
      HOST="$2"
      shift 2
      ;;
    --port)
      [[ $# -ge 2 ]] || { echo "[dashboard_up][ERR] --port requires a value" >&2; exit 1; }
      PORT="$2"
      shift 2
      ;;
    --control-ws)
      [[ $# -ge 2 ]] || { echo "[dashboard_up][ERR] --control-ws requires a URL" >&2; exit 1; }
      CONTROL_WS="$2"
      shift 2
      ;;
    --control-protocol)
      [[ $# -ge 2 ]] || { echo "[dashboard_up][ERR] --control-protocol requires relay or legacy" >&2; exit 1; }
      CONTROL_PROTOCOL="$2"
      shift 2
      ;;
    --video-decoder)
      [[ $# -ge 2 ]] || { echo "[dashboard_up][ERR] --video-decoder requires a value" >&2; exit 1; }
      DASHBOARD_VIDEO_DECODER="$2"
      shift 2
      ;;
    --video-on-demand)
      DASHBOARD_VIDEO_ON_DEMAND=1
      shift
      ;;
    --no-video-on-demand)
      DASHBOARD_VIDEO_ON_DEMAND=0
      shift
      ;;
    --video-prewarm-substreams)
      DASHBOARD_VIDEO_PREWARM_SUBSTREAMS=1
      shift
      ;;
    --no-video-prewarm-substreams)
      DASHBOARD_VIDEO_PREWARM_SUBSTREAMS=0
      shift
      ;;
    --video-sender-idle-sec)
      [[ $# -ge 2 ]] || { echo "[dashboard_up][ERR] --video-sender-idle-sec requires a value" >&2; exit 1; }
      DASHBOARD_VIDEO_SENDER_IDLE_SEC="$2"
      shift 2
      ;;
    --video-sender-encoder)
      [[ $# -ge 2 ]] || { echo "[dashboard_up][ERR] --video-sender-encoder requires a value" >&2; exit 1; }
      DASHBOARD_VIDEO_SENDER_ENCODER="$2"
      shift 2
      ;;
    --video-sender-run-dir)
      [[ $# -ge 2 ]] || { echo "[dashboard_up][ERR] --video-sender-run-dir requires a directory" >&2; exit 1; }
      DASHBOARD_VIDEO_SENDER_RUN_DIR="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[dashboard_up][ERR] unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

case "$CONTROL_PROTOCOL" in
  relay|legacy) ;;
  *)
    echo "[dashboard_up][ERR] --control-protocol must be relay or legacy" >&2
    exit 1
    ;;
esac

[[ -f "$TOPOLOGY_FILE" ]] || { echo "[dashboard_up][ERR] topology not found: $TOPOLOGY_FILE" >&2; exit 1; }
[[ -f "$SERVER_PY" ]] || { echo "[dashboard_up][ERR] server not found: $SERVER_PY" >&2; exit 1; }

args=(
  "$PYTHON_BIN" "$SERVER_PY"
  --topology "$TOPOLOGY_FILE"
  --host "$HOST"
  --port "$PORT"
  --control-protocol "$CONTROL_PROTOCOL"
  --video-decoder "$DASHBOARD_VIDEO_DECODER"
  --video-sender-idle-sec "$DASHBOARD_VIDEO_SENDER_IDLE_SEC"
  --video-sender-encoder "$DASHBOARD_VIDEO_SENDER_ENCODER"
)
case "$DASHBOARD_VIDEO_ON_DEMAND" in
  1|true|True|TRUE|yes|Yes|YES|on|On|ON)
    args+=(--video-on-demand)
    ;;
  *)
    args+=(--no-video-on-demand)
    ;;
esac
case "$DASHBOARD_VIDEO_PREWARM_SUBSTREAMS" in
  1|true|True|TRUE|yes|Yes|YES|on|On|ON)
    args+=(--video-prewarm-substreams)
    ;;
  *)
    args+=(--no-video-prewarm-substreams)
    ;;
esac
if [[ -n "$CONTROL_WS" ]]; then
  args+=(--control-ws "$CONTROL_WS")
fi
if [[ -n "$DASHBOARD_VIDEO_SENDER_RUN_DIR" ]]; then
  args+=(--video-sender-run-dir "$DASHBOARD_VIDEO_SENDER_RUN_DIR")
fi

echo "[dashboard_up] topology=${TOPOLOGY_FILE}"
echo "[dashboard_up] url=http://127.0.0.1:${PORT}"
echo "[dashboard_up] video_on_demand=${DASHBOARD_VIDEO_ON_DEMAND}"
echo "[dashboard_up] video_prewarm_substreams=${DASHBOARD_VIDEO_PREWARM_SUBSTREAMS}"
exec "${args[@]}"
