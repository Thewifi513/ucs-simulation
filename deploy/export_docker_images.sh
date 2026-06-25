#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/docker_images.env"

OUT="${1:-ucs-runtime-images-${UCS_IMAGE_SET_DATE}.tar}"
INCLUDE_BUILD_IMAGES="${INCLUDE_BUILD_IMAGES:-0}"

images="$UCS_RUNTIME_IMAGE_LIST"
case "$INCLUDE_BUILD_IMAGES" in
  1|true|True|TRUE|yes|Yes|YES|on|On|ON)
    images="$images $UCS_BUILD_IMAGE_LIST"
    ;;
esac

for image in $images; do
  docker image inspect "$image" >/dev/null
done

echo "[docker-images] exporting: $images"
echo "[docker-images] output: ${OUT}"
docker save -o "$OUT" $images
sha256sum "$OUT" > "${OUT}.sha256"
echo "[docker-images] wrote: ${OUT}"
echo "[docker-images] wrote: ${OUT}.sha256"
