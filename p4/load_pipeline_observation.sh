#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MESH_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${MESH_DIR}/fleet/env_defaults.sh"
MESH_DIR="$(realpath "${UCS_MESH_DIR}")"
SCRIPTS_ROOT="$(realpath "${UCS_SCRIPTS_ROOT}")"
DEFAULT_TOPOLOGY="${MESH_DIR}/topology/wifi_adhoc_matrix_2x3_6uav.json"

TOPOLOGY_FILE="${TOPOLOGY_FILE:-$DEFAULT_TOPOLOGY}"
P4_PROGRAM_OVERRIDE=""
BMV2_JSON_OVERRIDE=""
P4INFO_OVERRIDE=""
TARGET_FILTER=""
INCLUDE_GS=0
INSTALL_CLUSTER_HEAD_ROUTES=0
ROUTING_MODE="${UCS_MESH_ROUTING_MODE:-}"
CLUSTER_HEADS="${UCS_MESH_CLUSTER_HEADS:-}"
if [[ -n "${UCS_MESH_GS_APP_IF+x}" ]]; then
  GS_APP_IF="$UCS_MESH_GS_APP_IF"
  GS_APP_IF_ENV_SET=1
else
  GS_APP_IF=""
  GS_APP_IF_ENV_SET=0
fi
GS_APP_IF_CLI_SET=0
GS_DEVICE_ID="${UCS_MESH_GS_P4_DEVICE_ID:-100}"
GS_GRPC_ADDR="${UCS_MESH_GS_BMV2_GRPC_ADDR:-127.0.0.1:9560}"
P4RUNTIME_IMAGE="${P4RUNTIME_IMAGE:-${UCS_MESH_P4RUNTIME_IMAGE:-ucs-p4runtime-sh:20260625}}"
COMPILE="${UCS_MESH_P4_COMPILE:-0}"
DRY_RUN=0
VERBOSE=0

usage() {
  cat <<'USAGE'
Usage:
  load_pipeline_observation.sh [options]

Options:
  --topology FILE       Topology JSON file
  --program FILE        Override P4 source path
  --bmv2-json FILE      Override compiled BMv2 JSON path
  --p4info FILE         Override P4Info text path
  --target ID           Load only one UAV id or container name
  --include-gs          Also load the host-side GS BMv2 edge target
  --gs-app-if IFACE     Host GS app-facing interface for route MACs. Default: topology gs_edge.app_if or gs0
  --gs-device-id ID     P4Runtime device id for the GS edge. Default: 100
  --gs-grpc-addr ADDR   P4Runtime address for the GS edge. Default: 127.0.0.1:9560
  --routing-entries     Install BMv2 route table entries from programmable_net.routing.mode
  --routing-mode MODE   Route entry mode: cluster_heads or adaptive_prior. Default: topology routing.mode
  --cluster-head-routes Backward-compatible alias for --routing-entries
  --cluster-heads MAP   Cluster head map, e.g. 1:uav01,2:uav04
  --p4runtime-image IMG P4Runtime shell image. Default: ucs-p4runtime-sh:20260625
  --compile             Compile missing/stale P4 artifacts before loading
  --no-compile          Do not compile missing/stale P4 artifacts first. Default.
  --dry-run             Print resolved targets without loading
  --verbose             Print more details
  -h, --help            Show this help
USAGE
}

log() {
  echo "[p4-load] $*"
}

vlog() {
  if [[ "$VERBOSE" -eq 1 ]]; then
    echo "[p4-load] $*"
  fi
}

