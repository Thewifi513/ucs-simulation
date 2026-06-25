#!/usr/bin/env bash
set -Eeuo pipefail

# UAV instance profile expander (JSON-backed)
#
# 用法（推荐 source）：
#   source ./fleet/uav_profile.sh 1
#   source ./fleet/uav_profile.sh --idx 2
#   source ./fleet/uav_profile.sh --id uav02
#   source ./fleet/uav_profile.sh --topology ./topology/wifi_adhoc_matrix_2x3_6uav.json --idx 2
#
# 直接执行时会打印展开结果：
#   ./fleet/uav_profile.sh --topology ./topology/wifi_adhoc_matrix_2x3_6uav.json --idx 2
#
# 默认拓扑文件：
#   ./topology/wifi_adhoc_matrix_2x3_6uav.json

_uav_profile_die() {
  echo "[uav_profile][ERR] $*" >&2
  return 1 2>/dev/null || exit 1
}

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/env_defaults.sh" ]]; then
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/env_defaults.sh"
fi
MESH_DIR="${UCS_MESH_DIR:-$(cd -- "${SCRIPT_DIR}/.." && pwd)}"
DEFAULT_TOPOLOGY="${MESH_DIR}/topology/wifi_adhoc_matrix_2x3_6uav.json"

TOPOLOGY_FILE="${TOPOLOGY_FILE:-$DEFAULT_TOPOLOGY}"
IDX_INPUT="${IDX:-}"
ID_INPUT="${UAV_ID:-}"

