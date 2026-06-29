#!/usr/bin/env bash

# Common path defaults for the UCS BMv2 mesh scripts.
# Source this file from launchers; override any value from the environment when
# the server layout differs from the local development tree.

ENV_DEFAULTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if [[ -z "${UCS_MESH_DIR:-}" ]]; then
  if [[ -d "${ENV_DEFAULTS_DIR}/../topology" || -d "${ENV_DEFAULTS_DIR}/../topologies" ]]; then
    UCS_MESH_DIR="$(cd -- "${ENV_DEFAULTS_DIR}/.." && pwd)"
  else
    UCS_MESH_DIR="$ENV_DEFAULTS_DIR"
  fi
else
  UCS_MESH_DIR="$(cd -- "$UCS_MESH_DIR" && pwd)"
fi

UCS_MESH_PARENT="$(cd -- "${UCS_MESH_DIR}/.." && pwd)"

if [[ -z "${UCS_SCRIPTS_ROOT:-}" ]]; then
  if [[ "$(basename "${UCS_MESH_PARENT}")" == "scripts" ]]; then
    UCS_SCRIPTS_ROOT="${UCS_MESH_PARENT}"
  else
    UCS_SCRIPTS_ROOT="${UCS_MESH_DIR}"
  fi
else
  UCS_SCRIPTS_ROOT="$(cd -- "$UCS_SCRIPTS_ROOT" && pwd)"
fi

if [[ -z "${UCS_ROOT:-}" ]]; then
  if [[ "$(basename "${UCS_MESH_PARENT}")" == "scripts" ]]; then
    UCS_ROOT="$(cd -- "${UCS_MESH_PARENT}/.." && pwd)"
  else
    UCS_ROOT="${UCS_MESH_PARENT}"
  fi
else
  UCS_ROOT="$(cd -- "$UCS_ROOT" && pwd)"
fi

if [[ -z "${UCS_WORKSPACE_ROOT:-}" ]]; then
  UCS_WORKSPACE_ROOT="$(cd -- "${UCS_ROOT}/.." && pwd)"
else
  UCS_WORKSPACE_ROOT="$(cd -- "$UCS_WORKSPACE_ROOT" && pwd)"
fi

PX4_DIR="${PX4_DIR:-${UCS_PX4_DIR:-${UCS_WORKSPACE_ROOT}/PX4-Autopilot}}"
NS3_DIR="${NS3_DIR:-${UCS_NS3_DIR:-${UCS_WORKSPACE_ROOT}/ns-3}}"

GZ_ENV_SH="${GZ_ENV_SH:-${PX4_DIR}/build/px4_sitl_default/rootfs/gz_env.sh}"
PX4_GZ_MODELS="${PX4_GZ_MODELS:-${PX4_DIR}/Tools/simulation/gz/models}"
PX4_GZ_WORLDS="${PX4_GZ_WORLDS:-${PX4_DIR}/Tools/simulation/gz/worlds}"

UCS_VENV_DIR="${UCS_VENV_DIR:-${UCS_ROOT}/.venv}"

resolve_ucs_python_bin() {
  local candidate

  if [[ -n "${PYTHON_BIN:-}" ]]; then
    if [[ -x "$PYTHON_BIN" ]]; then
      printf '%s\n' "$PYTHON_BIN"
      return 0
    fi
    if command -v "$PYTHON_BIN" >/dev/null 2>&1; then
      command -v "$PYTHON_BIN"
      return 0
    fi
    echo "[env_defaults][ERR] PYTHON_BIN is set but not executable or resolvable: $PYTHON_BIN" >&2
    return 1
  fi

  for candidate in \
    "${UCS_VENV_DIR}/bin/python" \
    "${UCS_MESH_DIR}/.venv/bin/python" \
    python3; do
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
    if command -v "$candidate" >/dev/null 2>&1; then
      command -v "$candidate"
      return 0
    fi
  done

  echo "[env_defaults][ERR] no Python interpreter found; create ${UCS_VENV_DIR} or set PYTHON_BIN" >&2
  return 1
}

PYTHON_BIN="$(resolve_ucs_python_bin)"

UCS_UAV_BASE_IMAGE="${UCS_UAV_BASE_IMAGE:-ucs-uav-base-gz:20260625}"
UCS_MESH_BMV2_IMAGE="${UCS_MESH_BMV2_IMAGE:-ucs-uav-base-gz-bmv2:20260625}"
UCS_GAZEBO_IMAGE="${UCS_GAZEBO_IMAGE:-ucs-gazebo-runtime:20260625}"
UCS_MESH_P4RUNTIME_IMAGE="${UCS_MESH_P4RUNTIME_IMAGE:-ucs-p4runtime-sh:20260625}"
UCS_P4C_IMAGE="${UCS_P4C_IMAGE:-ucs-p4c:20260625}"
UCS_BMV2_RUNTIME_IMAGE="${UCS_BMV2_RUNTIME_IMAGE:-ucs-bmv2-runtime:20260625}"
UCS_P4_COMPILER_IMAGE="${UCS_P4_COMPILER_IMAGE:-ucs-p4-compiler:20260625}"
UCS_GZ_HELPER_BACKEND="${UCS_GZ_HELPER_BACKEND:-auto}"
UCS_GZ_HELPER_IMAGE="${UCS_GZ_HELPER_IMAGE:-$UCS_GAZEBO_IMAGE}"
UCS_GZ_HELPER_DOCKER_GPU="${UCS_GZ_HELPER_DOCKER_GPU:-${UCS_GAZEBO_DOCKER_GPU:-0}}"
UCS_DOCKER_GPU_MODE="${UCS_DOCKER_GPU_MODE:-auto}"

