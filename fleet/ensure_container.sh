#!/usr/bin/env bash
set -Eeuo pipefail

# Ensure a mesh UAV container exists.
# 只负责“保证某个 UAV 容器存在”，不启动 PX4，不启动 ns-3，不启动 world。
#
# 用法：
#   ./fleet/ensure_container.sh
#   ./fleet/ensure_container.sh 2
#   ./fleet/ensure_container.sh --idx 2
#   ./fleet/ensure_container.sh --topology ./topology/wifi_adhoc_matrix_2x3_6uav.json --idx 2
#   ./fleet/ensure_container.sh --topology ./topology/wifi_adhoc_matrix_2x3_6uav.json --idx 2 --recreate
#
# 行为：
# - 容器不存在：按母版规格创建
# - 容器已存在：默认只打印摘要并退出
# - 加 --recreate：先删旧容器，再重建

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/env_defaults.sh"
MESH_DIR="$UCS_MESH_DIR"
PROFILE_SH="${SCRIPT_DIR}/uav_profile.sh"
DEFAULT_TOPOLOGY="${MESH_DIR}/topology/wifi_adhoc_matrix_2x3_6uav.json"

TOPOLOGY_FILE="${TOPOLOGY_FILE:-$DEFAULT_TOPOLOGY}"
IDX_INPUT="${IDX:-1}"
RECREATE=0

# ---- Base container spec (derived from the validated Gazebo/PX4 UAV image) ----
CONTAINER_IMAGE_EXPLICIT="${CONTAINER_IMAGE+x}"
CONTAINER_IMAGE="${CONTAINER_IMAGE:-$UCS_UAV_BASE_IMAGE}"
UCS_MESH_BMV2_IMAGE="${UCS_MESH_BMV2_IMAGE:-${BMV2_IMAGE:-ucs-uav-base-gz-bmv2:20260625}}"
CONTAINER_WORKDIR="${CONTAINER_WORKDIR:-/px4}"
CONTAINER_ENTRYPOINT_BIN="${CONTAINER_ENTRYPOINT_BIN:-/usr/bin/dumb-init}"

# Final process inside container after entrypoint:
# /usr/bin/dumb-init -- bash -lc "sleep infinity"
CONTAINER_CMD_SHELL="${CONTAINER_CMD_SHELL:-bash}"
CONTAINER_CMD_FLAG="${CONTAINER_CMD_FLAG:--lc}"
CONTAINER_CMD_STRING="${CONTAINER_CMD_STRING:-sleep infinity}"

# Compatibility envs inherited from the Gazebo/PX4 baseline
UAV_P_SIG="${UAV_P_SIG:-5600}"
UAV_P_STAT="${UAV_P_STAT:-5601}"
UAV_P_DATA="${UAV_P_DATA:-5602}"
CTRL_IP="${CTRL_IP:-192.168.100.10}"
DATA_PROTO="${DATA_PROTO:-udp}"
PX4_CMD="${PX4_CMD:-/px4/bin/px4 -d /px4/etc/init.d-posix/rcS}"
BIND_IF="${BIND_IF:-eth1}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [idx] [--idx N] [--topology FILE] [--recreate] [--help]

idx             Optional positional UAV index.
--idx N         Explicit UAV index.
--topology FILE JSON topology file.
--recreate      Remove existing container and recreate it.
--help          Show this help.

Examples:
  $(basename "$0")
  $(basename "$0") 2
  $(basename "$0") --idx 2
  $(basename "$0") --topology ./topology/wifi_adhoc_matrix_2x3_6uav.json --idx 2
  $(basename "$0") --topology ./topology/wifi_adhoc_matrix_2x3_6uav.json --idx 2 --recreate
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --topology)
      [[ $# -ge 2 ]] || { echo "[ERR] --topology requires a path"; exit 1; }
      TOPOLOGY_FILE="$2"
      shift 2
      ;;
    --idx)
      [[ $# -ge 2 ]] || { echo "[ERR] --idx requires a value"; exit 1; }
      IDX_INPUT="$2"
      shift 2
      ;;
    --recreate)
      RECREATE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      if [[ "$1" =~ ^[0-9]+$ ]]; then
        IDX_INPUT="$1"
        shift
      else
        echo "[ERR] Unknown argument: $1"
        usage
        exit 1
      fi
      ;;
  esac
done

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "[ERR] '$1' not found."; exit 1; }; }
need_cmd docker
need_cmd "$PYTHON_BIN"

