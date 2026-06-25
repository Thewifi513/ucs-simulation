#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MESH_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${MESH_DIR}/fleet/env_defaults.sh"
IMAGE_DIR="${MESH_DIR}/deploy/docker/p4-compiler"

P4_PROGRAM="${P4_PROGRAM:-${MESH_DIR}/p4/ucs_edge_cluster_route.p4}"
OUTPUT_DIR="${OUTPUT_DIR:-${MESH_DIR}/p4/build}"
P4_COMPILER_IMAGE="${P4_COMPILER_IMAGE:-$UCS_P4_COMPILER_IMAGE}"
P4C_IMAGE="${P4C_IMAGE:-$UCS_P4C_IMAGE}"
DOCKER_BUILD_NETWORK="${DOCKER_BUILD_NETWORK:-host}"
DOCKER_BUILDKIT="${DOCKER_BUILDKIT:-0}"
BUILD_IMAGE=1
VERBOSE=0

usage() {
  cat <<'USAGE'
Usage:
  compile.sh [options]

Options:
  --program PATH       P4 source path. Default: ./p4/ucs_edge_cluster_route.p4
  --output-dir DIR     Output directory. Default: ./p4/build
  --image IMAGE        Compiler image tag. Default: ucs-p4-compiler:20260625
  --base-image IMAGE   Base p4c image. Default: ucs-p4c:20260625
  --no-build           Reuse an existing compiler image
  --verbose            Print tool versions and compile command
  -h, --help           Show this help

Environment overrides:
  P4_PROGRAM, OUTPUT_DIR, P4_COMPILER_IMAGE, P4C_IMAGE,
  DOCKER_BUILD_NETWORK, DOCKER_BUILDKIT
USAGE
}

log() {
  echo "[p4-compile] $*"
}

die() {
  echo "[p4-compile][ERR] $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --program)
      P4_PROGRAM="${2:-}"
      [[ -n "${P4_PROGRAM}" ]] || die "--program requires a path"
      shift 2
      ;;
    --output-dir)
      OUTPUT_DIR="${2:-}"
      [[ -n "${OUTPUT_DIR}" ]] || die "--output-dir requires a path"
      shift 2
      ;;
    --image)
      P4_COMPILER_IMAGE="${2:-}"
      [[ -n "${P4_COMPILER_IMAGE}" ]] || die "--image requires a tag"
      shift 2
      ;;
    --base-image)
      P4C_IMAGE="${2:-}"
      [[ -n "${P4C_IMAGE}" ]] || die "--base-image requires a tag"
      shift 2
      ;;
    --no-build)
      BUILD_IMAGE=0
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

command -v docker >/dev/null 2>&1 || die "docker is required"
command -v realpath >/dev/null 2>&1 || die "realpath is required"

[[ -f "${P4_PROGRAM}" ]] || die "P4 program not found: ${P4_PROGRAM}"
mkdir -p "${OUTPUT_DIR}"

REPO_ABS="$(realpath "${MESH_DIR}")"
PROGRAM_ABS="$(realpath "${P4_PROGRAM}")"
OUTPUT_ABS="$(realpath "${OUTPUT_DIR}")"

case "${PROGRAM_ABS}" in
  "${REPO_ABS}"/*) PROGRAM_REL="${PROGRAM_ABS#${REPO_ABS}/}" ;;
  *) die "P4 program must be inside ${MESH_DIR}: ${P4_PROGRAM}" ;;
esac

case "${OUTPUT_ABS}" in
  "${REPO_ABS}"/*) OUTPUT_REL="${OUTPUT_ABS#${REPO_ABS}/}" ;;
  *) die "output directory must be inside ${MESH_DIR}: ${OUTPUT_DIR}" ;;
esac

PROGRAM_BASE="$(basename "${PROGRAM_ABS}")"
PROGRAM_STEM="${PROGRAM_BASE%.p4}"
JSON_REL="${OUTPUT_REL}/${PROGRAM_STEM}.json"
P4INFO_REL="${OUTPUT_REL}/${PROGRAM_STEM}.p4info.txt"

if [[ "${BUILD_IMAGE}" -eq 1 ]]; then
  log "building compiler image ${P4_COMPILER_IMAGE}"
  DOCKER_BUILDKIT="${DOCKER_BUILDKIT}" docker build \
    --network "${DOCKER_BUILD_NETWORK}" \
    --build-arg "P4C_IMAGE=${P4C_IMAGE}" \
    -t "${P4_COMPILER_IMAGE}" \
    -f "${IMAGE_DIR}/Dockerfile" \
    "${IMAGE_DIR}"
fi

if [[ "${VERBOSE}" -eq 1 ]]; then
  log "compiler image: ${P4_COMPILER_IMAGE}"
  log "base image:     ${P4C_IMAGE}"
  log "program:        ${PROGRAM_REL}"
  log "json:           ${JSON_REL}"
  log "p4info:         ${P4INFO_REL}"
  docker run --rm "${P4_COMPILER_IMAGE}" p4c-bm2-ss --version
fi

log "compiling ${PROGRAM_REL}"
docker run --rm \
  -u "$(id -u):$(id -g)" \
  -v "${REPO_ABS}:/workspace/ucs-simulation" \
  -w /workspace/ucs-simulation \
  "${P4_COMPILER_IMAGE}" \
  p4c-bm2-ss \
    --std p4-16 \
    --target bmv2 \
    --arch v1model \
    --p4runtime-files "${P4INFO_REL}" \
    -o "${JSON_REL}" \
    "${PROGRAM_REL}"

[[ -s "${OUTPUT_ABS}/${PROGRAM_STEM}.json" ]] || die "missing output: ${OUTPUT_ABS}/${PROGRAM_STEM}.json"
[[ -s "${OUTPUT_ABS}/${PROGRAM_STEM}.p4info.txt" ]] || die "missing output: ${OUTPUT_ABS}/${PROGRAM_STEM}.p4info.txt"

log "wrote ${OUTPUT_ABS}/${PROGRAM_STEM}.json"
log "wrote ${OUTPUT_ABS}/${PROGRAM_STEM}.p4info.txt"
log "done"