die() {
  echo "[p4-load][ERR] $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --topology)
      TOPOLOGY_FILE="${2:-}"
      [[ -n "$TOPOLOGY_FILE" ]] || die "--topology requires a file"
      shift 2
      ;;
    --program)
      P4_PROGRAM_OVERRIDE="${2:-}"
      [[ -n "$P4_PROGRAM_OVERRIDE" ]] || die "--program requires a file"
      shift 2
      ;;
    --bmv2-json)
      BMV2_JSON_OVERRIDE="${2:-}"
      [[ -n "$BMV2_JSON_OVERRIDE" ]] || die "--bmv2-json requires a file"
      shift 2
      ;;
    --p4info)
      P4INFO_OVERRIDE="${2:-}"
      [[ -n "$P4INFO_OVERRIDE" ]] || die "--p4info requires a file"
      shift 2
      ;;
    --target)
      TARGET_FILTER="${2:-}"
      [[ -n "$TARGET_FILTER" ]] || die "--target requires a UAV id or container name"
      shift 2
      ;;
    --include-gs)
      INCLUDE_GS=1
      shift
      ;;
    --gs-app-if)
      GS_APP_IF="${2:-}"
      [[ -n "$GS_APP_IF" ]] || die "--gs-app-if requires an interface name"
      GS_APP_IF_CLI_SET=1
      shift 2
      ;;
    --gs-device-id)
      GS_DEVICE_ID="${2:-}"
      [[ "$GS_DEVICE_ID" =~ ^[0-9]+$ ]] || die "--gs-device-id requires an integer"
      shift 2
      ;;
    --gs-grpc-addr)
      GS_GRPC_ADDR="${2:-}"
      [[ -n "$GS_GRPC_ADDR" ]] || die "--gs-grpc-addr requires an address"
      shift 2
      ;;
    --cluster-head-routes)
      INSTALL_CLUSTER_HEAD_ROUTES=1
      shift
      ;;
    --routing-entries)
      INSTALL_CLUSTER_HEAD_ROUTES=1
      shift
      ;;
    --routing-mode)
      ROUTING_MODE="${2:-}"
      [[ -n "$ROUTING_MODE" ]] || die "--routing-mode requires a mode"
      shift 2
      ;;
    --cluster-heads)
      CLUSTER_HEADS="${2:-}"
      [[ -n "$CLUSTER_HEADS" ]] || die "--cluster-heads requires a map"
      shift 2
      ;;
    --p4runtime-image)
      P4RUNTIME_IMAGE="${2:-}"
      [[ -n "$P4RUNTIME_IMAGE" ]] || die "--p4runtime-image requires an image tag"
      shift 2
      ;;
    --compile)
      COMPILE=1
      shift
      ;;
    --no-compile)
      COMPILE=0
      shift
      ;;
    --dry-run)
      DRY_RUN=1
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

case "$COMPILE" in
  1|true|True|TRUE|yes|Yes|YES|on|On|ON)
    COMPILE=1
    ;;
  0|false|False|FALSE|no|No|NO|off|Off|OFF)
    COMPILE=0
    ;;
  *)
    die "unsupported UCS_MESH_P4_COMPILE/compile mode: $COMPILE"
    ;;
esac

command -v docker >/dev/null 2>&1 || die "docker is required"
command -v "$PYTHON_BIN" >/dev/null 2>&1 || die "Python is required: $PYTHON_BIN"
command -v realpath >/dev/null 2>&1 || die "realpath is required"
command -v timeout >/dev/null 2>&1 || die "timeout is required"

