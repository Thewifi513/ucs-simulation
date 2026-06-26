#!/usr/bin/env bash
set -Eeuo pipefail

# UCS BMv2 mesh migration checker/deployer for shared Ubuntu 20 GPU servers.
#
# The script is intentionally staged. "check" is read-mostly; "deploy" only
# prepares runtime prerequisites and dry-runs launch parsing. It does not start
# the full fleet.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MESH_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

# shellcheck disable=SC1091
source "${MESH_DIR}/fleet/env_defaults.sh"
if [[ -f "${SCRIPT_DIR}/docker_images.env" ]]; then
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/docker_images.env"
fi

COMMAND="${1:-check}"
if [[ $# -gt 0 ]]; then
  shift
fi

TOPOLOGY_FILE="${TOPOLOGY_FILE:-${MESH_DIR}/topology/wifi_adhoc_matrix_2x3_6uav.json}"
IMAGE_TAR="${IMAGE_TAR:-ucs-runtime-images-${UCS_IMAGE_SET_DATE:-20260625}.tar}"
CHECK_PORTS=0
STRICT=0
SKIP_IMAGES=0
SKIP_VENV=0
SKIP_NS3=0
INCLUDE_BUILD_IMAGES="${INCLUDE_BUILD_IMAGES:-0}"
VENV_DIR="${VENV_DIR:-${UCS_VENV_DIR}}"

usage() {
  cat <<EOF
Usage: $(basename "$0") <command> [options]

Commands:
  check          Validate repo assets, platform Python, preflight, and dry-runs.
  prepare-venv   Create/update the platform venv and verify required imports.
  export-images Export fixed Docker runtime images to a tarball.
  load-images   Verify sha256 and docker-load the fixed runtime images.
  install-ns3   Install/build the ns-3 scratch source.
  dry-run       Run no-side-effect launch parsing checks.
  deploy        Server-side sequence: prepare venv, load images, install ns-3,
                preflight, and dry-run. It does not start the full fleet.

Options:
  --topology FILE      Topology JSON. Default: ${TOPOLOGY_FILE}
  --px4-dir DIR        PX4-Autopilot path. Default: ${PX4_DIR}
  --ns3-dir DIR        ns-3 path. Default: ${NS3_DIR}
  --python-bin FILE    Platform Python. Default: ${PYTHON_BIN}
  --venv-dir DIR       Venv directory for prepare-venv. Default: ${VENV_DIR}
  --image-tar FILE     Docker image tar. Default: ${IMAGE_TAR}
  --with-ports         Include port conflict checks in preflight.
  --strict             Treat preflight warnings as failure.
  --no-images          Skip Docker image checks/load in check/deploy.
  --skip-venv          Skip prepare-venv in deploy.
  --skip-ns3           Skip install-ns3 in deploy.
  --include-build-images
                      Include build/dev images when exporting.
  -h, --help           Show this help.

Typical server flow:
  export PX4_DIR=/path/to/PX4-Autopilot
  export NS3_DIR=/path/to/ns-3
  export UCS_GZ_HELPER_BACKEND=docker
  export UCS_GZ_HELPER_DOCKER_GPU=1
  ./deploy/ubuntu20_server_check_deploy.sh deploy --image-tar ./ucs-runtime-images-20260625.tar
  export PYTHON_BIN=/path/to/ucs/.venv/bin/python
  ./deploy/ubuntu20_server_check_deploy.sh check --strict
EOF
}

log() {
  echo "[ucs-deploy] $*"
}

warn() {
  echo "[ucs-deploy][WARN] $*" >&2
}

die() {
  echo "[ucs-deploy][ERR] $*" >&2
  exit 1
}

run() {
  log "+ $*"
  "$@"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

require_file() {
  local path="$1"
  [[ -f "$path" ]] || die "missing required file: $path"
}

require_dir() {
  local path="$1"
  [[ -d "$path" ]] || die "missing required directory: $path"
}

normalize_path() {
  "$PYTHON_BIN" -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$1"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --topology)
      [[ $# -ge 2 ]] || die "--topology requires a file"
      TOPOLOGY_FILE="$2"
      shift 2
      ;;
    --px4-dir)
      [[ $# -ge 2 ]] || die "--px4-dir requires a directory"
      PX4_DIR="$2"
      GZ_ENV_SH="${PX4_DIR}/build/px4_sitl_default/rootfs/gz_env.sh"
      PX4_GZ_MODELS="${PX4_DIR}/Tools/simulation/gz/models"
      PX4_GZ_WORLDS="${PX4_DIR}/Tools/simulation/gz/worlds"
      shift 2
      ;;
    --ns3-dir)
      [[ $# -ge 2 ]] || die "--ns3-dir requires a directory"
      NS3_DIR="$2"
      shift 2
      ;;
    --python-bin)
      [[ $# -ge 2 ]] || die "--python-bin requires a file"
      PYTHON_BIN="$2"
      shift 2
      ;;
    --venv-dir)
      [[ $# -ge 2 ]] || die "--venv-dir requires a directory"
      VENV_DIR="$2"
      shift 2
      ;;
    --image-tar)
      [[ $# -ge 2 ]] || die "--image-tar requires a file"
      IMAGE_TAR="$2"
      shift 2
      ;;
    --with-ports)
      CHECK_PORTS=1
      shift
      ;;
    --strict)
      STRICT=1
      shift
      ;;
    --no-images)
      SKIP_IMAGES=1
      shift
      ;;
    --skip-venv)
      SKIP_VENV=1
      shift
      ;;
    --skip-ns3)
      SKIP_NS3=1
      shift
      ;;
    --include-build-images)
      INCLUDE_BUILD_IMAGES=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

export PX4_DIR NS3_DIR GZ_ENV_SH PX4_GZ_MODELS PX4_GZ_WORLDS PYTHON_BIN

preflight_args() {
  local args=(
    --topology "$TOPOLOGY_FILE"
    --px4-dir "$PX4_DIR"
    --ns3-dir "$NS3_DIR"
    --gz-env "$GZ_ENV_SH"
  )
  if [[ "$CHECK_PORTS" -eq 0 ]]; then
    args+=(--no-ports)
  fi
  if [[ "$SKIP_IMAGES" -eq 1 ]]; then
    args+=(--no-images)
  fi
  if [[ "$STRICT" -eq 1 ]]; then
    args+=(--strict)
  fi
  printf '%s\0' "${args[@]}"
}

assert_repo_assets() {
  log "checking repository assets"
  require_file "$TOPOLOGY_FILE"
  require_file "${MESH_DIR}/fleet/fleet_up.sh"
  require_file "${MESH_DIR}/fleet/fleet_down.sh"
  require_file "${MESH_DIR}/fleet/env_defaults.sh"
  require_file "${MESH_DIR}/control/control_up.sh"
  require_file "${MESH_DIR}/control/control_down.sh"
  require_file "${MESH_DIR}/control/control_core.py"
  require_file "${MESH_DIR}/control/remote_web.py"
  require_file "${MESH_DIR}/control/mavsdk_server_musl_x86_64"
  require_file "${MESH_DIR}/px4_gazebo/world_up.sh"
  require_file "${MESH_DIR}/px4_gazebo/px4_up.sh"
  require_file "${MESH_DIR}/px4_gazebo/worlds/ucs_obstacle_field.sdf"
  require_file "${MESH_DIR}/network/net_up.sh"
  require_file "${MESH_DIR}/network/metrics_up.sh"
  require_file "${MESH_DIR}/network/metrics_worker.py"
  require_file "${MESH_DIR}/network/ns3/ucs_fleet_l2_mesh_topology.cc"
  require_file "${MESH_DIR}/frontend/dashboard_up.sh"
  require_file "${MESH_DIR}/frontend/dashboard_server.py"
  require_file "${MESH_DIR}/frontend/index.html"
  require_file "${MESH_DIR}/video/run_rtp_camera_flow.sh"
  require_file "${MESH_DIR}/video/rtp_camera_bridge.py"
  require_file "${MESH_DIR}/p4/ucs_edge_cluster_route.p4"
  require_file "${MESH_DIR}/p4/build/ucs_edge_cluster_route.json"
  require_file "${MESH_DIR}/p4/build/ucs_edge_cluster_route.p4info.txt"
  require_file "${MESH_DIR}/fleet/icons/ucs_fleet_icon_up.png"
  require_file "${MESH_DIR}/fleet/icons/ucs_fleet_icon_down.png"
  [[ -x "${MESH_DIR}/control/mavsdk_server_musl_x86_64" ]] || die "mavsdk_server is not executable"
}

check_platform_python() {
  log "checking platform Python: ${PYTHON_BIN}"
  [[ -x "$PYTHON_BIN" ]] || die "PYTHON_BIN is not executable: ${PYTHON_BIN}"
  "$PYTHON_BIN" - <<'PY'
import sys
modules = ["mavsdk", "websockets"]
missing = []
for module in modules:
    try:
        __import__(module)
    except Exception as exc:
        missing.append(f"{module}: {exc}")
if missing:
    print("[ucs-deploy][ERR] platform Python import check failed:", file=sys.stderr)
    for item in missing:
        print(f"  - {item}", file=sys.stderr)
    raise SystemExit(1)
if sys.prefix == sys.base_prefix:
    print("[ucs-deploy][WARN] platform Python is not a virtual environment", file=sys.stderr)
PY
  log "Gazebo transport/GStreamer helper dependencies are checked by ubuntu20_server_preflight.sh"
}

prepare_venv() {
  need_cmd python3
  log "preparing platform venv: ${VENV_DIR}"
  if [[ ! -x "${VENV_DIR}/bin/python" ]]; then
    run python3 -m venv --system-site-packages "$VENV_DIR"
  fi
  PYTHON_BIN="${VENV_DIR}/bin/python"
  export PYTHON_BIN
  run "$PYTHON_BIN" -m pip install --upgrade pip
  run "$PYTHON_BIN" -m pip install -r "${MESH_DIR}/requirements.txt"
  check_platform_python
  log "use this in future shells:"
  log "  export PYTHON_BIN=${PYTHON_BIN}"
}

run_preflight() {
  local args=()
  while IFS= read -r -d '' item; do
    args+=("$item")
  done < <(preflight_args)
  log "running Ubuntu 20 server preflight"
  run "${SCRIPT_DIR}/ubuntu20_server_preflight.sh" "${args[@]}"
}

export_images() {
  need_cmd docker
  if [[ "$INCLUDE_BUILD_IMAGES" -eq 1 ]]; then
    log "+ INCLUDE_BUILD_IMAGES=1 ${SCRIPT_DIR}/export_docker_images.sh ${IMAGE_TAR}"
    INCLUDE_BUILD_IMAGES=1 "${SCRIPT_DIR}/export_docker_images.sh" "$IMAGE_TAR"
  else
    run "${SCRIPT_DIR}/export_docker_images.sh" "$IMAGE_TAR"
  fi
}

load_images() {
  [[ "$SKIP_IMAGES" -eq 0 ]] || {
    warn "skipping Docker image load by --no-images"
    return 0
  }
  need_cmd docker
  require_file "$IMAGE_TAR"
  require_file "${IMAGE_TAR}.sha256"
  run sha256sum -c "${IMAGE_TAR}.sha256"
  run docker load -i "$IMAGE_TAR"
  for image in ${UCS_RUNTIME_IMAGE_LIST:-}; do
    run docker image inspect "$image" >/dev/null
  done
}

install_ns3() {
  require_dir "$NS3_DIR"
  require_file "${NS3_DIR}/ns3"
  require_file "${MESH_DIR}/network/ns3/ucs_fleet_l2_mesh_topology.cc"
  local dst="${NS3_DIR}/scratch/ucs_fleet_l2_mesh_topology.cc"
  if [[ ! -f "$dst" ]] || ! cmp -s "${MESH_DIR}/network/ns3/ucs_fleet_l2_mesh_topology.cc" "$dst"; then
    log "installing ns-3 scratch source: ${dst}"
    cp "${MESH_DIR}/network/ns3/ucs_fleet_l2_mesh_topology.cc" "$dst"
  else
    log "ns-3 scratch source already current: ${dst}"
  fi
  run "${NS3_DIR}/ns3" build scratch/ucs_fleet_l2_mesh_topology
}

run_dry_run_checks() {
  log "running no-side-effect platform dry-runs"
  run "${MESH_DIR}/fleet/uav_profile.sh" --idx 6 >/dev/null
  run "${MESH_DIR}/network/net_up.sh" --dry-run --verbose >/dev/null
  run "${MESH_DIR}/network/metrics_up.sh" --dry-run >/dev/null
  run "${MESH_DIR}/video/run_rtp_camera_flow.sh" --uav uav04 --duration-sec 5 --dry-run >/dev/null
  run "${MESH_DIR}/p4/apply_cluster_heads.sh" --dry-run >/dev/null
  run "${MESH_DIR}/debug/check_gimbal_payload.sh" >/dev/null
}

run_check() {
  TOPOLOGY_FILE="$(normalize_path "$TOPOLOGY_FILE")"
  assert_repo_assets
  check_platform_python
  run_preflight
  run_dry_run_checks
  log "check complete"
}

run_deploy() {
  TOPOLOGY_FILE="$(normalize_path "$TOPOLOGY_FILE")"
  assert_repo_assets
  if [[ "$SKIP_VENV" -eq 0 ]]; then
    prepare_venv
  else
    check_platform_python
  fi
  load_images
  if [[ "$SKIP_NS3" -eq 0 ]]; then
    install_ns3
  else
    warn "skipping ns-3 install/build by --skip-ns3"
  fi
  run_preflight
  run_dry_run_checks
  log "deploy preparation complete; full stack is not started by this script"
}

case "$COMMAND" in
  check)
    run_check
    ;;
  prepare-venv)
    prepare_venv
    ;;
  export-images)
    export_images
    ;;
  load-images)
    load_images
    ;;
  install-ns3)
    install_ns3
    ;;
  dry-run)
    TOPOLOGY_FILE="$(normalize_path "$TOPOLOGY_FILE")"
    run_dry_run_checks
    ;;
  deploy)
    run_deploy
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    die "unknown command: ${COMMAND}"
    ;;
esac
