#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MESH_DIR="$(cd -- "${SCRIPT_DIR}/../../.." && pwd)"
# shellcheck disable=SC1091
source "${MESH_DIR}/fleet/env_defaults.sh"
IMAGE_DIR="${MESH_DIR}/deploy/docker/uav-bmv2"

BASE_IMAGE="${BASE_IMAGE:-$UCS_UAV_BASE_IMAGE}"
BMV2_IMAGE="${BMV2_IMAGE:-$UCS_MESH_BMV2_IMAGE}"
BMV2_RUNTIME_IMAGE="${BMV2_RUNTIME_IMAGE:-$UCS_BMV2_RUNTIME_IMAGE}"
DOCKER_BUILD_NETWORK="${DOCKER_BUILD_NETWORK:-host}"
DOCKER_BUILDKIT="${DOCKER_BUILDKIT:-0}"

echo "[I] building UAV BMv2 image"
echo "    base=${BASE_IMAGE}"
echo "    image=${BMV2_IMAGE}"
echo "    bmv2_runtime=${BMV2_RUNTIME_IMAGE}"
echo "    network=${DOCKER_BUILD_NETWORK}"
echo "    buildkit=${DOCKER_BUILDKIT}"

DOCKER_BUILDKIT="${DOCKER_BUILDKIT}" docker build \
  --network "${DOCKER_BUILD_NETWORK}" \
  --build-arg "BASE_IMAGE=${BASE_IMAGE}" \
  --build-arg "BMV2_RUNTIME_IMAGE=${BMV2_RUNTIME_IMAGE}" \
  -t "${BMV2_IMAGE}" \
  -f "${IMAGE_DIR}/Dockerfile" \
  "${IMAGE_DIR}"

echo "[I] verifying image tools"
docker run --rm --entrypoint bash "${BMV2_IMAGE}" -lc '
set -Eeuo pipefail
command -v simple_switch_grpc
simple_switch_grpc --version
LD_LIBRARY_PATH="/usr/local/lib:/opt/bmv2/compat-lib:${LD_LIBRARY_PATH:-}" \
  ldd /usr/local/libexec/bmv2/simple_switch_grpc | awk "/not found/{bad=1; print} END{exit bad ? 1 : 0}"
'

echo "[OK] built ${BMV2_IMAGE}"