[[ -f "$PROFILE_SH" ]] || { echo "[ERR] uav_profile.sh not found: $PROFILE_SH"; exit 1; }
[[ -f "$TOPOLOGY_FILE" ]] || { echo "[ERR] topology file not found: $TOPOLOGY_FILE"; exit 1; }

TOPOLOGY_FILE="$("$PYTHON_BIN" -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$TOPOLOGY_FILE")"

# Load instance profile from JSON
# shellcheck disable=SC1090
source "$PROFILE_SH" --topology "$TOPOLOGY_FILE" --idx "$IDX_INPUT"

PROGRAMMABLE_NET_EDGE_DATAPLANE="$(
"$PYTHON_BIN" - "$TOPOLOGY_FILE" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as f:
    topo = json.load(f)

prog = topo.get("programmable_net", {})
if not isinstance(prog, dict) or not prog.get("enabled", False):
    print("")
    raise SystemExit(0)

placement = str(prog.get("placement", ""))
target = str(prog.get("target", ""))
if placement == "in_uav_container_inline" and target == "bmv2_simple_switch_grpc":
    print("container_bmv2_inline")
else:
    print("")
PY
)"

REQUESTED_EDGE_DATAPLANE="${UCS_MESH_EDGE_DATAPLANE:-$PROGRAMMABLE_NET_EDGE_DATAPLANE}"
if [[ "$REQUESTED_EDGE_DATAPLANE" == "bmv2_uav_edge" ]]; then
  REQUESTED_EDGE_DATAPLANE="container_bmv2_inline"
fi

USE_BMV2_CONTAINER=0
if [[ "$REQUESTED_EDGE_DATAPLANE" == "container_bmv2_inline" ]]; then
  USE_BMV2_CONTAINER=1
  if [[ -z "$CONTAINER_IMAGE_EXPLICIT" ]]; then
    CONTAINER_IMAGE="$UCS_MESH_BMV2_IMAGE"
  fi
fi

echo "[I] ensure container for:"
echo "    TOPOLOGY_FILE=$TOPOLOGY_FILE"
echo "    SCENARIO_ID=$SCENARIO_ID"
echo "    IDX=$IDX"
echo "    UAV_NAME=$UAV_NAME"
echo "    UAV_CONTAINER=$UAV_CONTAINER"
echo "    PX4_INSTANCE=$PX4_INSTANCE"
echo "    PX4_MODEL_INSTANCE=$PX4_MODEL_INSTANCE"
echo "    QGC_TARGET=$QGC_TARGET"
echo "    EDGE_DATAPLANE=${REQUESTED_EDGE_DATAPLANE:-linux_bridge}"
echo "    BMV2_CONTAINER=$USE_BMV2_CONTAINER"

existing_id="$(docker ps -aq -f "name=^/${UAV_CONTAINER}$" || true)"

if [[ -n "$existing_id" && "$RECREATE" -eq 0 ]]; then
  echo "[I] container already exists: $UAV_CONTAINER"
  if [[ "$USE_BMV2_CONTAINER" -eq 1 ]]; then
    existing_image="$(docker inspect -f '{{.Config.Image}}' "$UAV_CONTAINER" 2>/dev/null || true)"
    if [[ -n "$existing_image" && "$existing_image" != "$CONTAINER_IMAGE" ]]; then
      echo "[ERR] BMv2 inline requested but existing container image is ${existing_image}, expected ${CONTAINER_IMAGE}" >&2
      echo "[ERR] build the BMv2 image, then recreate containers for this stage" >&2
      echo "[ERR]   ${MESH_DIR}/deploy/docker/uav-bmv2/build_image.sh" >&2
      echo "[ERR]   ${SCRIPT_DIR}/ensure_container.sh --topology $TOPOLOGY_FILE --idx $IDX --recreate" >&2
      exit 1
    fi
    existing_cap_add="$(docker inspect -f '{{json .HostConfig.CapAdd}}' "$UAV_CONTAINER" 2>/dev/null || true)"
    if [[ "$existing_cap_add" != *NET_ADMIN* || "$existing_cap_add" != *NET_RAW* ]]; then
      echo "[ERR] BMv2 inline requested but existing container lacks NET_ADMIN/NET_RAW: ${existing_cap_add:-null}" >&2
      echo "[ERR] recreate containers after building the BMv2 image so simple_switch_grpc can bind inline ports" >&2
      exit 1
    fi
  fi
  docker inspect -f '
