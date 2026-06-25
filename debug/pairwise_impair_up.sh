#!/usr/bin/env bash
set -Eeuo pipefail

# UCS mesh pairwise impairment launcher
#
# Deprecated for the normal Stage-4 path: pairwise loss/delay now lives in
# ns-3 when the topology declares impairment_policy=ns3_pairwise_links. This
# wrapper remains for rollback/debug tc mode and for cleaning old qdiscs.
#
# Responsibilities:
#   - Read the topology JSON
#   - Start/stop pairwise_impair_worker.py
#   - Keep one Linux tc qdisc tree per endpoint tap
#   - Apply per-destination loss/delay using the 21 metrics files

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MESH_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${MESH_DIR}/fleet/env_defaults.sh"
DEFAULT_TOPOLOGY="${MESH_DIR}/topology/wifi_adhoc_matrix_2x3_6uav.json"
WORKER_PY="${MESH_DIR}/debug/pairwise_impair_worker.py"

TOPOLOGY_FILE="${TOPOLOGY_FILE:-$DEFAULT_TOPOLOGY}"
VERBOSE=0
DRY_RUN=0
ONCE=0
CLEANUP_ONLY=0
STOP_ONLY=0
FOREGROUND=1

usage() {
  cat <<EOF
Usage: $(basename "$0") [--topology FILE] [--verbose] [--dry-run] [--once] [--fg|--bg] [--stop] [--cleanup]

--topology FILE   Topology JSON file. Default: ${DEFAULT_TOPOLOGY}
--verbose         Print per-link update details.
--dry-run         Print tc commands without applying them.
--once            Apply one setup/update cycle and exit.
--fg              Foreground mode. (Default)
--bg              Start worker in detached background mode and exit.
--stop            Stop existing worker for the scenario, then cleanup qdiscs.
--cleanup         Cleanup qdiscs for topology endpoint taps and exit.
EOF
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "[pairwise_impair_up][ERR] missing command: $1" >&2
    exit 1
  }
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --topology)
      [[ $# -ge 2 ]] || { echo "[pairwise_impair_up][ERR] --topology requires a path" >&2; exit 1; }
      TOPOLOGY_FILE="$2"
      shift 2
      ;;
    --verbose)
      VERBOSE=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --once)
      ONCE=1
      shift
      ;;
    --fg)
      FOREGROUND=1
      shift
      ;;
    --bg)
      FOREGROUND=0
      shift
      ;;
    --stop)
      STOP_ONLY=1
      shift
      ;;
    --cleanup)
      CLEANUP_ONLY=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[pairwise_impair_up][ERR] unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

need_cmd "$PYTHON_BIN"

[[ -f "$TOPOLOGY_FILE" ]] || { echo "[pairwise_impair_up][ERR] topology file not found: $TOPOLOGY_FILE" >&2; exit 1; }
[[ -f "$WORKER_PY" ]] || { echo "[pairwise_impair_up][ERR] worker not found: $WORKER_PY" >&2; exit 1; }

TOPOLOGY_FILE="$("$PYTHON_BIN" -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$TOPOLOGY_FILE")"

SCENARIO_ID="$("$PYTHON_BIN" - "$TOPOLOGY_FILE" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as f:
    topo = json.load(f)
sid = topo.get("scenario_id")
if not sid:
    raise SystemExit("[pairwise_impair_up][ERR] missing scenario_id")
print(sid)
PY
)"

IMPAIRMENT_POLICY="$("$PYTHON_BIN" - "$TOPOLOGY_FILE" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as f:
    topo = json.load(f)
policy = (
    topo.get("globals", {})
        .get("experiment_net", {})
        .get("impairment_policy", "ns3_access_links")
)
print(policy)
PY
)"

PIDFILE="/tmp/ucs_mesh_pairwise_impair_${SCENARIO_ID}.pid"
LOGFILE="/tmp/ucs_mesh_pairwise_impair_${SCENARIO_ID}.log"

stop_existing() {
  if [[ ! -f "$PIDFILE" ]]; then
    echo "[pairwise_impair_up] no pidfile: $PIDFILE"
    return 0
  fi

  local pid
  pid="$(cat "$PIDFILE" 2>/dev/null || true)"
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    echo "[pairwise_impair_up] stopping worker pid=${pid}"
    kill "$pid" 2>/dev/null || true
    sleep 0.3
    kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
  fi
  rm -f "$PIDFILE"
}

WORKER_CMD=("$PYTHON_BIN" "$WORKER_PY" --topology "$TOPOLOGY_FILE")
[[ "$VERBOSE" -eq 1 ]] && WORKER_CMD+=(--verbose)
[[ "$DRY_RUN" -eq 1 ]] && WORKER_CMD+=(--dry-run)
[[ "$ONCE" -eq 1 ]] && WORKER_CMD+=(--once)
[[ "$CLEANUP_ONLY" -eq 1 ]] && WORKER_CMD+=(--cleanup)

echo "[pairwise_impair_up] topology = $TOPOLOGY_FILE"
echo "[pairwise_impair_up] scenario = $SCENARIO_ID"
echo "[pairwise_impair_up] impairment_policy = $IMPAIRMENT_POLICY"

if [[ "$IMPAIRMENT_POLICY" != "linux_pairwise_tc" && "$STOP_ONLY" -ne 1 && "$CLEANUP_ONLY" -ne 1 ]]; then
  echo "[pairwise_impair_up] tc worker not started; topology uses ns-3 pairwise impairment"
  echo "[pairwise_impair_up] start only fleet_up/net_up for this topology"
  exit 0
fi

need_cmd tc

if [[ "$STOP_ONLY" -eq 1 ]]; then
  stop_existing
  "${WORKER_CMD[@]}" --cleanup
  exit 0
fi

if [[ "$CLEANUP_ONLY" -eq 1 || "$DRY_RUN" -eq 1 || "$ONCE" -eq 1 ]]; then
  "${WORKER_CMD[@]}"
  exit $?
fi

if [[ -f "$PIDFILE" ]]; then
  OLD_PID="$(cat "$PIDFILE" 2>/dev/null || true)"
  if [[ -n "$OLD_PID" ]] && kill -0 "$OLD_PID" 2>/dev/null; then
    echo "[pairwise_impair_up][ERR] worker already running: pid=${OLD_PID}" >&2
    echo "[pairwise_impair_up][ERR] use --stop first if you want to restart it" >&2
    exit 1
  fi
  rm -f "$PIDFILE"
fi

if [[ "$FOREGROUND" -eq 1 ]]; then
  echo "[pairwise_impair_up] starting worker in foreground ..."
  "${WORKER_CMD[@]}"
else
  echo "[pairwise_impair_up] starting worker in background ..."
  if command -v setsid >/dev/null 2>&1; then
    setsid "${WORKER_CMD[@]}" >>"$LOGFILE" 2>&1 < /dev/null &
  else
    "${WORKER_CMD[@]}" >>"$LOGFILE" 2>&1 < /dev/null &
  fi
  WORKER_PID=$!
  echo "$WORKER_PID" > "$PIDFILE"
  echo "[pairwise_impair_up] pid=${WORKER_PID}"
  echo "[pairwise_impair_up] log=${LOGFILE}"
fi
