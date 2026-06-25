#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/env_defaults.sh"
MESH_DIR="$UCS_MESH_DIR"
cd "$MESH_DIR" || exit 1

"$SCRIPT_DIR/fleet_down.sh" --topology "$MESH_DIR/topology/wifi_adhoc_matrix_2x3_6uav.json"
rc=$?

echo
echo "Exit code: ${rc}"
read -r -p "Press Enter to close..."
exit "$rc"
