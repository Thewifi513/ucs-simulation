#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MESH_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${MESH_DIR}/fleet/env_defaults.sh"
DEFAULT_TOPOLOGY="${MESH_DIR}/topology/wifi_adhoc_matrix_2x3_6uav.json"

TOPOLOGY_FILE="${TOPOLOGY_FILE:-$DEFAULT_TOPOLOGY}"
ROUTING_MODE="${UCS_MESH_ROUTING_MODE:-adaptive_prior}"
ROUTING_METRICS_MAX_AGE_SEC="${UCS_MESH_ROUTING_METRICS_MAX_AGE_SEC:-15}"
INTERVAL_SEC="${UCS_MESH_ADAPTIVE_ROUTE_INTERVAL_SEC:-5}"
TARGETS_CSV="${UCS_MESH_ADAPTIVE_ROUTE_TARGETS:-}"
CLUSTER_HEADS="${UCS_MESH_CLUSTER_HEADS:-}"
GS_APP_IF="${UCS_MESH_GS_APP_IF:-gs0}"
ONCE=0
VERBOSE=0

usage() {
  cat <<'USAGE'
Usage:
  adaptive_route_monitor.sh [options]

Options:
  --topology FILE       Topology JSON file
  --targets CSV         Targets to watch, e.g. gs,uav05. Default: gs plus all UAVs
  --interval-sec SEC    Recompute interval. Default: 5
  --routing-mode MODE   Route entry mode. Default: adaptive_prior
  --routing-metrics-max-age-sec SEC
                        Max age for live routing metrics. Default: 15
  --once                Run one check/apply pass and exit
  --verbose             Print unchanged targets too
  -h, --help            Show this help
USAGE
}

die() {
  echo "[p4-route-monitor][ERR] $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --topology)
      TOPOLOGY_FILE="${2:-}"
      [[ -n "$TOPOLOGY_FILE" ]] || die "--topology requires a file"
      shift 2
      ;;
    --targets)
      TARGETS_CSV="${2:-}"
      [[ -n "$TARGETS_CSV" ]] || die "--targets requires a CSV value"
      shift 2
      ;;
    --interval-sec)
      INTERVAL_SEC="${2:-}"
      [[ "$INTERVAL_SEC" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "--interval-sec requires a number"
      shift 2
      ;;
    --routing-mode)
      ROUTING_MODE="${2:-}"
      [[ -n "$ROUTING_MODE" ]] || die "--routing-mode requires a mode"
      shift 2
      ;;
    --routing-metrics-max-age-sec)
      ROUTING_METRICS_MAX_AGE_SEC="${2:-}"
      [[ "$ROUTING_METRICS_MAX_AGE_SEC" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "--routing-metrics-max-age-sec requires a number"
      shift 2
      ;;
    --once)
      ONCE=1
      shift
      ;;
    --verbose)
      VERBOSE=1
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

command -v "$PYTHON_BIN" >/dev/null 2>&1 || die "Python is required: $PYTHON_BIN"

targets() {
  if [[ -n "$TARGETS_CSV" ]]; then
    "$PYTHON_BIN" - "$TARGETS_CSV" <<'PY'
import sys
for item in sys.argv[1].split(","):
    item = item.strip()
    if item:
        print(item)
PY
    return
  fi
  "$PYTHON_BIN" - "$TOPOLOGY_FILE" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    topo = json.load(handle)
print(str(topo.get("globals", {}).get("gs_id", "gs")))
for inst in topo.get("instances", []):
    if inst.get("type") == "uav":
        print(str(inst.get("id")))
PY
}

entries_changed() {
  local old_file="$1"
  local new_file="$2"
  "$PYTHON_BIN" - "$old_file" "$new_file" <<'PY'
import json
import sys

def relevant(path):
    try:
        with open(path, encoding="utf-8") as handle:
            payload = json.load(handle)
    except OSError:
        return None
    return {
        "mode": payload.get("mode"),
        "target_id": payload.get("target_id"),
        "entries": payload.get("entries", []),
        "routes": payload.get("routes", {}),
    }

sys.exit(0 if relevant(sys.argv[1]) == relevant(sys.argv[2]) else 1)
PY
}

check_one() {
  local target="$1"
  local entries_dir="${MESH_DIR}/p4/build/p4runtime_entries"
  local current="${entries_dir}/${target}.json"
  local tmp
  tmp="$(mktemp "/tmp/ucs_${target}_route.XXXXXX.json")"
  trap 'rm -f "$tmp"' RETURN

  "$PYTHON_BIN" "${MESH_DIR}/p4/cluster_head_entries.py" \
    --topology "$TOPOLOGY_FILE" \
    --target-id "$target" \
    --output "$tmp" \
    --routing-mode "$ROUTING_MODE" \
    --metrics-max-age-sec "$ROUTING_METRICS_MAX_AGE_SEC" \
    --cluster-heads "$CLUSTER_HEADS" \
    --gs-app-if "$GS_APP_IF" >/tmp/ucs_route_monitor_generate.log 2>&1 || {
      cat /tmp/ucs_route_monitor_generate.log >&2 || true
      return 1
    }

  if [[ -f "$current" ]] && entries_changed "$current" "$tmp"; then
    [[ "$VERBOSE" -eq 1 ]] && echo "[p4-route-monitor] unchanged target=${target}"
    return 0
  fi

  echo "[p4-route-monitor] changed target=${target}; applying"
  "${SCRIPT_DIR}/apply_adaptive_routes.sh" \
    --topology "$TOPOLOGY_FILE" \
    --target "$target" \
    --routing-mode "$ROUTING_MODE" \
    --routing-metrics-max-age-sec "$ROUTING_METRICS_MAX_AGE_SEC"
}

echo "[p4-route-monitor] topology=${TOPOLOGY_FILE} mode=${ROUTING_MODE} interval=${INTERVAL_SEC}s metrics_max_age=${ROUTING_METRICS_MAX_AGE_SEC}s"

while true; do
  while IFS= read -r target; do
    [[ -n "$target" ]] || continue
    check_one "$target"
  done < <(targets)

  if [[ "$ONCE" -eq 1 ]]; then
    exit 0
  fi
  sleep "$INTERVAL_SEC"
done
