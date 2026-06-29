#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/env_defaults.sh"
MESH_DIR="$UCS_MESH_DIR"
cd "$MESH_DIR" || exit 1

resolve_desktop_python() {
  [[ -n "${PYTHON_BIN:-}" && -x "${PYTHON_BIN}" ]] || return 1
  printf '%s\n' "$PYTHON_BIN"
}

desktop_control_ready() {
  local python_bin=""
  if [[ -n "${MAVSDK_SERVER_BIN:-}" && -x "${MAVSDK_SERVER_BIN}" ]]; then
    :
  elif [[ -x "${MESH_DIR}/control/mavsdk_server" || -x "${MESH_DIR}/control/mavsdk_server_musl_x86_64" ]]; then
    :
  elif ! command -v mavsdk_server >/dev/null 2>&1; then
    return 1
  fi

  python_bin="$(resolve_desktop_python || true)"
  [[ -n "$python_bin" ]] || return 1
  "$python_bin" -c 'import mavsdk, websockets' >/dev/null 2>&1
}

control_args=(--no-control)
if [[ "${UCS_MESH_DESKTOP_CONTROL:-auto}" != "off" ]]; then
  if desktop_control_ready; then
    control_args=(--with-control --control-uav "${CONTROL_UAV:-all}")
  else
    echo "[desktop_fleet_up][WARN] control dependencies are not ready; starting dashboard/video without browser control."
    echo "[desktop_fleet_up][WARN] Put mavsdk_server under control/ or set PYTHON_BIN and MAVSDK_SERVER_BIN to enable control."
  fi
fi

"$SCRIPT_DIR/fleet_up.sh" \
  --topology "$MESH_DIR/topology/wifi_adhoc_matrix_2x3_6uav.json" \
  --with-video \
  --gui \
  --video-bitrate-kbps "${VIDEO_BITRATE_KBPS:-4000}" \
  --video-fps "${VIDEO_FPS:-24}" \
  --video-encoder "${VIDEO_ENCODER:-auto}" \
  "${control_args[@]}" \
  --with-dashboard \
  --dashboard-port "${DASHBOARD_PORT:-8088}"
rc=$?

echo
echo "Exit code: ${rc}"
read -r -p "Press Enter to close..."
exit "$rc"
