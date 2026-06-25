#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MESH_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${MESH_DIR}/fleet/env_defaults.sh"
DEFAULT_TOPOLOGY="${MESH_DIR}/topology/wifi_adhoc_matrix_2x3_6uav.json"

TOPOLOGY_FILE="${TOPOLOGY_FILE:-$DEFAULT_TOPOLOGY}"
CLUSTER_HEADS="${UCS_MESH_CLUSTER_HEADS:-1:uav01,2:uav04}"
DRY_RUN=0
VERBOSE=0

usage() {
  cat <<'USAGE'
Usage:
  apply_cluster_heads.sh [options]

Options:
  --topology FILE       Topology JSON file
  --cluster-heads MAP   Cluster head map. Default: 1:uav01,2:uav04
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
      [[ -n "$TOPOLOGY_FILE" ]] || { echo "[p4-cluster][ERR] --topology requires a file" >&2; exit 1; }
      shift 2
      ;;
    --cluster-heads)
      CLUSTER_HEADS="${2:-}"
      [[ -n "$CLUSTER_HEADS" ]] || { echo "[p4-cluster][ERR] --cluster-heads requires a map" >&2; exit 1; }
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
      echo "[p4-cluster][ERR] unknown argument: $1" >&2
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
  --cluster-head-routes
  --cluster-heads "$CLUSTER_HEADS"
)

if [[ "$VERBOSE" -eq 1 ]]; then
  args+=(--verbose)
fi
if [[ "$DRY_RUN" -eq 1 ]]; then
  args+=(--dry-run)
fi

"${SCRIPT_DIR}/load_pipeline_observation.sh" "${args[@]}"
