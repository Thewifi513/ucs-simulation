#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MESH_DIR="$(cd -- "${SCRIPT_DIR}/../../.." && pwd)"
# shellcheck disable=SC1091
source "${MESH_DIR}/fleet/env_defaults.sh"

BASE_IMAGE="${UCS_GAZEBO_BASE_IMAGE:-$UCS_UAV_BASE_IMAGE}"
IMAGE="${UCS_GAZEBO_IMAGE:-ucs-gazebo-runtime:20260625}"

if ! docker image inspect "$BASE_IMAGE" >/dev/null 2>&1; then
  echo "[gazebo-image][ERR] base image not found: $BASE_IMAGE" >&2
  echo "[gazebo-image][ERR] set UCS_GAZEBO_BASE_IMAGE or build the UAV Gazebo image first" >&2
  exit 1
fi

echo "[gazebo-image] base  = $BASE_IMAGE"
echo "[gazebo-image] image = $IMAGE"

docker build \
  --build-arg "BASE_IMAGE=$BASE_IMAGE" \
  -t "$IMAGE" \
  "$MESH_DIR/deploy/docker/gazebo-runtime"
