#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MESH_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${MESH_DIR}/fleet/env_defaults.sh"
CONTROL_CORE_PY="${SCRIPT_DIR}/control_core.py"
TARGET_UAV=""
SCENARIO_ID="wifi_adhoc_matrix_2x3_6uav_v1"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --uav uavNN       Stop only this target UAV control runtime.
  --scenario ID     Scenario id. Default: ${SCENARIO_ID}
  --all             Stop all BMv2 control runtimes for the scenario.
  --help            Show this help.
EOF
}

ALL=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --uav)
      [[ $# -ge 2 ]] || { echo "[control_down][ERR] --uav requires a value" >&2; exit 1; }
      TARGET_UAV="$2"
      shift 2
      ;;
    --scenario)
      [[ $# -ge 2 ]] || { echo "[control_down][ERR] --scenario requires a value" >&2; exit 1; }
      SCENARIO_ID="$2"
      shift 2
      ;;
    --all)
      ALL=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[control_down][ERR] unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [[ "$ALL" -ne 1 && -z "$TARGET_UAV" ]]; then
  TARGET_UAV="uav04"
fi

pid_is_alive() {
  local pid="$1"
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

stop_pid() {
  local pid="$1"
  local label="$2"

  if pid_is_alive "$pid"; then
    echo "[control_down] stopping pid=${pid} ${label}"
    kill -TERM "$pid" >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5; do
      pid_is_alive "$pid" || break
      sleep 0.2
    done
    if pid_is_alive "$pid"; then
      echo "[control_down] force stopping pid=${pid} ${label}"
      kill -KILL "$pid" >/dev/null 2>&1 || true
    fi
  fi
}

stop_pidfile() {
  local pidfile="$1"
  local label="$2"

  [[ -s "$pidfile" ]] || return 0

  local pid
  pid="$(cat "$pidfile" 2>/dev/null || true)"
  stop_pid "$pid" "${label} (${pidfile})"
  rm -f "$pidfile"
}

stop_residual_control_core() {
  command -v pgrep >/dev/null 2>&1 || return 0

  local pid cmd
  while read -r pid cmd; do
    [[ -n "${pid:-}" && -n "${cmd:-}" ]] || continue
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    [[ "$cmd" == *"$CONTROL_CORE_PY"* ]] || continue
    [[ "$cmd" == *"/control/${SCENARIO_ID}/"* ]] || continue
    if [[ "$ALL" -eq 1 || "$cmd" == *"--uav ${TARGET_UAV}"* ]]; then
      stop_pid "$pid" "residual control_core"
    fi
  done < <(pgrep -af 'control_core\.py' 2>/dev/null || true)
}

runtime_files=()
if [[ "$ALL" -eq 1 ]]; then
  while IFS= read -r path; do
    runtime_files+=("$path")
  done < <(find /tmp -maxdepth 1 -type f -name "ucs_mesh_control_${SCENARIO_ID}_*.runtime.json" 2>/dev/null | sort)
else
  runtime_files=("/tmp/ucs_mesh_control_${SCENARIO_ID}_${TARGET_UAV}.runtime.json")
fi

if [[ "${#runtime_files[@]}" -eq 0 ]]; then
  echo "[control_down] no runtime files found"
fi

for runtime in "${runtime_files[@]}"; do
  if [[ ! -s "$runtime" ]]; then
    echo "[control_down] missing runtime: $runtime"
    continue
  fi
  echo "[control_down] runtime=$runtime"
  mapfile -t pidfiles < <("$PYTHON_BIN" - "$runtime" <<'PY'
import json
import sys
payload = json.load(open(sys.argv[1], encoding="utf-8"))
for key in ("remote_web", "control_core", "mavsdk_server"):
    value = payload.get("pidfiles", {}).get(key)
    if value:
        print(value)
PY
)
  for pidfile in "${pidfiles[@]}"; do
    stop_pidfile "$pidfile" "$(basename "$pidfile" .pid)"
  done
  rm -f "$runtime"
done

stop_residual_control_core