usage() {
  cat <<EOF
Usage:
  source ./fleet/uav_profile.sh [idx]
  source ./fleet/uav_profile.sh --idx N
  source ./fleet/uav_profile.sh --id uavNN
  source ./fleet/uav_profile.sh --topology <json> --idx N

Examples:
  source ./fleet/uav_profile.sh 1
  source ./fleet/uav_profile.sh --idx 2
  source ./fleet/uav_profile.sh --id uav02
  ./fleet/uav_profile.sh --topology ./topology/wifi_adhoc_matrix_2x3_6uav.json --idx 2
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --topology)
      [[ $# -ge 2 ]] || _uav_profile_die "--topology requires a path"
      TOPOLOGY_FILE="$2"
      shift 2
      ;;
    --idx)
      [[ $# -ge 2 ]] || _uav_profile_die "--idx requires a value"
      IDX_INPUT="$2"
      shift 2
      ;;
    --id)
      [[ $# -ge 2 ]] || _uav_profile_die "--id requires a value"
      ID_INPUT="$2"
      shift 2
      ;;
    -h|--help)
      usage
      return 0 2>/dev/null || exit 0
      ;;
    *)
      if [[ "$1" =~ ^[0-9]+$ ]]; then
        IDX_INPUT="$1"
        shift
      else
        _uav_profile_die "unknown argument: $1"
      fi
      ;;
  esac
done

[[ -f "$TOPOLOGY_FILE" ]] || _uav_profile_die "topology file not found: $TOPOLOGY_FILE"

if [[ -z "${IDX_INPUT}" && -z "${ID_INPUT}" ]]; then
  IDX_INPUT="1"
fi

if [[ -n "${IDX_INPUT}" && -n "${ID_INPUT}" ]]; then
  _uav_profile_die "use either --idx or --id, not both"
fi

if [[ -n "${IDX_INPUT}" ]]; then
  [[ "${IDX_INPUT}" =~ ^[0-9]+$ ]] || _uav_profile_die "idx must be a positive integer, got: ${IDX_INPUT}"
  (( IDX_INPUT >= 1 )) || _uav_profile_die "idx must be >= 1"
fi

_PROFILE_EXPORTS="$(
"$PYTHON_BIN" - "$TOPOLOGY_FILE" "${IDX_INPUT:-}" "${ID_INPUT:-}" <<'PY'
import ipaddress
import json
import shlex
import sys

topology_file, idx_raw, id_raw = sys.argv[1], sys.argv[2], sys.argv[3]

with open(topology_file, "r", encoding="utf-8") as f:
    topo = json.load(f)

globals_ = topo.get("globals", {})
instances = topo.get("instances", [])
links = topo.get("links", [])

uavs = [x for x in instances if x.get("type") == "uav"]

selected = None
if idx_raw:
    idx = int(idx_raw)
    for inst in uavs:
        if int(inst.get("idx", -1)) == idx:
            selected = inst
            break
elif id_raw:
    for inst in uavs:
        if inst.get("id") == id_raw:
            selected = inst
            break

if selected is None:
    key = f"idx={idx_raw}" if idx_raw else f"id={id_raw}"
    raise SystemExit(f"[uav_profile][ERR] no UAV instance matched {key} in topology")

def q(s):
    return shlex.quote("" if s is None else str(s))

def must(name, value):
    if value is None or value == "":
        raise SystemExit(f"[uav_profile][ERR] missing required field: {name}")
    return value

uav_id = must("instances[].id", selected.get("id"))
uav_name = must("instances[].name", selected.get("name"))
uav_idx = int(must("instances[].idx", selected.get("idx")))
uav_num = f"{uav_idx:02d}"
cluster_id = int(selected.get("cluster_id", globals_.get("cluster_id", 1)))

container_name = must("instances[].container_name", selected.get("container_name"))
px4_instance = int(must("instances[].px4_instance", selected.get("px4_instance")))
model_name = must("instances[].model_name", selected.get("model_name"))
mav_sys_id = int(must("instances[].mav_sys_id", selected.get("mav_sys_id")))
uxrce_dds_key = int(must("instances[].uxrce_dds_key", selected.get("uxrce_dds_key")))
uav_ip = must("instances[].exp_ip", selected.get("exp_ip"))
exp_if = str(selected.get("exp_if", globals_.get("exp_if", "eth1")))
qgc_port = int(must("instances[].qgc_port", selected.get("qgc_port")))
tap_name = must("instances[].tap_name", selected.get("tap_name"))
bridge_name = must("instances[].bridge_name", selected.get("bridge_name"))
veth_host = must("instances[].veth_host", selected.get("veth_host"))
veth_ct = must("instances[].veth_ct", selected.get("veth_ct"))
metrics_file = must("instances[].metrics_file", selected.get("metrics_file"))

spawn_pose = selected.get("spawn_pose", {})
spawn_x = float(spawn_pose.get("x", 0.0))
spawn_y = float(spawn_pose.get("y", 0.0))
spawn_z = float(spawn_pose.get("z", 0.0))
spawn_roll = float(spawn_pose.get("roll", 0.0))
spawn_pitch = float(spawn_pose.get("pitch", 0.0))
spawn_yaw = float(spawn_pose.get("yaw", 0.0))
px4_gz_model_pose = f"{spawn_x},{spawn_y},{spawn_z},{spawn_roll},{spawn_pitch},{spawn_yaw}"

uav_ip_addr = str(ipaddress.ip_interface(uav_ip).ip)
qgc_target = f"{uav_ip_addr}:{qgc_port}"

experiment_net = globals_.get("experiment_net", {})
if not isinstance(experiment_net, dict):
    raise SystemExit("[uav_profile][ERR] globals.experiment_net must be an object if present")
experiment_mode = str(experiment_net.get("mode", "l3_star"))
gs_cluster_ips = experiment_net.get("gs_cluster_ips", {})
if not isinstance(gs_cluster_ips, dict):
    raise SystemExit("[uav_profile][ERR] globals.experiment_net.gs_cluster_ips must be an object if present")
gs_ips = experiment_net.get("gs_ips", [])
if not isinstance(gs_ips, list):
    raise SystemExit("[uav_profile][ERR] globals.experiment_net.gs_ips must be an array if present")

if experiment_mode == "l2_link_mesh":
    gs_cluster_ip = ""
else:
    gs_cluster_ip = selected.get("gateway_ip") or gs_cluster_ips.get(str(cluster_id))
if not gs_cluster_ip and experiment_mode != "l2_link_mesh":
    gs_cluster_ip = f"10.10.{cluster_id}.254/24"
gs_cluster_ip_addr = str(ipaddress.ip_interface(gs_cluster_ip).ip) if gs_cluster_ip else ""
if experiment_mode in {"l3_mesh", "l2_link_mesh"} and gs_ips:
    gs_ip = str(gs_ips[0])
else:
    gs_ip = globals_.get("gs_ip", gs_cluster_ip)

business_flows = globals_.get("business_flows", {})
if not isinstance(business_flows, dict):
    business_flows = {}
control_flow = business_flows.get("control", {})
if not isinstance(control_flow, dict):
    control_flow = {}
qgc_flow = control_flow.get("qgc", {})
if not isinstance(qgc_flow, dict):
    qgc_flow = {}
mavsdk_flow = control_flow.get("mavsdk", {})
if not isinstance(mavsdk_flow, dict):
    mavsdk_flow = {}
mavsdk_control_enabled = int(bool(control_flow.get("enabled", True) and mavsdk_flow.get("enabled", True)))
qgc_rate_bytes_per_sec = int(selected.get(
    "qgc_rate_bytes_per_sec",
    qgc_flow.get("rate_bytes_per_sec", 20000),
))
mavsdk_rate_bytes_per_sec = int(selected.get(
    "mavsdk_rate_bytes_per_sec",
    mavsdk_flow.get("rate_bytes_per_sec", 20000),
))
px4_default_offboard_rate_bytes_per_sec = int(selected.get(
    "px4_default_offboard_rate_bytes_per_sec",
    mavsdk_flow.get("px4_default_offboard_rate_bytes_per_sec", mavsdk_rate_bytes_per_sec),
))
mavsdk_local_port = int(selected.get(
    "mavsdk_local_port",
    int(mavsdk_flow.get("uav_local_port_base", 18600)) + uav_idx,
))
mavsdk_remote_port = int(selected.get(
    "mavsdk_remote_port",
    int(mavsdk_flow.get("gs_remote_port_base", 14600)) + uav_idx,
))
mavsdk_remote_ip = str(selected.get("mavsdk_remote_ip") or mavsdk_flow.get("remote_ip") or gs_ip)
if mavsdk_remote_ip == "ground_station.exp_ip":
    mavsdk_remote_ip = str(gs_ip)
mavsdk_remote_ip_addr = str(ipaddress.ip_interface(mavsdk_remote_ip).ip) if "/" in mavsdk_remote_ip else str(ipaddress.ip_address(mavsdk_remote_ip))
mavsdk_url = str(selected.get("mavsdk_url") or f"udpin://0.0.0.0:{mavsdk_remote_port}")

tap_left = must("globals.tap_left", globals_.get("tap_left"))
time_file = must("globals.time_file", globals_.get("time_file"))
gz_partition = must("globals.gz_partition", globals_.get("gz_partition"))
px4_gz_world_name = must("globals.px4_gz_world_name", globals_.get("px4_gz_world_name"))
px4_sim_model_name = must("globals.px4_sim_model_name", globals_.get("px4_sim_model_name"))

default_data_rate = globals_.get("default_data_rate", "1Gbps")
default_delay = globals_.get("default_delay", "2ms")
tick = globals_.get("tick", "200ms")
pcap = globals_.get("pcap", 0)
verbose = globals_.get("verbose", 1)
stop_time = globals_.get("stop_time", 0)
scenario_id = topo.get("scenario_id", "")

link = None
for item in links:
    if item.get("enabled", True) and item.get("dst") == uav_id:
        link = item
        break

link_id = ""
link_src = ""
link_dst = ""
ns3_data_rate = default_data_rate
ns3_delay = default_delay
ns3_loss_min = 0.0
ns3_loss_max = 0.30
ns3_dist_no_loss = 50
ns3_dist_max = 500
ns3_jitter_per_mps = "0.05ms"
ns3_jitter_max = "10ms"

if link is not None:
    link_id = str(link.get("id", ""))
    link_src = str(link.get("src", ""))
    link_dst = str(link.get("dst", ""))
    ns3_data_rate = str(link.get("data_rate", default_data_rate))
    ns3_delay = str(link.get("base_delay", default_delay))
    ns3_loss_min = link.get("loss_min", 0.0)
    ns3_loss_max = link.get("loss_max", 0.30)
    ns3_dist_no_loss = link.get("dist_no_loss", 50)
    ns3_dist_max = link.get("dist_max", 500)
    ns3_jitter_per_mps = str(link.get("jitter_per_mps", "0.05ms"))
    ns3_jitter_max = str(link.get("jitter_max", "10ms"))

pairs = {
    "TOPOLOGY_FILE": topology_file,
    "SCENARIO_ID": scenario_id,

    "IDX": uav_idx,
    "UAV_NUM": uav_num,
    "CLUSTER_ID": cluster_id,
    "UAV_ID": uav_id,
    "UAV_NAME": uav_name,
    "UAV_CONTAINER": container_name,
    "CONTAINER_NAME": container_name,

    "PX4_INSTANCE": px4_instance,
    "PX4_MODEL_INSTANCE": model_name,
    "MAV_SYS_ID": mav_sys_id,
    "UXRCE_DDS_KEY": uxrce_dds_key,

    "GS_IP": gs_ip,
    "GS_CLUSTER_IP": gs_cluster_ip,
    "GS_CLUSTER_IP_ADDR": gs_cluster_ip_addr,
    "EDGE_GATEWAY_IP": gs_cluster_ip,
    "EDGE_GATEWAY_IP_ADDR": gs_cluster_ip_addr,
    "GS_IPS": " ".join(str(x) for x in gs_ips),
    "TAP_LEFT": tap_left,
    "EXPERIMENT_MODE": experiment_mode,

    "UAV_IP": uav_ip,
    "UAV_IP_ADDR": uav_ip_addr,
    "EXP_IF": exp_if,
    "QGC_PORT": qgc_port,
    "QGC_TARGET": qgc_target,
    "QGC_RATE_BYTES_PER_SEC": qgc_rate_bytes_per_sec,
    "MAVSDK_CONTROL_ENABLED": mavsdk_control_enabled,
    "MAVSDK_LOCAL_PORT": mavsdk_local_port,
    "MAVSDK_REMOTE_PORT": mavsdk_remote_port,
    "MAVSDK_REMOTE_IP": mavsdk_remote_ip_addr,
    "MAVSDK_URL": mavsdk_url,
    "MAVSDK_RATE_BYTES_PER_SEC": mavsdk_rate_bytes_per_sec,
    "PX4_DEFAULT_OFFBOARD_RATE_BYTES_PER_SEC": px4_default_offboard_rate_bytes_per_sec,

    "TAP_RIGHT": tap_name,
    "BRIDGE": bridge_name,
    "VETH_HOST": veth_host,
    "VETH_CT": veth_ct,

    "NS3_METRICS_FILE": metrics_file,
    "NS3_TIME_FILE": time_file,

    "GZ_PARTITION_NAME": gz_partition,
    "PX4_GZ_WORLD_NAME": px4_gz_world_name,
    "PX4_SIM_MODEL_NAME": px4_sim_model_name,

    "SPAWN_X": spawn_x,
    "SPAWN_Y": spawn_y,
    "SPAWN_Z": spawn_z,
    "SPAWN_ROLL": spawn_roll,
    "SPAWN_PITCH": spawn_pitch,
    "SPAWN_YAW": spawn_yaw,
    "PX4_GZ_MODEL_POSE": px4_gz_model_pose,

    "NS3_DATA_RATE": ns3_data_rate,
    "NS3_DELAY": ns3_delay,
    "NS3_TICK": tick,
    "NS3_PCAP": pcap,
    "NS3_VERBOSE": verbose,
    "NS3_STOP_TIME": stop_time,

    "NS3_LOSS_MIN": ns3_loss_min,
    "NS3_LOSS_MAX": ns3_loss_max,
    "NS3_DIST_NO_LOSS": ns3_dist_no_loss,
    "NS3_DIST_MAX": ns3_dist_max,
    "NS3_JITTER_PER_MPS": ns3_jitter_per_mps,
    "NS3_JITTER_MAX": ns3_jitter_max,

    "LINK_ID": link_id,
    "LINK_SRC": link_src,
    "LINK_DST": link_dst,
}

for k, v in pairs.items():
    print(f"export {k}={q(v)}")
PY
)"

eval "$_PROFILE_EXPORTS"
unset _PROFILE_EXPORTS

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  cat <<EOF
TOPOLOGY_FILE=${TOPOLOGY_FILE}
SCENARIO_ID=${SCENARIO_ID}

IDX=${IDX}
UAV_NUM=${UAV_NUM}
CLUSTER_ID=${CLUSTER_ID}
UAV_ID=${UAV_ID}
UAV_NAME=${UAV_NAME}
UAV_CONTAINER=${UAV_CONTAINER}

PX4_INSTANCE=${PX4_INSTANCE}
PX4_MODEL_INSTANCE=${PX4_MODEL_INSTANCE}
MAV_SYS_ID=${MAV_SYS_ID}
UXRCE_DDS_KEY=${UXRCE_DDS_KEY}

GS_IP=${GS_IP}
GS_CLUSTER_IP=${GS_CLUSTER_IP}
GS_CLUSTER_IP_ADDR=${GS_CLUSTER_IP_ADDR}
EDGE_GATEWAY_IP=${EDGE_GATEWAY_IP}
EDGE_GATEWAY_IP_ADDR=${EDGE_GATEWAY_IP_ADDR}
GS_IPS=${GS_IPS}
EXPERIMENT_MODE=${EXPERIMENT_MODE}
UAV_IP=${UAV_IP}
UAV_IP_ADDR=${UAV_IP_ADDR}
EXP_IF=${EXP_IF}
QGC_PORT=${QGC_PORT}
QGC_TARGET=${QGC_TARGET}
QGC_RATE_BYTES_PER_SEC=${QGC_RATE_BYTES_PER_SEC}
MAVSDK_CONTROL_ENABLED=${MAVSDK_CONTROL_ENABLED}
MAVSDK_LOCAL_PORT=${MAVSDK_LOCAL_PORT}
MAVSDK_REMOTE_PORT=${MAVSDK_REMOTE_PORT}
MAVSDK_REMOTE_IP=${MAVSDK_REMOTE_IP}
MAVSDK_URL=${MAVSDK_URL}
MAVSDK_RATE_BYTES_PER_SEC=${MAVSDK_RATE_BYTES_PER_SEC}
PX4_DEFAULT_OFFBOARD_RATE_BYTES_PER_SEC=${PX4_DEFAULT_OFFBOARD_RATE_BYTES_PER_SEC}

TAP_LEFT=${TAP_LEFT}
TAP_RIGHT=${TAP_RIGHT}
BRIDGE=${BRIDGE}
VETH_HOST=${VETH_HOST}
VETH_CT=${VETH_CT}

NS3_METRICS_FILE=${NS3_METRICS_FILE}
NS3_TIME_FILE=${NS3_TIME_FILE}

GZ_PARTITION_NAME=${GZ_PARTITION_NAME}
PX4_GZ_WORLD_NAME=${PX4_GZ_WORLD_NAME}
PX4_SIM_MODEL_NAME=${PX4_SIM_MODEL_NAME}

SPAWN_X=${SPAWN_X}
SPAWN_Y=${SPAWN_Y}
SPAWN_Z=${SPAWN_Z}
SPAWN_ROLL=${SPAWN_ROLL}
SPAWN_PITCH=${SPAWN_PITCH}
SPAWN_YAW=${SPAWN_YAW}
PX4_GZ_MODEL_POSE=${PX4_GZ_MODEL_POSE}

LINK_ID=${LINK_ID}
LINK_SRC=${LINK_SRC}
LINK_DST=${LINK_DST}

NS3_DATA_RATE=${NS3_DATA_RATE}
NS3_DELAY=${NS3_DELAY}
NS3_TICK=${NS3_TICK}
NS3_PCAP=${NS3_PCAP}
NS3_VERBOSE=${NS3_VERBOSE}
NS3_STOP_TIME=${NS3_STOP_TIME}

NS3_LOSS_MIN=${NS3_LOSS_MIN}
NS3_LOSS_MAX=${NS3_LOSS_MAX}
NS3_DIST_NO_LOSS=${NS3_DIST_NO_LOSS}
NS3_DIST_MAX=${NS3_DIST_MAX}
NS3_JITTER_PER_MPS=${NS3_JITTER_PER_MPS}
NS3_JITTER_MAX=${NS3_JITTER_MAX}
EOF
fi