resolve_repo_path() {
  local path="$1"
  if [[ "$path" = /* ]]; then
    realpath -m "$path"
  elif [[ -e "${MESH_DIR}/${path}" ]]; then
    realpath -m "${MESH_DIR}/${path}"
  elif [[ -e "${SCRIPTS_ROOT}/${path}" ]]; then
    realpath -m "${SCRIPTS_ROOT}/${path}"
  else
    realpath -m "${MESH_DIR}/${path}"
  fi
}

repo_rel_path() {
  local abs
  abs="$(realpath -m "$1")"
  case "$abs" in
    "${SCRIPTS_ROOT}"/*)
      printf '%s\n' "${abs#${SCRIPTS_ROOT}/}"
      ;;
    *)
      die "path must be under ${SCRIPTS_ROOT}: $abs"
      ;;
  esac
}

TOPOLOGY_FILE="$(resolve_repo_path "$TOPOLOGY_FILE")"
[[ -f "$TOPOLOGY_FILE" ]] || die "topology file not found: $TOPOLOGY_FILE"

RUNTIME_SH="$(mktemp /tmp/ucs_mesh_p4_load.XXXXXX.sh)"
cleanup_runtime_file() {
  rm -f "$RUNTIME_SH"
}
trap cleanup_runtime_file EXIT

"$PYTHON_BIN" - "$TOPOLOGY_FILE" "$TARGET_FILTER" "$INCLUDE_GS" "$GS_DEVICE_ID" "$GS_GRPC_ADDR" > "$RUNTIME_SH" <<'PY'
import json
import os
import shlex
import sys

topology_file, target_filter, include_gs_raw, gs_device_id_raw, gs_grpc_addr = sys.argv[1:]
include_gs_cli = include_gs_raw == "1"
with open(topology_file, "r", encoding="utf-8") as f:
    topo = json.load(f)

programmable = topo.get("programmable_net", topo.get("globals", {}).get("programmable_net", {}))
if programmable and not isinstance(programmable, dict):
    raise SystemExit("[p4-load][ERR] programmable_net must be an object")

control_plane = programmable.get("control_plane", {}) if programmable else {}
if control_plane and not isinstance(control_plane, dict):
    raise SystemExit("[p4-load][ERR] programmable_net.control_plane must be an object")
control_network = str(control_plane.get("network", "observation"))
if control_network != "observation":
    raise SystemExit(
        f"[p4-load][ERR] this loader supports only observation control plane, got: {control_network}"
    )

pipeline = programmable.get("pipeline", {}) if programmable else {}
if pipeline and not isinstance(pipeline, dict):
    raise SystemExit("[p4-load][ERR] programmable_net.pipeline must be an object")

p4_program = str(pipeline.get("p4_program", "p4/ucs_edge_cluster_route.p4"))
stem = os.path.splitext(os.path.basename(p4_program))[0]
bmv2_json = str(pipeline.get("bmv2_json", f"p4/build/{stem}.json"))
p4info = str(pipeline.get("p4info", f"p4/build/{stem}.p4info.txt"))

targets = []
gs_id = str(topo.get("globals", {}).get("gs_id", "gs"))
gs_edge = programmable.get("gs_edge", {}) if programmable else {}
if gs_edge and not isinstance(gs_edge, dict):
    raise SystemExit("[p4-load][ERR] programmable_net.gs_edge must be an object")
gs_app_if = str(gs_edge.get("app_if", "gs0"))
include_gs = include_gs_cli or bool(gs_edge.get("enabled", False))
if include_gs:
    gs_device_id = int(gs_edge.get("device_id", gs_device_id_raw))
    gs_grpc_addr = str(gs_edge.get("grpc_addr", gs_grpc_addr))
    if not target_filter or target_filter == gs_id:
        targets.append((gs_id, gs_id, gs_device_id, gs_grpc_addr, "host"))

for inst in topo.get("instances", []):
    if inst.get("type") != "uav":
        continue
    p4_cfg = inst.get("p4", {})
    if p4_cfg is False:
        continue
    if isinstance(p4_cfg, dict) and p4_cfg.get("enabled", True) is False:
        continue
    if not isinstance(p4_cfg, dict):
        p4_cfg = {}
    uav_id = str(inst.get("id"))
    container = str(inst.get("container_name", uav_id))
    if target_filter and target_filter not in {uav_id, container}:
        continue
    idx = int(inst.get("idx", "".join(ch for ch in uav_id if ch.isdigit()) or "0"))
    device_id = int(p4_cfg.get("device_id", 100 + idx))
    grpc_addr = str(p4_cfg.get("grpc_addr", "0.0.0.0:9559"))
    targets.append((uav_id, container, device_id, grpc_addr, "container"))

if not targets:
    raise SystemExit("[p4-load][ERR] no P4Runtime targets resolved")

def emit(name, value):
    print(f"{name}={shlex.quote(str(value))}")

emit("P4_PROGRAM_FROM_TOPOLOGY", p4_program)
emit("BMV2_JSON_FROM_TOPOLOGY", bmv2_json)
emit("P4INFO_FROM_TOPOLOGY", p4info)
emit("GS_APP_IF_FROM_TOPOLOGY", gs_app_if)
emit("TARGET_COUNT", len(targets))
for i, (uav_id, container, device_id, grpc_addr, target_kind) in enumerate(targets):
    emit(f"TARGET_ID_{i}", uav_id)
    emit(f"TARGET_CONTAINER_{i}", container)
    emit(f"TARGET_DEVICE_ID_{i}", device_id)
    emit(f"TARGET_GRPC_ADDR_{i}", grpc_addr)
    emit(f"TARGET_KIND_{i}", target_kind)
PY

# shellcheck disable=SC1090
source "$RUNTIME_SH"

P4_PROGRAM="${P4_PROGRAM_OVERRIDE:-$P4_PROGRAM_FROM_TOPOLOGY}"
BMV2_JSON="${BMV2_JSON_OVERRIDE:-$BMV2_JSON_FROM_TOPOLOGY}"
P4INFO="${P4INFO_OVERRIDE:-$P4INFO_FROM_TOPOLOGY}"
if [[ "$GS_APP_IF_CLI_SET" -eq 0 && "$GS_APP_IF_ENV_SET" -eq 0 ]]; then
  GS_APP_IF="$GS_APP_IF_FROM_TOPOLOGY"
fi
GS_APP_IF="${GS_APP_IF:-gs0}"

P4_PROGRAM_ABS="$(resolve_repo_path "$P4_PROGRAM")"
BMV2_JSON_ABS="$(resolve_repo_path "$BMV2_JSON")"
P4INFO_ABS="$(resolve_repo_path "$P4INFO")"

[[ -f "$P4_PROGRAM_ABS" ]] || die "P4 program not found: $P4_PROGRAM_ABS"

if [[ "$COMPILE" -eq 1 ]]; then
  if [[ ! -s "$BMV2_JSON_ABS" || ! -s "$P4INFO_ABS" || "$P4_PROGRAM_ABS" -nt "$BMV2_JSON_ABS" || "$P4_PROGRAM_ABS" -nt "$P4INFO_ABS" ]]; then
    log "compiling P4 artifacts before pipeline load"
    "$SCRIPT_DIR/compile.sh" --program "$P4_PROGRAM_ABS" --output-dir "$(dirname "$BMV2_JSON_ABS")"
  fi
fi

[[ -s "$BMV2_JSON_ABS" ]] || die "BMv2 JSON not found or empty: $BMV2_JSON_ABS"
[[ -s "$P4INFO_ABS" ]] || die "P4Info not found or empty: $P4INFO_ABS"

BMV2_JSON_REL="$(repo_rel_path "$BMV2_JSON_ABS")"
P4INFO_REL="$(repo_rel_path "$P4INFO_ABS")"
LOADER_REL="$(repo_rel_path "$MESH_DIR/p4/runtime_set_pipeline.py")"
CLUSTER_ENTRIES_HELPER_REL="$(repo_rel_path "$MESH_DIR/p4/cluster_head_entries.py")"
BMV2_JSON_IN_CONTAINER="/workspace/ucs/scripts/${BMV2_JSON_REL}"
P4INFO_IN_CONTAINER="/workspace/ucs/scripts/${P4INFO_REL}"
LOADER_IN_CONTAINER="/workspace/ucs/scripts/${LOADER_REL}"
CLUSTER_ENTRIES_HELPER_ABS="${MESH_DIR}/p4/cluster_head_entries.py"

grpc_port_from_addr() {
  local addr="$1"
  local port="${addr##*:}"
  [[ "$port" =~ ^[0-9]+$ ]] || die "cannot parse grpc port from address: $addr"
  printf '%s\n' "$port"
}

container_observation_ip() {
  local container="$1"
  docker inspect -f '{{range $name, $net := .NetworkSettings.Networks}}{{if $net.IPAddress}}{{println $net.IPAddress}}{{end}}{{end}}' "$container" 2>/dev/null | sed -n '1p'
}

grpc_host_from_addr() {
  local addr="$1"
  local host="${addr%:*}"
  [[ -n "$host" && "$host" != "$addr" ]] || die "cannot parse grpc host from address: $addr"
  if [[ "$host" == "0.0.0.0" ]]; then
    host="127.0.0.1"
  fi
  printf '%s\n' "$host"
}

wait_tcp() {
  local host="$1"
  local port="$2"
  local deadline=$((SECONDS + 10))
  while (( SECONDS < deadline )); do
    if timeout 1 bash -c "</dev/tcp/${host}/${port}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.2
  done
  return 1
}

load_one() {
  local uav_id="$1"
  local container="$2"
  local device_id="$3"
  local grpc_bind="$4"
  local target_kind="$5"
  local obs_ip grpc_port grpc_target running entries_abs entries_rel entries_in_container

  grpc_port="$(grpc_port_from_addr "$grpc_bind")"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    if [[ "$target_kind" == "host" ]]; then
      obs_ip="$(grpc_host_from_addr "$grpc_bind")"
      grpc_target="${obs_ip}:${grpc_port}"
    else
      grpc_target="<${container}-observation-ip>:${grpc_port}"
    fi
    log "dry-run target ${uav_id}: kind=${target_kind} container=${container} device=${device_id} grpc=${grpc_target}"
    return 0
  fi

  if [[ "$target_kind" == "host" ]]; then
    obs_ip="$(grpc_host_from_addr "$grpc_bind")"
  else
    running="$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null || true)"
    [[ "$running" == "true" ]] || die "container is not running: $container"

    obs_ip="$(container_observation_ip "$container")"
    [[ -n "$obs_ip" ]] || die "could not resolve observation IP for container: $container"
  fi
  grpc_target="${obs_ip}:${grpc_port}"

  wait_tcp "$obs_ip" "$grpc_port" || die "P4Runtime server is not reachable: ${uav_id} ${grpc_target}"

  entries_in_container=""
  if [[ "$INSTALL_CLUSTER_HEAD_ROUTES" -eq 1 ]]; then
    [[ -f "$CLUSTER_ENTRIES_HELPER_ABS" ]] || die "cluster-head entry helper not found: $CLUSTER_ENTRIES_HELPER_ABS"
    entries_abs="${MESH_DIR}/p4/build/p4runtime_entries/${uav_id}.json"
    mkdir -p "$(dirname "$entries_abs")"
    "$PYTHON_BIN" "$CLUSTER_ENTRIES_HELPER_ABS" \
      --topology "$TOPOLOGY_FILE" \
      --target-id "$uav_id" \
      --output "$entries_abs" \
      --routing-mode "$ROUTING_MODE" \
      --cluster-heads "$CLUSTER_HEADS" \
      --gs-app-if "$GS_APP_IF"
    entries_rel="$(repo_rel_path "$entries_abs")"
    entries_in_container="/workspace/ucs/scripts/${entries_rel}"
  fi

  vlog "loading ${uav_id}: kind=${target_kind} container=${container} device=${device_id} grpc=${grpc_target}"
  docker run --rm \
    --network host \
    -v "${SCRIPTS_ROOT}:/workspace/ucs/scripts:ro" \
    --entrypoint bash \
    "$P4RUNTIME_IMAGE" \
    -lc '
set -Eeuo pipefail
source /p4runtime-sh/venv/bin/activate
extra=()
if [[ "${6:-0}" == "1" ]]; then
  extra+=(--verbose)
fi
if [[ -n "${7:-}" ]]; then
  extra+=(--entries-json "$7")
fi
python3 "$1" \
  --device-id "$2" \
  --grpc-addr "$3" \
  --p4info "$4" \
  --bmv2-json "$5" \
  "${extra[@]}"
' _ \
    "$LOADER_IN_CONTAINER" \
    "$device_id" \
    "$grpc_target" \
    "$P4INFO_IN_CONTAINER" \
    "$BMV2_JSON_IN_CONTAINER" \
    "$VERBOSE" \
    "$entries_in_container"

  log "loaded ${uav_id}: device=${device_id} grpc=${grpc_target}"
}

log "pipeline artifacts:"
log "  json=${BMV2_JSON_ABS}"
log "  p4info=${P4INFO_ABS}"
if [[ "$INSTALL_CLUSTER_HEAD_ROUTES" -eq 1 ]]; then
  log "route entries mode=${ROUTING_MODE:-topology} gs-app-if=${GS_APP_IF}"
fi
log "loading via observation network using ${P4RUNTIME_IMAGE}"

for ((i=0; i<TARGET_COUNT; ++i)); do
  eval "target_id=\${TARGET_ID_${i}}"
  eval "target_container=\${TARGET_CONTAINER_${i}}"
  eval "target_device_id=\${TARGET_DEVICE_ID_${i}}"
  eval "target_grpc_addr=\${TARGET_GRPC_ADDR_${i}}"
  eval "target_kind=\${TARGET_KIND_${i}}"
  load_one "$target_id" "$target_container" "$target_device_id" "$target_grpc_addr" "$target_kind"
done

log "done"
