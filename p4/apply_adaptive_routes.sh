#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MESH_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${MESH_DIR}/fleet/env_defaults.sh"
DEFAULT_TOPOLOGY="${MESH_DIR}/topology/wifi_adhoc_matrix_2x3_6uav.json"

TOPOLOGY_FILE="${TOPOLOGY_FILE:-$DEFAULT_TOPOLOGY}"
ROUTING_MODE="${UCS_MESH_ROUTING_MODE:-adaptive_resource}"
ROUTING_METRICS_MAX_AGE_SEC="${UCS_MESH_ROUTING_METRICS_MAX_AGE_SEC:-15}"
TARGET_FILTER=""
DRY_RUN=0
VERBOSE=0

usage() {
  cat <<'USAGE'
Usage:
  apply_adaptive_routes.sh [options]

Options:
  --topology FILE       Topology JSON file
  --target ID           Load only one UAV id or gs
  --targets CSV         Load a comma-separated set of UAV ids or gs
  --routing-mode MODE   Route entry mode. Default: adaptive_resource
  --routing-metrics-max-age-sec SEC
                        Max age for live routing metrics. Default: 15
  --dry-run             Print resolved P4Runtime targets without loading
  --verbose             Print more details
  -h, --help            Show this help

This changes only BMv2 pipelines/table entries. Linux routes remain the normal
on-link experiment-net routes.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --topology)
      TOPOLOGY_FILE="${2:-}"
      [[ -n "$TOPOLOGY_FILE" ]] || { echo "[p4-adaptive][ERR] --topology requires a file" >&2; exit 1; }
      shift 2
      ;;
    --routing-mode)
      ROUTING_MODE="${2:-}"
      [[ -n "$ROUTING_MODE" ]] || { echo "[p4-adaptive][ERR] --routing-mode requires a mode" >&2; exit 1; }
      shift 2
      ;;
    --routing-metrics-max-age-sec)
      ROUTING_METRICS_MAX_AGE_SEC="${2:-}"
      [[ "$ROUTING_METRICS_MAX_AGE_SEC" =~ ^[0-9]+([.][0-9]+)?$ ]] || { echo "[p4-adaptive][ERR] --routing-metrics-max-age-sec requires a number" >&2; exit 1; }
      shift 2
      ;;
    --target)
      TARGET_FILTER="${2:-}"
      [[ -n "$TARGET_FILTER" ]] || { echo "[p4-adaptive][ERR] --target requires an id" >&2; exit 1; }
      shift 2
      ;;
    --targets)
      TARGET_FILTER="${2:-}"
      [[ -n "$TARGET_FILTER" ]] || { echo "[p4-adaptive][ERR] --targets requires a CSV value" >&2; exit 1; }
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
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[p4-adaptive][ERR] unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

args=(
  --topology "$TOPOLOGY_FILE"
  --program "$MESH_DIR/p4/ucs_edge_cluster_route.p4"
  --bmv2-json "$MESH_DIR/p4/build/ucs_edge_cluster_route.json"
  --p4info "$MESH_DIR/p4/build/ucs_edge_cluster_route.p4info.txt"
  --include-gs
  --routing-entries
  --routing-mode "$ROUTING_MODE"
  --routing-metrics-max-age-sec "$ROUTING_METRICS_MAX_AGE_SEC"
)

if [[ -n "$TARGET_FILTER" ]]; then
  if [[ "$TARGET_FILTER" == *,* ]]; then
    args+=(--targets "$TARGET_FILTER")
  else
    args+=(--target "$TARGET_FILTER")
  fi
fi

if [[ "$VERBOSE" -eq 1 ]]; then
  args+=(--verbose)
fi
if [[ "$DRY_RUN" -eq 1 ]]; then
  args+=(--dry-run)
fi

"${SCRIPT_DIR}/load_pipeline_observation.sh" "${args[@]}"