ucs_docker_nvidia_runtime_available() {
  command -v docker >/dev/null 2>&1 || return 1
  docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -q '"nvidia"'
}

ucs_docker_gpu_args() {
  local caps="${1:-compute,utility,graphics,video}"
  local mode="${UCS_DOCKER_GPU_MODE:-auto}"
  local visible="${NVIDIA_VISIBLE_DEVICES:-all}"

  case "$mode" in
    runtime)
      printf '%s\n' \
        "--runtime" "nvidia" \
        "-e" "NVIDIA_VISIBLE_DEVICES=${visible}" \
        "-e" "NVIDIA_DRIVER_CAPABILITIES=${caps}"
      ;;
    gpus)
      printf '%s\n' \
        "--gpus" "all" \
        "-e" "NVIDIA_DRIVER_CAPABILITIES=${caps}"
      ;;
    auto|"")
      if ucs_docker_nvidia_runtime_available; then
        UCS_DOCKER_GPU_MODE=runtime ucs_docker_gpu_args "$caps"
      else
        UCS_DOCKER_GPU_MODE=gpus ucs_docker_gpu_args "$caps"
      fi
      ;;
    *)
      echo "[env_defaults][ERR] unsupported UCS_DOCKER_GPU_MODE=${mode}; use auto, gpus, or runtime" >&2
      return 1
      ;;
  esac
}

ucs_cpu_count() {
  nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || printf '1\n'
}

ucs_cpu_affinity_enabled() {
  local mode="${UCS_MESH_CPU_AFFINITY:-auto}"
  case "$mode" in
    0|false|False|FALSE|no|No|NO|off|Off|OFF)
      return 1
      ;;
    1|true|True|TRUE|yes|Yes|YES|on|On|ON)
      command -v taskset >/dev/null 2>&1
      return $?
      ;;
    auto|"")
      command -v taskset >/dev/null 2>&1 || return 1
      [[ "$(ucs_cpu_count)" -ge 64 ]]
      ;;
    *)
      echo "[env_defaults][ERR] unsupported UCS_MESH_CPU_AFFINITY=${mode}" >&2
      return 1
      ;;
  esac
}

ucs_cpu_affinity_forced_off() {
  local mode="${UCS_MESH_CPU_AFFINITY:-auto}"
  case "$mode" in
    0|false|False|FALSE|no|No|NO|off|Off|OFF)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

ucs_default_uav_cpuset_64() {
  local idx="$1"
  case "$idx" in
    1|01) printf '%s\n' "20-21,52-53" ;;
    2|02) printf '%s\n' "22-23,54-55" ;;
    3|03) printf '%s\n' "24-25,56-57" ;;
    4|04) printf '%s\n' "26-27,58-59" ;;
    5|05) printf '%s\n' "28-29,60-61" ;;
    6|06) printf '%s\n' "30-31,62-63" ;;
    *) printf '%s\n' "20-31,52-63" ;;
  esac
}

ucs_default_uav_cpuset_32() {
  local idx="$1"
  case "$idx" in
    1|01) printf '%s\n' "16-17" ;;
    2|02) printf '%s\n' "18-19" ;;
    3|03) printf '%s\n' "20-21" ;;
    4|04) printf '%s\n' "22-23" ;;
    5|05) printf '%s\n' "24-25" ;;
    6|06) printf '%s\n' "26-27" ;;
    *) printf '%s\n' "16-31" ;;
  esac
}

