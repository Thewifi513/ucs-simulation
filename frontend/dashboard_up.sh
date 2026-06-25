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
)
if [[ -n "$CONTROL_WS" ]]; then
  args+=(--control-ws "$CONTROL_WS")
fi

echo "[dashboard_up] topology=${TOPOLOGY_FILE}"
echo "[dashboard_up] url=http://127.0.0.1:${PORT}"
exec "${args[@]}"