Name={{.Name}}
Image={{.Config.Image}}
Entrypoint={{json .Config.Entrypoint}}
Cmd={{json .Config.Cmd}}
WorkingDir={{.Config.WorkingDir}}
NetworkMode={{.HostConfig.NetworkMode}}
PortBindings={{json .HostConfig.PortBindings}}
CapAdd={{json .HostConfig.CapAdd}}
Labels={{json .Config.Labels}}
' "$UAV_CONTAINER"
  exit 0
fi

if [[ -n "$existing_id" && "$RECREATE" -eq 1 ]]; then
  echo "[I] recreate requested: removing existing container $UAV_CONTAINER"
  docker rm -f "$UAV_CONTAINER" >/dev/null
fi

# Host published UDP port follows QGC target port from topology
HOST_UDP_PORT="$QGC_PORT"
CONTAINER_UDP_PORT="$QGC_PORT"

if [[ "$USE_BMV2_CONTAINER" -eq 1 ]]; then
  if ! docker image inspect "$CONTAINER_IMAGE" >/dev/null 2>&1; then
    echo "[ERR] BMv2 inline requested but image is not available: $CONTAINER_IMAGE" >&2
    echo "[ERR] build it first: ${MESH_DIR}/deploy/docker/uav-bmv2/build_image.sh" >&2
    exit 1
  fi
fi

DOCKER_CAP_ARGS=()
if [[ "$USE_BMV2_CONTAINER" -eq 1 ]]; then
  DOCKER_CAP_ARGS+=(--cap-add NET_ADMIN --cap-add NET_RAW)
fi

echo "[I] creating container:"
echo "    name=$UAV_CONTAINER"
echo "    image=$CONTAINER_IMAGE"
echo "    workdir=$CONTAINER_WORKDIR"
echo "    publish=${HOST_UDP_PORT}:${CONTAINER_UDP_PORT}/udp"
if [[ "$USE_BMV2_CONTAINER" -eq 1 ]]; then
  echo "    cap_add=NET_ADMIN,NET_RAW"
fi

created_id="$(
docker create \
  --name "$UAV_CONTAINER" \
  --hostname "$UAV_NAME" \
  --workdir "$CONTAINER_WORKDIR" \
  --network bridge \
  "${DOCKER_CAP_ARGS[@]}" \
  --entrypoint "$CONTAINER_ENTRYPOINT_BIN" \
  --label "ucs.mesh.managed=true" \
  --label "ucs.scenario.id=$SCENARIO_ID" \
  --label "ucs.uav.id=$UAV_ID" \
  --label "ucs.uav.idx=$IDX" \
  --label "ucs.uav.name=$UAV_NAME" \
  --label "ucs.px4.instance=$PX4_INSTANCE" \
  --label "ucs.model.name=$PX4_MODEL_INSTANCE" \
  --label "ucs.bmv2.enabled=$USE_BMV2_CONTAINER" \
  --label "ucs.bmv2.placement=${REQUESTED_EDGE_DATAPLANE:-none}" \
  -e "UAV_P_SIG=$UAV_P_SIG" \
  -e "UAV_P_STAT=$UAV_P_STAT" \
  -e "UAV_P_DATA=$UAV_P_DATA" \
  -e "CTRL_IP=$CTRL_IP" \
  -e "DATA_PROTO=$DATA_PROTO" \
  -e "PX4_CMD=$PX4_CMD" \
  -e "BIND_IF=$BIND_IF" \
  -e "UCS_BMV2_ENABLED=$USE_BMV2_CONTAINER" \
  -p "${HOST_UDP_PORT}:${CONTAINER_UDP_PORT}/udp" \
  "$CONTAINER_IMAGE" \
  -- "$CONTAINER_CMD_SHELL" "$CONTAINER_CMD_FLAG" "$CONTAINER_CMD_STRING"
)"

echo "[OK] created container: $UAV_CONTAINER"
echo "     Container ID: $created_id"

docker inspect -f '
Name={{.Name}}
Image={{.Config.Image}}
Entrypoint={{json .Config.Entrypoint}}
Cmd={{json .Config.Cmd}}
WorkingDir={{.Config.WorkingDir}}
NetworkMode={{.HostConfig.NetworkMode}}
PortBindings={{json .HostConfig.PortBindings}}
CapAdd={{json .HostConfig.CapAdd}}
Labels={{json .Config.Labels}}
' "$UAV_CONTAINER"
