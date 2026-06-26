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

export UCS_MESH_DIR UCS_SCRIPTS_ROOT UCS_ROOT UCS_WORKSPACE_ROOT
export PX4_DIR NS3_DIR GZ_ENV_SH PX4_GZ_MODELS PX4_GZ_WORLDS
export UCS_VENV_DIR PYTHON_BIN
export UCS_UAV_BASE_IMAGE UCS_MESH_BMV2_IMAGE UCS_GAZEBO_IMAGE
export UCS_MESH_P4RUNTIME_IMAGE UCS_P4C_IMAGE UCS_BMV2_RUNTIME_IMAGE UCS_P4_COMPILER_IMAGE
export UCS_GZ_HELPER_BACKEND UCS_GZ_HELPER_IMAGE UCS_GZ_HELPER_DOCKER_GPU