ucs_default_cpuset() {
  local role="$1"
  local idx="${2:-}"
  local cpus
  cpus="$(ucs_cpu_count)"

  if [[ "$cpus" -ge 64 ]]; then
    case "$role" in
      GAZEBO) printf '%s\n' "${UCS_CPU_GAZEBO_SET:-0-11,32-43}" ;;
      NS3) printf '%s\n' "${UCS_CPU_NS3_SET:-12-13,44-45}" ;;
      GS_BMV2) printf '%s\n' "${UCS_CPU_GS_BMV2_SET:-14-15,46-47}" ;;
      VIDEO) printf '%s\n' "${UCS_CPU_VIDEO_SET:-16-19,48-51}" ;;
      METRICS) printf '%s\n' "${UCS_CPU_METRICS_SET:-18-19,50-51}" ;;
      DASHBOARD) printf '%s\n' "${UCS_CPU_DASHBOARD_SET:-18,50}" ;;
      CONTROL) printf '%s\n' "${UCS_CPU_CONTROL_SET:-$(ucs_default_uav_cpuset_64 "$idx")}" ;;
      UAV|UAV_BMV2|PX4) printf '%s\n' "${UCS_CPU_UAV_SET:-$(ucs_default_uav_cpuset_64 "$idx")}" ;;
      *) return 1 ;;
    esac
    return 0
  fi

  if [[ "$cpus" -ge 32 ]]; then
    case "$role" in
      GAZEBO) printf '%s\n' "${UCS_CPU_GAZEBO_SET:-0-7}" ;;
      NS3) printf '%s\n' "${UCS_CPU_NS3_SET:-8-9}" ;;
      GS_BMV2) printf '%s\n' "${UCS_CPU_GS_BMV2_SET:-10-11}" ;;
      VIDEO) printf '%s\n' "${UCS_CPU_VIDEO_SET:-12-15}" ;;
      METRICS) printf '%s\n' "${UCS_CPU_METRICS_SET:-14-15}" ;;
      DASHBOARD) printf '%s\n' "${UCS_CPU_DASHBOARD_SET:-14}" ;;
      CONTROL) printf '%s\n' "${UCS_CPU_CONTROL_SET:-$(ucs_default_uav_cpuset_32 "$idx")}" ;;
      UAV|UAV_BMV2|PX4) printf '%s\n' "${UCS_CPU_UAV_SET:-$(ucs_default_uav_cpuset_32 "$idx")}" ;;
      *) return 1 ;;
    esac
    return 0
  fi

  return 1
}

ucs_cpu_set() {
  local role="$1"
  local idx="${2:-}"
  local role_var="UCS_CPU_${role}_SET"
  local idx_var=""
  local idx_norm=""

  ucs_cpu_affinity_forced_off && return 1

  if [[ "$role" == "UAV" || "$role" == "UAV_BMV2" || "$role" == "PX4" || "$role" == "CONTROL" ]]; then
    if [[ "$idx" =~ ^[0-9]+$ ]]; then
      idx_norm="$(printf '%02d' "$((10#$idx))")"
    else
      idx_norm="$idx"
    fi
    idx_var="UCS_CPU_UAV${idx_norm}_SET"
    if [[ -n "$idx_var" && -n "${!idx_var:-}" ]]; then
      printf '%s\n' "${!idx_var}"
      return 0
    fi
  fi

  if [[ -n "${!role_var:-}" ]]; then
    printf '%s\n' "${!role_var}"
    return 0
  fi

  ucs_cpu_affinity_enabled || return 1
  ucs_default_cpuset "$role" "$idx"
}

ucs_maybe_taskset() {
  local role="$1"
  local idx="${2:-}"
  shift 2 || true
  local cpuset=""
  cpuset="$(ucs_cpu_set "$role" "$idx" 2>/dev/null || true)"
  if [[ -n "$cpuset" && -n "${1:-}" ]]; then
    taskset -c "$cpuset" "$@"
  else
    "$@"
  fi
}

ucs_docker_cpuset_args() {
  local role="$1"
  local idx="${2:-}"
  local cpuset=""
  cpuset="$(ucs_cpu_set "$role" "$idx" 2>/dev/null || true)"
  if [[ -n "$cpuset" ]]; then
    printf '%s\n' "--cpuset-cpus" "$cpuset"
  fi
}

ucs_docker_update_cpuset() {
  local container="$1"
  local role="$2"
  local idx="${3:-}"
  local cpuset=""
  cpuset="$(ucs_cpu_set "$role" "$idx" 2>/dev/null || true)"
  [[ -n "$cpuset" ]] || return 0
  docker update --cpuset-cpus "$cpuset" "$container" >/dev/null
}

ucs_docker_wait_update_cpuset() {
  local container="$1"
  local role="$2"
  local idx="${3:-}"
  local attempts="${4:-30}"
  local delay="${5:-0.2}"
  local cpuset=""
  local state=""
  local i

  cpuset="$(ucs_cpu_set "$role" "$idx" 2>/dev/null || true)"
  [[ -n "$cpuset" ]] || return 0

  for ((i = 1; i <= attempts; ++i)); do
    state="$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null || true)"
    if [[ "$state" == "true" ]]; then
      docker update --cpuset-cpus "$cpuset" "$container" >/dev/null
      return 0
    fi
    sleep "$delay"
  done
  return 1
}

export UCS_MESH_DIR UCS_SCRIPTS_ROOT UCS_ROOT UCS_WORKSPACE_ROOT
export PX4_DIR NS3_DIR GZ_ENV_SH PX4_GZ_MODELS PX4_GZ_WORLDS
export UCS_VENV_DIR PYTHON_BIN
export UCS_UAV_BASE_IMAGE UCS_MESH_BMV2_IMAGE UCS_GAZEBO_IMAGE
export UCS_MESH_P4RUNTIME_IMAGE UCS_P4C_IMAGE UCS_BMV2_RUNTIME_IMAGE UCS_P4_COMPILER_IMAGE
export UCS_GZ_HELPER_BACKEND UCS_GZ_HELPER_IMAGE UCS_GZ_HELPER_DOCKER_GPU
export UCS_DOCKER_GPU_MODE
