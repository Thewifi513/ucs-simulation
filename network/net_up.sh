#!/usr/bin/env bash
set -Eeuo pipefail

# UCS mesh live ns-3 launcher
#
# 职责：
#   - 读取 topology JSON
#   - 前置检查容器
#   - 后台等待 ns-3/TapBridge 创建 tap 设备
#   - 两阶段完成实验网接线：
#       1) 先统一把所有 tap 拉起并预配置
#       2) 再逐架建立 bridge/veth/netns/eth1
#   - 确保 ns-3 scratch 二进制具备 root+suid 后，前台运行 --live=1
#
# 说明：
#   - 不启动 PX4；默认假定各 UAV 容器/PX4 已经起来
#   - 不启动 metrics；metrics_up.sh 仍然单独运行
#   - 支持 Stage 1 L3 star、Stage 2 routed mesh、Stage 3/4 Linux-visible L2 link mesh
#   - ns-3 启动时序沿用 fleet
#
# 用法：
#   ./network/net_up.sh
#   ./network/net_up.sh --topology ./topology/wifi_adhoc_matrix_2x3_6uav.json
#   ./network/net_up.sh --verbose
#   ./network/net_up.sh --dry-run
#   ./network/net_up.sh --plumb-only
#   ./network/net_up.sh --sudo-ready --ready-file /tmp/ucs-mesh/net.ready
#
# 退出：
#   - Ctrl+C 会结束前台 ns-3，同时清理后台等待进程
#   - tap 设备会随 ns-3 退出而消失；这是正常行为
#   - 调试链路仿真时可用 UCS_MESH_DISABLE_BMV2=1 或
#     UCS_MESH_EDGE_DATAPLANE=linux_bridge 绕过 BMv2，只保留 ns-3 链路。

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MESH_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${MESH_DIR}/fleet/env_defaults.sh"
DEFAULT_TOPOLOGY="${MESH_DIR}/topology/wifi_adhoc_matrix_2x3_6uav.json"
SCRATCH="${SCRATCH:-}"

TOPOLOGY_FILE="${TOPOLOGY_FILE:-$DEFAULT_TOPOLOGY}"
VERBOSE=0
DRY_RUN=0
PLUMB_ONLY=0
SUDO_READY=0
READY_FILE=""

TXQLEN="${TXQLEN:-20000}"
PFIFO_LIMIT="${PFIFO_LIMIT:-20000}"
WAIT_TIMEOUT_SEC="${WAIT_TIMEOUT_SEC:-20}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--topology FILE] [--verbose] [--dry-run] [--plumb-only] [--sudo-ready] [--ready-file FILE] [--help]

--topology FILE   Topology JSON file. Default: ${DEFAULT_TOPOLOGY}
--verbose         Print more details.
--dry-run         Only resolve and print config; do not run ns-3 or change networking.
--plumb-only      Configure tap/bridge/veth/routes against an already running ns-3; do not start ns-3.
--sudo-ready      Assume caller already ran sudo -v; use non-interactive sudo only.
--ready-file FILE Write network plumbing status for fleet_up.sh: ready or failed.
--help            Show this help.
EOF
}

log() {
  echo "[ns3_live_up] $*"
}

vlog() {
  if [[ "$VERBOSE" -eq 1 ]]; then
    echo "[ns3_live_up] $*"
  fi
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "[ns3_live_up][ERR] missing command: $1" >&2
    exit 1
  }
}

s() {
  sudo -n "$@"
}

write_ready_status() {
  local status="$1"
  [[ -n "$READY_FILE" ]] || return 0
  mkdir -p "$(dirname -- "$READY_FILE")"
  printf '%s\n' "$status" > "$READY_FILE"
}

mark_ready() {
  write_ready_status "ready"
}

mark_failed() {
  write_ready_status "failed"
}

ns3_scratch_binary() {
  local scratch_name="${SCRATCH##*/}"
  find "$NS3_DIR/build/scratch" -maxdepth 1 -type f -name "ns3-*-${scratch_name}-*" 2>/dev/null | sort | head -n 1
}

ensure_ns3_scratch_suid() {
  local bin=""
  local owner_uid=""

  log "preparing ns-3 scratch binary privileges ..."
  cd "$NS3_DIR"
  ./ns3 build "scratch/${SCRATCH}"

  bin="$(ns3_scratch_binary)"
  if [[ -z "$bin" ]]; then
    echo "[ns3_live_up][ERR] built ns-3 scratch binary not found for ${SCRATCH}" >&2
    return 1
  fi

  owner_uid="$(stat -c '%u' "$bin")"
  if [[ "$owner_uid" == "0" && -u "$bin" ]]; then
    vlog "ns-3 scratch binary already root+suid: ${bin}"
    return 0
  fi

  s chown root "$bin"
  s chmod u+s "$bin"
  vlog "configured root+suid on ns-3 scratch binary: ${bin}"
}

try_sysctl() {
  local setting="$1"
  if ! s sysctl -w "$setting" >/dev/null 2>&1; then
    vlog "sysctl skipped or failed: ${setting}"
  fi
}

quiet_host_l2_if() {
  local ifname="$1"

  # These interfaces are transparent L2 plumbing. The host must not answer ARP
  # for gs0 or other local addresses through them.
  try_sysctl "net.ipv4.conf.${ifname}.arp_ignore=8"
  try_sysctl "net.ipv4.conf.${ifname}.arp_announce=2"
  try_sysctl "net.ipv4.conf.${ifname}.proxy_arp=0"
  try_sysctl "net.ipv4.conf.${ifname}.proxy_arp_pvlan=0"
  try_sysctl "net.ipv4.conf.${ifname}.rp_filter=0"
  try_sysctl "net.ipv6.conf.${ifname}.disable_ipv6=1"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --topology)
      [[ $# -ge 2 ]] || { echo "[ns3_live_up][ERR] --topology requires a path" >&2; exit 1; }
      TOPOLOGY_FILE="$2"
      shift 2
      ;;
    --verbose)
      VERBOSE=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --plumb-only)
      PLUMB_ONLY=1
      shift
      ;;
    --sudo-ready)
      SUDO_READY=1
      shift
      ;;
    --ready-file)
      [[ $# -ge 2 ]] || { echo "[ns3_live_up][ERR] --ready-file requires a path" >&2; exit 1; }
      READY_FILE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[ns3_live_up][ERR] unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

need_cmd "$PYTHON_BIN"
need_cmd docker
need_cmd ip
need_cmd tc
need_cmd nsenter
need_cmd sudo

[[ -d "$NS3_DIR" ]] || { echo "[ns3_live_up][ERR] ns-3 dir not found: $NS3_DIR" >&2; exit 1; }
[[ -f "$TOPOLOGY_FILE" ]] || { echo "[ns3_live_up][ERR] topology file not found: $TOPOLOGY_FILE" >&2; exit 1; }

TOPOLOGY_FILE="$("$PYTHON_BIN" -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$TOPOLOGY_FILE")"

RUNTIME_SH="$(mktemp /tmp/ucs_mesh_ns3_live.XXXXXX.sh)"
cleanup_runtime_file() {
  rm -f "$RUNTIME_SH"
}
trap cleanup_runtime_file EXIT

"$PYTHON_BIN" - "$TOPOLOGY_FILE" "$NS3_DIR" "$SCRATCH" > "$RUNTIME_SH" <<'PY'
import ipaddress
import json
import os
import re
import shlex
import sys

topology_file, ns3_dir, scratch = sys.argv[1:]

with open(topology_file, "r", encoding="utf-8") as f:
    topo = json.load(f)

scenario_id = topo.get("scenario_id")
if not scenario_id:
    raise SystemExit("[ns3_live_up][ERR] missing scenario_id")
SAFE_IDENTIFIER_RE = re.compile(r"^[A-Za-z0-9_.:-]+$")

def require_safe_identifier(value: str, context: str) -> str:
    text = str(value)
    if not SAFE_IDENTIFIER_RE.fullmatch(text):
        raise SystemExit(
            f"[ns3_live_up][ERR] unsafe {context}: {text!r}; "
            "expected [A-Za-z0-9_.:-]+"
        )
    return text

scenario_id = require_safe_identifier(str(scenario_id), "scenario_id")

globals_ = topo.get("globals", {})
instances = topo.get("instances", [])
links = topo.get("links", [])
mesh_links = topo.get("mesh_links", [])
if not isinstance(links, list):
    raise SystemExit("[ns3_live_up][ERR] top-level links must be an array if present")
if mesh_links and not isinstance(mesh_links, list):
    raise SystemExit("[ns3_live_up][ERR] top-level mesh_links must be an array if present")

gs_id = globals_.get("gs_id")
if not gs_id:
    raise SystemExit("[ns3_live_up][ERR] missing globals.gs_id")
gs_id = require_safe_identifier(str(gs_id), "globals.gs_id")

tap_left = globals_.get("tap_left")
if not tap_left:
    raise SystemExit("[ns3_live_up][ERR] missing globals.tap_left")
tap_left = require_safe_identifier(str(tap_left), "globals.tap_left")

experiment_net = globals_.get("experiment_net", {})
if not isinstance(experiment_net, dict):
    raise SystemExit("[ns3_live_up][ERR] globals.experiment_net must be an object if present")

programmable_net = topo.get("programmable_net", globals_.get("programmable_net", {}))
if programmable_net and not isinstance(programmable_net, dict):
    raise SystemExit("[ns3_live_up][ERR] programmable_net must be an object if present")

experiment_mode = str(experiment_net.get("mode", "l3_star"))
if experiment_mode not in {"l3_star", "l3_mesh", "l2_link_mesh"}:
    raise SystemExit(f"[ns3_live_up][ERR] unsupported experiment_net.mode: {experiment_mode}")

default_edge_dataplane = str(experiment_net.get("edge_dataplane", "linux_bridge"))
if programmable_net.get("enabled", False):
    placement = str(programmable_net.get("placement", "in_uav_container_inline"))
    if placement != "in_uav_container_inline":
        raise SystemExit(f"[ns3_live_up][ERR] unsupported programmable_net placement: {placement}")
    default_edge_dataplane = "container_bmv2_inline"

disable_bmv2 = os.environ.get("UCS_MESH_DISABLE_BMV2", "").lower() in {"1", "true", "yes", "on"}
edge_dataplane = os.environ.get("UCS_MESH_EDGE_DATAPLANE", default_edge_dataplane)
if edge_dataplane == "bmv2_uav_edge":
    edge_dataplane = "container_bmv2_inline"
if disable_bmv2:
    edge_dataplane = "linux_bridge"
if edge_dataplane not in {"linux_bridge", "container_bmv2_inline"}:
    raise SystemExit(f"[ns3_live_up][ERR] unsupported edge dataplane: {edge_dataplane}")
if edge_dataplane == "container_bmv2_inline" and experiment_mode != "l2_link_mesh":
    raise SystemExit("[ns3_live_up][ERR] container_bmv2_inline is currently supported only for l2_link_mesh")

gs_edge_cfg = programmable_net.get("gs_edge", {}) if programmable_net else {}
if gs_edge_cfg and not isinstance(gs_edge_cfg, dict):
    raise SystemExit("[ns3_live_up][ERR] programmable_net.gs_edge must be an object if present")
ports_cfg = programmable_net.get("ports", {}) if programmable_net else {}
if ports_cfg and not isinstance(ports_cfg, dict):
    raise SystemExit("[ns3_live_up][ERR] programmable_net.ports must be an object if present")
local_port_cfg = ports_cfg.get("local", {}) if ports_cfg else {}
air_port_cfg = ports_cfg.get("air", {}) if ports_cfg else {}
cpu_port_cfg = ports_cfg.get("cpu", {}) if ports_cfg else {}
for label, cfg in (("local", local_port_cfg), ("air", air_port_cfg), ("cpu", cpu_port_cfg)):
    if cfg and not isinstance(cfg, dict):
        raise SystemExit(f"[ns3_live_up][ERR] programmable_net.ports.{label} must be an object if present")

def env_first(names):
    for name in names:
        value = os.environ.get(name)
        if value not in (None, ""):
            return value
    return None

bmv2_local_port = int(os.environ.get("UCS_MESH_BMV2_LOCAL_PORT", local_port_cfg.get("port_id", 1)))
bmv2_local_if = require_safe_identifier(
    os.environ.get("UCS_MESH_BMV2_LOCAL_IF", local_port_cfg.get("iface", "p4local")),
    "BMv2 local interface",
)
bmv2_air_port = int(os.environ.get("UCS_MESH_BMV2_AIR_PORT", air_port_cfg.get("port_id", 2)))
bmv2_air_if = require_safe_identifier(
    os.environ.get("UCS_MESH_BMV2_AIR_IF", air_port_cfg.get("iface", "air0")),
    "BMv2 air interface",
)
bmv2_cpu_port = int(os.environ.get("UCS_MESH_BMV2_CPU_PORT", cpu_port_cfg.get("port_id", 255)))
programmable_routing = programmable_net.get("routing", {}) if programmable_net else {}
if programmable_routing and not isinstance(programmable_routing, dict):
    raise SystemExit("[ns3_live_up][ERR] programmable_net.routing must be an object if present")
programmable_routing_mode = str(programmable_routing.get("mode", ""))
p4_cluster_head_routes = programmable_routing_mode in {"cluster_heads", "cluster_head_routes"}
if programmable_routing.get("cluster_head_routes", False):
    p4_cluster_head_routes = True
cluster_heads_cfg = programmable_routing.get("cluster_heads", {})
if cluster_heads_cfg and not isinstance(cluster_heads_cfg, dict):
    raise SystemExit("[ns3_live_up][ERR] programmable_net.routing.cluster_heads must be an object if present")
p4_cluster_heads = ",".join(
    f"{cluster_id}:{head_id}"
    for cluster_id, head_id in sorted(
        ((int(k), str(v)) for k, v in cluster_heads_cfg.items()),
        key=lambda item: item[0],
    )
)
gs_bmv2_enabled = bool(gs_edge_cfg.get("enabled", False))
if os.environ.get("UCS_MESH_GS_BMV2_EDGE", "") == "1":
    gs_bmv2_enabled = True
if edge_dataplane != "container_bmv2_inline" or disable_bmv2:
    gs_bmv2_enabled = False
gs_app_if = require_safe_identifier(env_first(["UCS_MESH_GS_APP_IF"]) or gs_edge_cfg.get("app_if", "gs0"), "GS app interface")
gs_local_if = require_safe_identifier(env_first(["UCS_MESH_GS_LOCAL_IF"]) or gs_edge_cfg.get("local_if", "p4gs-local"), "GS BMv2 local interface")
gs_air_if = require_safe_identifier(env_first(["UCS_MESH_GS_AIR_IF"]) or gs_edge_cfg.get("air_if", tap_left), "GS BMv2 air interface")
if gs_bmv2_enabled and gs_air_if != tap_left:
    raise SystemExit(
        f"[ns3_live_up][ERR] programmable_net.gs_edge.air_if must match globals.tap_left "
        f"for host_inline GS BMv2: air_if={gs_air_if} tap_left={tap_left}"
    )
gs_p4_device_id = int(env_first(["UCS_MESH_GS_P4_DEVICE_ID"]) or gs_edge_cfg.get("device_id", 100))
gs_p4_grpc_addr = str(
    env_first(["UCS_MESH_GS_P4_GRPC_ADDR", "UCS_MESH_GS_BMV2_GRPC_ADDR"])
    or gs_edge_cfg.get("grpc_addr", "127.0.0.1:9560")
)
require_safe_identifier(gs_p4_grpc_addr, "GS P4Runtime grpc address")
gs_bmv2_image = str(gs_edge_cfg.get("runtime_image", os.environ.get("UCS_MESH_GS_BMV2_IMAGE", os.environ.get("UCS_MESH_BMV2_IMAGE", "uav-base:v1.1-gz-bmv2"))))
gs_bmv2_container = str(
    env_first(["UCS_MESH_GS_BMV2_CONTAINER"])
    or gs_edge_cfg.get("container_name", f"ucs-bmv2-gs-{scenario_id}")
)
require_safe_identifier(gs_bmv2_container, "GS BMv2 container name")

if not scratch:
    if experiment_mode == "l3_mesh":
        scratch = "ucs_fleet_mesh_topology_v2"
    elif experiment_mode == "l2_link_mesh":
        scratch = "ucs_fleet_l2_mesh_topology"
    else:
        scratch = "ucs_fleet_topology"

gs_cluster_ips = experiment_net.get("gs_cluster_ips", {})
if not isinstance(gs_cluster_ips, dict):
    raise SystemExit("[ns3_live_up][ERR] globals.experiment_net.gs_cluster_ips must be an object if present")

gs_ips = experiment_net.get("gs_ips", [])
if gs_ips and not isinstance(gs_ips, list):
    raise SystemExit("[ns3_live_up][ERR] globals.experiment_net.gs_ips must be an array if present")
if not gs_ips:
    legacy_gs_ip = globals_.get("gs_ip", "10.10.0.254/24")
    gs_ips = [legacy_gs_ip]

default_exp_if = str(globals_.get("exp_if", "eth1"))

inst_map = {}
instance_index = {}
for inst in instances:
    inst_id = inst.get("id")
    if not inst_id:
        raise SystemExit("[ns3_live_up][ERR] found instance without id")
    inst_id = require_safe_identifier(str(inst_id), "instance id")
    inst["id"] = inst_id
    instance_index[inst_id] = len(instance_index)
    inst_map[inst_id] = inst

def normalize_mac(value: str) -> str:
    return str(value).strip().lower()

def validate_mac(value: str, context: str) -> str:
    mac = normalize_mac(value)
    if not re.fullmatch(r"[0-9a-f]{2}(:[0-9a-f]{2}){5}", mac):
        raise SystemExit(f"[ns3_live_up][ERR] invalid MAC for {context}: {value}")
    if int(mac[:2], 16) & 0x01 or mac in {"00:00:00:00:00:00", "ff:ff:ff:ff:ff:ff"}:
        raise SystemExit(f"[ns3_live_up][ERR] endpoint MAC must be unicast for {context}: {value}")
    return mac

def format_endpoint_mac(ordinal: int) -> str:
    ordinal = int(ordinal) & 0xffff
    return f"02:75:63:00:{(ordinal >> 8) & 0xff:02x}:{ordinal & 0xff:02x}"

def derive_endpoint_mac(inst: dict) -> str:
    for key in ("mac_addr", "endpoint_mac"):
        if inst.get(key):
            return validate_mac(str(inst[key]), f"instance {inst.get('id', '<unknown>')}")
    inst_id = str(inst.get("id", ""))
    if inst_id == str(gs_id) or inst.get("type") == "ground_station":
        return format_endpoint_mac(0)
    if "idx" in inst:
        try:
            idx = int(inst["idx"])
            if idx < 0 or idx > 65535:
                raise ValueError(idx)
            return format_endpoint_mac(idx)
        except Exception:
            raise SystemExit(
                f"[ns3_live_up][ERR] instances[].idx must fit uint16 for endpoint MAC derivation: {inst_id}"
            )
    m = re.search(r"(\d+)$", inst_id)
    if m:
        return format_endpoint_mac(int(m.group(1)))
    return format_endpoint_mac(instance_index.get(inst_id, 0) + 1)

def derive_uav_num(inst: dict) -> str:
    if "uav_num" in inst:
        return str(inst["uav_num"]).zfill(2)
    if "idx" in inst:
        try:
            return f"{int(inst['idx']):02d}"
        except Exception:
            pass
    inst_id = str(inst.get("id", ""))
    m = re.search(r"(\d+)$", inst_id)
    if m:
        return f"{int(m.group(1)):02d}"
    raise SystemExit(f"[ns3_live_up][ERR] cannot derive UAV number from instance: {inst}")

def cidr_ip(cidr: str) -> str:
    return str(ipaddress.ip_interface(cidr).ip)

def addr_ip(value: str) -> str:
    if "/" in value:
        return str(ipaddress.ip_interface(value).ip)
    return str(ipaddress.ip_address(value))

uav_instances = [inst for inst in instances if inst.get("type") == "uav"]
uav_by_id = {inst["id"]: inst for inst in uav_instances if inst.get("id")}
gs_inst = inst_map.get(gs_id)
if gs_inst is None:
    raise SystemExit(f"[ns3_live_up][ERR] globals.gs_id does not exist in instances: {gs_id}")

endpoint_macs = {}
mac_to_id = {}
for inst in instances:
    inst_id = str(inst.get("id", ""))
    mac = derive_endpoint_mac(inst)
    if mac in mac_to_id:
        raise SystemExit(
            f"[ns3_live_up][ERR] duplicate endpoint MAC: {mac} for {mac_to_id[mac]} and {inst_id}"
        )
    endpoint_macs[inst_id] = mac
    mac_to_id[mac] = inst_id
gs_endpoint_mac = endpoint_macs[str(gs_id)]

gs_gateway_ip = ""
if experiment_mode in {"l3_mesh", "l2_link_mesh"}:
    gs_exp_ip = gs_inst.get("exp_ip")
    if not gs_exp_ip:
        raise SystemExit(f"[ns3_live_up][ERR] {experiment_mode} requires gs instance exp_ip")
    gs_ips = [str(gs_exp_ip)]
    if experiment_mode == "l3_mesh":
        gs_gateway_raw = gs_inst.get("gateway_ip")
        if not gs_gateway_raw:
            raise SystemExit("[ns3_live_up][ERR] l3_mesh requires gs instance gateway_ip")
        gs_gateway_ip = addr_ip(str(gs_gateway_raw))

cluster_subnets = sorted({
    str(ipaddress.ip_interface(inst["exp_ip"]).network)
    for inst in uav_instances
    if inst.get("exp_ip")
})

host_routes = []
if experiment_mode == "l3_mesh":
    for subnet in cluster_subnets:
        host_routes.append({"dst": subnet, "via": gs_gateway_ip, "kind": "subnet_via_mesh_gs_edge"})
elif experiment_mode == "l2_link_mesh":
    for inst in uav_instances:
        peer_ip = inst.get("exp_ip")
        if peer_ip:
            host_routes.append({"dst": f"{cidr_ip(str(peer_ip))}/32", "via": "", "kind": "uav_onlink"})

if experiment_mode in {"l3_mesh", "l2_link_mesh"}:
    candidate_links = links if experiment_mode == "l3_mesh" else links + mesh_links
    enabled_mesh_links = [link for link in candidate_links if link.get("enabled", True)]
    if not enabled_mesh_links:
        link_sources = "links[]" if experiment_mode == "l3_mesh" else "links[] or mesh_links[]"
        raise SystemExit(
            f"[ns3_live_up][ERR] experiment_net.mode={experiment_mode} requires enabled {link_sources}"
        )
    for mesh_link in enabled_mesh_links:
        src = mesh_link.get("src")
        dst = mesh_link.get("dst")
        link_id = mesh_link.get("id", f"{src}-{dst}")
        if src not in inst_map:
            raise SystemExit(f"[ns3_live_up][ERR] mesh link src is not a known instance: {link_id} src={src}")
        if dst not in inst_map:
            raise SystemExit(f"[ns3_live_up][ERR] mesh link dst is not a known instance: {link_id} dst={dst}")
        if experiment_mode == "l3_mesh" and not mesh_link.get("subnet"):
            raise SystemExit(f"[ns3_live_up][ERR] l3_mesh link must define subnet: {link_id}")
        if not mesh_link.get("metrics_file"):
            raise SystemExit(f"[ns3_live_up][ERR] link must define metrics_file: {link_id}")
        if src == dst:
            raise SystemExit(f"[ns3_live_up][ERR] mesh link self-link is not supported: {link_id}")

def build_uav_item(inst: dict):
    uav_num = derive_uav_num(inst)
    default_name = str(inst.get("id", f"uav{uav_num}"))
    default_container = default_name
    cluster_id = int(inst.get("cluster_id", 1))
    default_ip = f"10.10.{cluster_id}.{int(uav_num)}/24"
    exp_if = str(inst.get("exp_if", default_exp_if))
    uav_ip = str(inst.get("exp_ip", default_ip))
    uav_ip_addr = cidr_ip(uav_ip)
    p4_cfg = inst.get("p4", {})
    if not isinstance(p4_cfg, dict):
        raise SystemExit(f"[ns3_live_up][ERR] instance p4 field must be an object: {default_name}")
    p4_device_id = int(p4_cfg.get("device_id", 100 + int(uav_num)))
    p4_grpc_addr = require_safe_identifier(
        p4_cfg.get("grpc_addr", os.environ.get("UCS_MESH_BMV2_GRPC_ADDR", "0.0.0.0:9559")),
        f"P4Runtime grpc address for {default_name}",
    )
    next_hop_raw = inst.get("gateway_ip") or gs_cluster_ips.get(str(cluster_id))
    if not next_hop_raw:
        if experiment_mode == "l3_mesh":
            raise SystemExit(f"[ns3_live_up][ERR] l3_mesh UAV missing gateway_ip: {default_name}")
        if experiment_mode == "l2_link_mesh":
            next_hop = ""
        else:
            next_hop_raw = f"10.10.{cluster_id}.254/24"
            next_hop = addr_ip(str(next_hop_raw))
    else:
        next_hop = addr_ip(str(next_hop_raw))

    if experiment_mode == "l3_star":
        routes = [{"dst": "10.10.0.0/16", "via": next_hop, "kind": "fallback_gs"}]
        for peer in uav_instances:
            if peer.get("id") == inst.get("id"):
                continue
            if int(peer.get("cluster_id", 1)) != cluster_id:
                continue
            peer_ip = peer.get("exp_ip")
            if peer_ip:
                routes.append({
                    "dst": f"{cidr_ip(str(peer_ip))}/32",
                    "via": next_hop,
                    "kind": "same_cluster_via_gs",
                })
    elif experiment_mode == "l3_mesh":
        routes = [{"dst": "10.10.0.0/24", "via": next_hop, "kind": "infra_via_mesh_edge"}]
        for peer in uav_instances:
            if peer.get("id") == inst.get("id"):
                continue
            peer_ip = peer.get("exp_ip")
            if peer_ip:
                routes.append({
                    "dst": f"{cidr_ip(str(peer_ip))}/32",
                    "via": next_hop,
                    "kind": "peer_via_mesh_edge",
                })
    else:
        routes = []
        gs_peer_ip = cidr_ip(str(gs_ips[0])) if gs_ips else "10.10.0.254"
        routes.append({"dst": f"{gs_peer_ip}/32", "via": "", "kind": "gs_onlink"})
        for peer in uav_instances:
            if peer.get("id") == inst.get("id"):
                continue
            peer_ip = peer.get("exp_ip")
            if peer_ip:
                routes.append({
                    "dst": f"{cidr_ip(str(peer_ip))}/32",
                    "via": "",
                    "kind": "peer_onlink",
                })

    return {
        "uav_id": default_name,
        "cluster_id": cluster_id,
        "container_name": require_safe_identifier(inst.get("container_name", default_container), f"container name for {default_name}"),
        "tap_right": require_safe_identifier(inst.get("tap_name", f"tap-{default_name}"), f"tap name for {default_name}"),
        "bridge": require_safe_identifier(inst.get("bridge_name", f"br-{default_name}"), f"bridge name for {default_name}"),
        "veth_host": require_safe_identifier(inst.get("veth_host", f"veth-{default_name}-host"), f"host veth name for {default_name}"),
        "veth_ct": require_safe_identifier(inst.get("veth_ct", f"veth-{default_name}-ct"), f"container veth name for {default_name}"),
        "uav_ip": uav_ip,
        "uav_ip_addr": uav_ip_addr,
        "exp_if": require_safe_identifier(exp_if, f"experiment interface for {default_name}"),
        "endpoint_mac": endpoint_macs[str(inst.get("id"))],
        "gs_next_hop": next_hop,
        "p4_device_id": p4_device_id,
        "p4_grpc_addr": p4_grpc_addr,
        "routes": routes,
    }

resolved = []
if experiment_mode == "l3_star":
    for link in links:
        if not link.get("enabled", True):
            continue
        if link.get("src") != gs_id:
            continue
        dst = link.get("dst")
        if dst not in inst_map:
            raise SystemExit(f"[ns3_live_up][ERR] enabled link dst not found in instances: {dst}")
        inst = inst_map[dst]
        if inst.get("type") != "uav":
            raise SystemExit(f"[ns3_live_up][ERR] enabled link dst is not a uav: {dst}")
        resolved.append(build_uav_item(inst))
else:
    for inst in uav_instances:
        resolved.append(build_uav_item(inst))

if not resolved:
    raise SystemExit("[ns3_live_up][ERR] no UAV endpoints resolved")

def emit(name: str, value) -> None:
    print(f"{name}={shlex.quote(str(value))}")

emit("SCENARIO_ID", scenario_id)
emit("TOPOLOGY_FILE", topology_file)
emit("NS3_DIR", ns3_dir)
emit("SCRATCH", scratch)
emit("TAP_LEFT", tap_left)
emit("EXPERIMENT_MODE", experiment_mode)
emit("EDGE_DATAPLANE", edge_dataplane)
emit("BMV2_BYPASS", 1 if disable_bmv2 else 0)
emit("GS_BMV2_ENABLED", 1 if gs_bmv2_enabled else 0)
emit("GS_APP_IF", gs_app_if)
emit("GS_LOCAL_IF", gs_local_if)
emit("GS_AIR_IF", gs_air_if)
emit("GS_ENDPOINT_MAC", gs_endpoint_mac)
emit("GS_P4_DEVICE_ID", gs_p4_device_id)
emit("GS_P4_GRPC_ADDR", gs_p4_grpc_addr)
emit("GS_BMV2_IMAGE", gs_bmv2_image)
emit("GS_BMV2_CONTAINER", gs_bmv2_container)
emit("BMV2_LOCAL_PORT", bmv2_local_port)
emit("BMV2_LOCAL_IF", bmv2_local_if)
emit("BMV2_AIR_PORT", bmv2_air_port)
emit("BMV2_AIR_IF", bmv2_air_if)
emit("BMV2_CPU_PORT", bmv2_cpu_port)
emit("P4_ROUTING_MODE", programmable_routing_mode)
emit("P4_CLUSTER_HEAD_ROUTES", 1 if p4_cluster_head_routes else 0)
emit("P4_CLUSTER_HEADS", p4_cluster_heads)
emit("GS_GATEWAY_IP", gs_gateway_ip)
emit("GS_IP_COUNT", len(gs_ips))
for i, gs_ip in enumerate(gs_ips):
    emit(f"GS_IP_{i}", gs_ip)
emit("CLUSTER_SUBNET_COUNT", len(cluster_subnets))
for i, subnet in enumerate(cluster_subnets):
    emit(f"CLUSTER_SUBNET_{i}", subnet)
emit("HOST_ROUTE_COUNT", len(host_routes))
for i, route in enumerate(host_routes):
    emit(f"HOST_ROUTE_DST_{i}", route["dst"])
    emit(f"HOST_ROUTE_VIA_{i}", route["via"])
    emit(f"HOST_ROUTE_KIND_{i}", route["kind"])
emit("UAV_COUNT", len(resolved))

for i, item in enumerate(resolved):
    emit(f"UAV_ID_{i}", item["uav_id"])
    emit(f"CLUSTER_ID_{i}", item["cluster_id"])
    emit(f"UAV_CONTAINER_{i}", item["container_name"])
    emit(f"TAP_RIGHT_{i}", item["tap_right"])
    emit(f"BRIDGE_{i}", item["bridge"])
    emit(f"VETH_HOST_{i}", item["veth_host"])
    emit(f"VETH_CT_{i}", item["veth_ct"])
    emit(f"UAV_IP_{i}", item["uav_ip"])
    emit(f"UAV_IP_ADDR_{i}", item["uav_ip_addr"])
    emit(f"EXP_IF_{i}", item["exp_if"])
    emit(f"UAV_ENDPOINT_MAC_{i}", item["endpoint_mac"])
    emit(f"GS_NEXT_HOP_{i}", item["gs_next_hop"])
    emit(f"P4_DEVICE_ID_{i}", item["p4_device_id"])
    emit(f"P4_GRPC_ADDR_{i}", item["p4_grpc_addr"])
    emit(f"ROUTE_COUNT_{i}", len(item["routes"]))
    for j, route in enumerate(item["routes"]):
        emit(f"ROUTE_DST_{i}_{j}", route["dst"])
        emit(f"ROUTE_VIA_{i}_{j}", route["via"])
        emit(f"ROUTE_KIND_{i}_{j}", route["kind"])
PY

# shellcheck disable=SC1090
source "$RUNTIME_SH"

log "topology = $TOPOLOGY_FILE"
log "scenario = $SCENARIO_ID"
log "ns3_dir   = $NS3_DIR"
log "scratch   = $SCRATCH"
log "tap_left  = $TAP_LEFT"
log "exp_mode  = $EXPERIMENT_MODE"
log "edge_dp   = $EDGE_DATAPLANE"
if [[ "$BMV2_BYPASS" == "1" ]]; then
  log "bmv2      = bypassed by UCS_MESH_DISABLE_BMV2=1"
fi
if [[ "$GS_BMV2_ENABLED" == "1" ]]; then
  log "gs_edge   = bmv2_inline app=${GS_APP_IF} mac=${GS_ENDPOINT_MAC} local=${GS_LOCAL_IF} air=${GS_AIR_IF} container=${GS_BMV2_CONTAINER} device=${GS_P4_DEVICE_ID} grpc=${GS_P4_GRPC_ADDR}"
fi
if [[ "$EDGE_DATAPLANE" == "container_bmv2_inline" || "$GS_BMV2_ENABLED" == "1" ]]; then
  log "bmv2_ports = local ${BMV2_LOCAL_PORT}@${BMV2_LOCAL_IF}, air ${BMV2_AIR_PORT}@${BMV2_AIR_IF}, cpu ${BMV2_CPU_PORT}"
fi
if [[ "$EDGE_DATAPLANE" == "container_bmv2_inline" && "$P4_CLUSTER_HEAD_ROUTES" == "1" ]]; then
  log "p4_routes = ${P4_ROUTING_MODE} heads=${P4_CLUSTER_HEADS}"
fi
if [[ "$EXPERIMENT_MODE" == "l3_mesh" ]]; then
  log "gs_gateway = $GS_GATEWAY_IP"
fi
log "gs_ips    = $GS_IP_COUNT"
for ((i=0; i<GS_IP_COUNT; ++i)); do
  eval "GS_IP_ITEM=\${GS_IP_${i}}"
  log "  gs_ip[$i]=${GS_IP_ITEM}"
done
log "uavs      = $UAV_COUNT"
FORWARD_RULE_COMMENT="ucs-mesh-${SCENARIO_ID}"
BMV2_RUNTIME_DIR="/tmp/ucs-mesh-${UID}/${SCENARIO_ID}/bmv2"
BMV2_PID_PREFIX="/tmp/ucs_mesh_bmv2_${SCENARIO_ID}"
HOST_EXP_IF="$TAP_LEFT"
if [[ "$GS_BMV2_ENABLED" == "1" ]]; then
  HOST_EXP_IF="$GS_APP_IF"
fi

for ((i=0; i<UAV_COUNT; ++i)); do
  eval "UAV_ID=\${UAV_ID_${i}}"
  eval "CLUSTER_ID=\${CLUSTER_ID_${i}}"
  eval "UAV_CONTAINER=\${UAV_CONTAINER_${i}}"
  eval "TAP_RIGHT=\${TAP_RIGHT_${i}}"
  eval "BRIDGE=\${BRIDGE_${i}}"
  eval "VETH_HOST=\${VETH_HOST_${i}}"
  eval "VETH_CT=\${VETH_CT_${i}}"
  eval "UAV_IP=\${UAV_IP_${i}}"
  eval "EXP_IF=\${EXP_IF_${i}}"
  eval "UAV_ENDPOINT_MAC=\${UAV_ENDPOINT_MAC_${i}}"
  eval "GS_NEXT_HOP=\${GS_NEXT_HOP_${i}}"
  eval "P4_DEVICE_ID=\${P4_DEVICE_ID_${i}}"
  eval "P4_GRPC_ADDR=\${P4_GRPC_ADDR_${i}}"

  log "uav[$i] id=${UAV_ID} cluster=${CLUSTER_ID} container=${UAV_CONTAINER} tap=${TAP_RIGHT} bridge=${BRIDGE} veth_host=${VETH_HOST} veth_ct=${VETH_CT} ${EXP_IF}=${UAV_IP} mac=${UAV_ENDPOINT_MAC} via=${GS_NEXT_HOP} p4_device=${P4_DEVICE_ID} p4_grpc=${P4_GRPC_ADDR}"
  eval "ROUTE_COUNT=\${ROUTE_COUNT_${i}}"
  for ((j=0; j<ROUTE_COUNT; ++j)); do
    eval "ROUTE_DST=\${ROUTE_DST_${i}_${j}}"
    eval "ROUTE_VIA=\${ROUTE_VIA_${i}_${j}}"
    eval "ROUTE_KIND=\${ROUTE_KIND_${i}_${j}}"
    if [[ -n "$ROUTE_VIA" ]]; then
      vlog "  route[$i:$j] ${ROUTE_DST} via ${ROUTE_VIA} dev ${EXP_IF} kind=${ROUTE_KIND}"
    else
      vlog "  route[$i:$j] ${ROUTE_DST} dev ${EXP_IF} scope link kind=${ROUTE_KIND}"
    fi
  done
done

if [[ "$DRY_RUN" -eq 1 ]]; then
  log "dry-run only; exiting before sudo / tap wait / ns-3 run"
  exit 0
fi

if [[ -n "$READY_FILE" ]]; then
  rm -f "$READY_FILE"
fi

for ((i=0; i<UAV_COUNT; ++i)); do
  eval "UAV_CONTAINER=\${UAV_CONTAINER_${i}}"
  PID="$(docker inspect -f '{{.State.Pid}}' "$UAV_CONTAINER" 2>/dev/null || true)"
  if [[ -z "${PID}" || "${PID}" == "0" ]]; then
    echo "[ns3_live_up][ERR] container not running or not found: $UAV_CONTAINER" >&2
    mark_failed
    exit 1
  fi
  vlog "container ${UAV_CONTAINER} pid=${PID}"
done

if [[ "$SUDO_READY" -eq 1 ]]; then
  if ! sudo -n true; then
    echo "[ns3_live_up][ERR] sudo credential is not available; caller should run sudo -v first" >&2
    mark_failed
    exit 1
  fi
else
  if ! sudo -v; then
    mark_failed
    exit 1
  fi
fi

wait_link_up() {
  local ifname="$1"
  local deadline=$((SECONDS + WAIT_TIMEOUT_SEC))
  while (( SECONDS < deadline )); do
    if ip link show "$ifname" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.05
  done
  return 1
}

prepare_tap() {
  local ifname="$1"
  local flush_addr="${2:-0}"

  try_sysctl "net.ipv6.conf.${ifname}.disable_ipv6=1"
  s ip link set "$ifname" up
  s ip link set "$ifname" txqueuelen "$TXQLEN"
  disable_link_offload "$ifname"
  s tc qdisc replace dev "$ifname" root pfifo limit "$PFIFO_LIMIT"
  if [[ "$flush_addr" == "1" ]]; then
    s ip addr flush dev "$ifname"
  fi
}

disable_link_offload() {
  local ifname="$1"

  if ! command -v ethtool >/dev/null 2>&1; then
    return 0
  fi

  # BMv2 reads and writes raw packets before Linux can complete veth checksum
  # offloads. Leave packets fully checksummed before they enter simple_switch.
  s ethtool -K "$ifname" tx off tso off gso off gro off >/dev/null 2>&1 || true
}

configure_host_gs_bmv2_inline() {
  [[ "$GS_BMV2_ENABLED" == "1" ]] || return 0

  if [[ "$GS_APP_IF" == "$GS_AIR_IF" || "$GS_LOCAL_IF" == "$GS_AIR_IF" ]]; then
    echo "[ns3_live_up][ERR] GS BMv2 app/local interfaces must not reuse ${GS_AIR_IF}" >&2
    return 1
  fi

  s ip link del "$GS_APP_IF" 2>/dev/null || true
  s ip link del "$GS_LOCAL_IF" 2>/dev/null || true

  s ip link add "$GS_APP_IF" type veth peer name "$GS_LOCAL_IF"
  s ip link set "$GS_APP_IF" address "$GS_ENDPOINT_MAC"
  quiet_host_l2_if "$GS_AIR_IF"
  quiet_host_l2_if "$GS_LOCAL_IF"
  s ip link set "$GS_APP_IF" up
  s ip link set "$GS_LOCAL_IF" up
  s ip link set "$GS_LOCAL_IF" promisc on
  s ip link set "$GS_APP_IF" txqueuelen "$TXQLEN" >/dev/null 2>&1 || true
  s ip link set "$GS_LOCAL_IF" txqueuelen "$TXQLEN" >/dev/null 2>&1 || true
  s tc qdisc replace dev "$GS_APP_IF" root pfifo limit "$PFIFO_LIMIT" 2>/dev/null || true
  s tc qdisc replace dev "$GS_LOCAL_IF" root pfifo limit "$PFIFO_LIMIT" 2>/dev/null || true
  disable_link_offload "$GS_APP_IF"
  disable_link_offload "$GS_LOCAL_IF"

  for ((i=0; i<GS_IP_COUNT; ++i)); do
    eval "GS_IP_ITEM=\${GS_IP_${i}}"
    s ip addr add "$GS_IP_ITEM" dev "$GS_APP_IF"
  done

  try_sysctl "net.ipv4.conf.${GS_APP_IF}.rp_filter=0"
  try_sysctl "net.ipv4.conf.${GS_LOCAL_IF}.rp_filter=0"
  try_sysctl "net.ipv6.conf.${GS_APP_IF}.disable_ipv6=1"
  try_sysctl "net.ipv6.conf.${GS_LOCAL_IF}.disable_ipv6=1"

  log "configured host GS BMv2 inline: ${GS_APP_IF}(${GS_ENDPOINT_MAC})<->${GS_LOCAL_IF}, ${GS_AIR_IF}->ns3"
}

start_host_gs_bmv2() {
  [[ "$GS_BMV2_ENABLED" == "1" ]] || return 0

  docker rm -f "$GS_BMV2_CONTAINER" >/dev/null 2>&1 || true
  local docker_cpuset_args=()
  mapfile -t docker_cpuset_args < <(ucs_docker_cpuset_args GS_BMV2 0)
  docker run -d --rm \
    --name "$GS_BMV2_CONTAINER" \
    --network host \
    --privileged \
    "${docker_cpuset_args[@]}" \
    --entrypoint bash \
    "$GS_BMV2_IMAGE" \
    -lc "exec simple_switch_grpc \
      --device-id '$GS_P4_DEVICE_ID' \
      --no-p4 \
      -i '$BMV2_LOCAL_PORT@$GS_LOCAL_IF' \
      -i '$BMV2_AIR_PORT@$GS_AIR_IF' \
      -- \
      --grpc-server-addr '$GS_P4_GRPC_ADDR' \
      --cpu-port '$BMV2_CPU_PORT'" >/dev/null
  sleep 0.3
  if ! docker inspect -f '{{.State.Running}}' "$GS_BMV2_CONTAINER" 2>/dev/null | grep -qx true; then
    docker logs "$GS_BMV2_CONTAINER" 2>/dev/null || true
    echo "[ns3_live_up][ERR] failed to start GS BMv2 edge container: ${GS_BMV2_CONTAINER}" >&2
    return 1
  fi
  local gs_cpuset
  gs_cpuset="$(ucs_cpu_set GS_BMV2 0 2>/dev/null || true)"
  if [[ -n "$gs_cpuset" ]]; then
    if ucs_docker_wait_update_cpuset "$GS_BMV2_CONTAINER" GS_BMV2 0 10 0.2; then
      log "cpu affinity container ${GS_BMV2_CONTAINER} = ${gs_cpuset}"
    else
      log "cpu affinity container ${GS_BMV2_CONTAINER} = skipped (docker update failed)"
    fi
  fi

  log "started host GS BMv2 edge: container=${GS_BMV2_CONTAINER} device=${GS_P4_DEVICE_ID} grpc=${GS_P4_GRPC_ADDR} ports=${BMV2_LOCAL_PORT}:${GS_LOCAL_IF},${BMV2_AIR_PORT}:${GS_AIR_IF}"
}

stop_host_gs_bmv2() {
  [[ "$GS_BMV2_ENABLED" == "1" ]] || return 0
  docker rm -f "$GS_BMV2_CONTAINER" >/dev/null 2>&1 || true
}

ensure_tap_forward_rule() {
  if ! command -v iptables >/dev/null 2>&1; then
    echo "[ns3_live_up][W] iptables not found; skip explicit ${TAP_LEFT}->${TAP_LEFT} FORWARD accept rule" >&2
    return 0
  fi

  if s iptables -C FORWARD -i "$TAP_LEFT" -o "$TAP_LEFT" -m comment --comment "$FORWARD_RULE_COMMENT" -j ACCEPT 2>/dev/null; then
    vlog "iptables FORWARD rule already present for ${TAP_LEFT}->${TAP_LEFT}"
    return 0
  fi

  if s iptables -I FORWARD 1 -i "$TAP_LEFT" -o "$TAP_LEFT" -m comment --comment "$FORWARD_RULE_COMMENT" -j ACCEPT 2>/dev/null; then
    log "installed iptables FORWARD accept rule for ${TAP_LEFT}->${TAP_LEFT}"
    return 0
  fi

  s iptables -I FORWARD 1 -i "$TAP_LEFT" -o "$TAP_LEFT" -j ACCEPT
  log "installed iptables FORWARD accept rule for ${TAP_LEFT}->${TAP_LEFT} without comment match"
}

ensure_bmv2_container_tools() {
  [[ "$EDGE_DATAPLANE" == "container_bmv2_inline" ]] || return 0

  if ! command -v ethtool >/dev/null 2>&1; then
    echo "[ns3_live_up][W] ethtool not found on host; BMv2 inline UDP traffic may suffer checksum-offload drops" >&2
  fi

  if [[ "$GS_BMV2_ENABLED" == "1" ]]; then
    if ! docker image inspect "$GS_BMV2_IMAGE" >/dev/null 2>&1; then
      echo "[ns3_live_up][ERR] GS BMv2 image not found: ${GS_BMV2_IMAGE}" >&2
      echo "[ns3_live_up][ERR] build/reuse a BMv2 runtime image before enabling GS BMv2 edge" >&2
      return 1
    fi
  fi

  local container
  for ((i=0; i<UAV_COUNT; ++i)); do
    eval "container=\${UAV_CONTAINER_${i}}"
    if ! docker exec "$container" sh -lc 'command -v simple_switch_grpc >/dev/null 2>&1'; then
      echo "[ns3_live_up][ERR] container ${container} is missing simple_switch_grpc" >&2
      echo "[ns3_live_up][ERR] install BMv2 inside the UAV image before enabling container_bmv2_inline" >&2
      return 1
    fi
  done
}

container_bmv2_pidfile() {
  local endpoint="$1"
  printf '%s_%s.pid' "$BMV2_PID_PREFIX" "$endpoint"
}

container_bmv2_logfile() {
  local endpoint="$1"
  printf '%s_%s.log' "$BMV2_PID_PREFIX" "$endpoint"
}

configure_container_bmv2_inline() {
  local endpoint="$1"
  local pid="$2"
  local veth_ct="$3"
  local exp_if="$4"
  local uav_ip="$5"
  local endpoint_mac="$6"

  [[ "$EDGE_DATAPLANE" == "container_bmv2_inline" ]] || return 0

  s nsenter -t "$pid" -n bash -lc "
set -Eeuo pipefail
for dev in '$BMV2_LOCAL_IF' '$BMV2_AIR_IF' '$exp_if'; do
  if ip link show \"\$dev\" >/dev/null 2>&1; then
    ip link del \"\$dev\"
  fi
done
ip link set '$veth_ct' name '$BMV2_AIR_IF'
ip link set '$BMV2_AIR_IF' up
ip link set '$BMV2_AIR_IF' arp off
ip link set '$BMV2_AIR_IF' promisc on
ip link set '$BMV2_AIR_IF' txqueuelen '$TXQLEN' >/dev/null 2>&1 || true
ip link add '$exp_if' type veth peer name '$BMV2_LOCAL_IF'
ip link set '$exp_if' address '$endpoint_mac'
ip link set '$exp_if' up
ip link set '$BMV2_LOCAL_IF' up
ip link set '$BMV2_LOCAL_IF' arp off
ip link set '$BMV2_LOCAL_IF' promisc on
ip link set '$exp_if' txqueuelen '$TXQLEN' >/dev/null 2>&1 || true
ip link set '$BMV2_LOCAL_IF' txqueuelen '$TXQLEN' >/dev/null 2>&1 || true
for dev in '$exp_if' '$BMV2_LOCAL_IF' '$BMV2_AIR_IF'; do
  if command -v ethtool >/dev/null 2>&1; then
    ethtool -K \"\$dev\" tx off tso off gso off gro off >/dev/null 2>&1 || true
  fi
done
ip addr flush dev '$exp_if'
ip addr add '$uav_ip' dev '$exp_if'
sysctl -w net.ipv4.conf.'$exp_if'.arp_ignore=0 >/dev/null 2>&1 || true
sysctl -w net.ipv4.conf.'$exp_if'.arp_announce=2 >/dev/null 2>&1 || true
sysctl -w net.ipv4.conf.'$exp_if'.rp_filter=0 >/dev/null 2>&1 || true
for dev in '$BMV2_LOCAL_IF' '$BMV2_AIR_IF'; do
  sysctl -w net.ipv4.conf.\${dev}.arp_ignore=8 >/dev/null 2>&1 || true
  sysctl -w net.ipv4.conf.\${dev}.arp_announce=2 >/dev/null 2>&1 || true
  sysctl -w net.ipv4.conf.\${dev}.proxy_arp=0 >/dev/null 2>&1 || true
  sysctl -w net.ipv4.conf.\${dev}.proxy_arp_pvlan=0 >/dev/null 2>&1 || true
  sysctl -w net.ipv4.conf.\${dev}.arp_accept=0 >/dev/null 2>&1 || true
  sysctl -w net.ipv4.conf.\${dev}.rp_filter=0 >/dev/null 2>&1 || true
  sysctl -w net.ipv6.conf.\${dev}.disable_ipv6=1 >/dev/null 2>&1 || true
done
sysctl -w net.ipv4.conf.'$BMV2_AIR_IF'.rp_filter=0 >/dev/null 2>&1 || true
sysctl -w net.ipv6.conf.'$exp_if'.disable_ipv6=1 >/dev/null 2>&1 || true
sysctl -w net.ipv6.conf.'$BMV2_LOCAL_IF'.disable_ipv6=1 >/dev/null 2>&1 || true
sysctl -w net.ipv6.conf.'$BMV2_AIR_IF'.disable_ipv6=1 >/dev/null 2>&1 || true
"

  vlog "configured in-container BMv2 inline interfaces for ${endpoint}: ${exp_if}(${endpoint_mac})<->${BMV2_LOCAL_IF}, ${BMV2_AIR_IF}->ns3"
}

start_container_bmv2() {
  local endpoint="$1"
  local container="$2"
  local device_id="$3"
  local grpc_addr="$4"
  local pid_file
  local log_file
  local endpoint_idx

  [[ "$EDGE_DATAPLANE" == "container_bmv2_inline" ]] || return 0

  pid_file="$(container_bmv2_pidfile "$endpoint")"
  log_file="$(container_bmv2_logfile "$endpoint")"
  endpoint_idx="${endpoint//[!0-9]/}"
  ucs_docker_update_cpuset "$container" UAV "$endpoint_idx" 2>/dev/null || true

  docker exec "$container" bash -lc "
set -Eeuo pipefail
if [[ -f '$pid_file' ]]; then
  old_pid=\"\$(cat '$pid_file' 2>/dev/null || true)\"
  if [[ -n \"\$old_pid\" ]] && kill -0 \"\$old_pid\" 2>/dev/null; then
    kill \"\$old_pid\" 2>/dev/null || true
    sleep 0.2
    kill -0 \"\$old_pid\" 2>/dev/null && kill -9 \"\$old_pid\" 2>/dev/null || true
  fi
fi
rm -f '$pid_file' '$log_file'
nohup simple_switch_grpc \
  --device-id '$device_id' \
  --no-p4 \
  -i '$BMV2_LOCAL_PORT@$BMV2_LOCAL_IF' \
  -i '$BMV2_AIR_PORT@$BMV2_AIR_IF' \
  -- \
  --grpc-server-addr '$grpc_addr' \
  --cpu-port '$BMV2_CPU_PORT' \
  >'$log_file' 2>&1 < /dev/null &
echo \$! > '$pid_file'
sleep 0.2
new_pid=\"\$(cat '$pid_file')\"
kill -0 \"\$new_pid\"
"

  log "started in-container BMv2 ${endpoint}: device=${device_id} grpc=${grpc_addr} ports=${BMV2_LOCAL_PORT}:${BMV2_LOCAL_IF},${BMV2_AIR_PORT}:${BMV2_AIR_IF}"
}

stop_bmv2_switches() {
  [[ "$EDGE_DATAPLANE" == "container_bmv2_inline" ]] || return 0

  local endpoint container pid_file
  for ((i=0; i<UAV_COUNT; ++i)); do
    eval "endpoint=\${UAV_ID_${i}}"
    eval "container=\${UAV_CONTAINER_${i}}"
    pid_file="$(container_bmv2_pidfile "$endpoint")"
    docker exec "$container" bash -lc "
set +e
if [[ -f '$pid_file' ]]; then
  pid=\"\$(cat '$pid_file' 2>/dev/null || true)\"
  if [[ -n \"\$pid\" ]] && kill -0 \"\$pid\" 2>/dev/null; then
    kill \"\$pid\" 2>/dev/null || true
    sleep 0.2
    kill -0 \"\$pid\" 2>/dev/null && kill -9 \"\$pid\" 2>/dev/null || true
  fi
  rm -f '$pid_file'
fi
" >/dev/null 2>&1 || true
  done
}

run_bmv2_controller_hook() {
  [[ "$EDGE_DATAPLANE" == "container_bmv2_inline" ]] || return 0

  if [[ -n "${UCS_MESH_BMV2_CONTROLLER_HOOK:-}" ]]; then
    log "running BMv2 controller hook before ARP warm-up ..."
    TOPOLOGY_FILE="$TOPOLOGY_FILE" \
      SCENARIO_ID="$SCENARIO_ID" \
      UCS_MESH_EDGE_DATAPLANE="$EDGE_DATAPLANE" \
      bash -lc "$UCS_MESH_BMV2_CONTROLLER_HOOK"
  elif [[ "${UCS_MESH_BMV2_AUTO_LOAD_PIPELINE:-1}" == "1" ]]; then
    log "loading BMv2 pipeline over observation network before ARP warm-up ..."
    hook_args=(--topology "$TOPOLOGY_FILE")
    if [[ "$GS_BMV2_ENABLED" == "1" ]]; then
      hook_args+=(--include-gs --gs-app-if "$GS_APP_IF" --gs-device-id "$GS_P4_DEVICE_ID" --gs-grpc-addr "$GS_P4_GRPC_ADDR")
    fi
    if [[ "$P4_CLUSTER_HEAD_ROUTES" == "1" ]]; then
      hook_args+=(--cluster-head-routes)
      if [[ -n "$P4_CLUSTER_HEADS" ]]; then
        hook_args+=(--cluster-heads "$P4_CLUSTER_HEADS")
      fi
    fi
    if [[ "$VERBOSE" -eq 1 ]]; then
      hook_args+=(--verbose)
    fi
    "$MESH_DIR/p4/load_pipeline_observation.sh" "${hook_args[@]}"
  else
    log "BMv2 simple_switch_grpc started with --no-p4; pipeline auto-load disabled"
  fi
}

warm_experiment_neighbors() {
  log "warming experiment-net neighbors ..."

  for ((i=0; i<UAV_COUNT; ++i)); do
    eval "UAV_IP_ADDR=\${UAV_IP_ADDR_${i}}"
    ping -c 1 -W 1 "$UAV_IP_ADDR" >/dev/null 2>&1 || true
  done

  for ((i=0; i<UAV_COUNT; ++i)); do
    eval "UAV_CONTAINER=\${UAV_CONTAINER_${i}}"
    eval "EXP_IF=\${EXP_IF_${i}}"
    eval "GS_NEXT_HOP=\${GS_NEXT_HOP_${i}}"

    PID="$(docker inspect -f '{{.State.Pid}}' "$UAV_CONTAINER" 2>/dev/null || true)"
    if [[ -z "${PID}" || "${PID}" == "0" ]]; then
      continue
    fi

    if [[ -n "$GS_NEXT_HOP" ]]; then
      s nsenter -t "$PID" -n bash -lc "
if command -v ping >/dev/null 2>&1; then
  ping -c 1 -W 1 '$GS_NEXT_HOP' -I '$EXP_IF' >/dev/null 2>&1 || true
fi
"
    fi

    eval "ROUTE_COUNT=\${ROUTE_COUNT_${i}}"
    for ((j=0; j<ROUTE_COUNT; ++j)); do
      eval "ROUTE_DST=\${ROUTE_DST_${i}_${j}}"
      eval "ROUTE_VIA=\${ROUTE_VIA_${i}_${j}}"
      if [[ "$ROUTE_DST" != */32 ]]; then
        continue
      fi
      PEER_IP="${ROUTE_DST%/32}"
      s nsenter -t "$PID" -n bash -lc "
if command -v ping >/dev/null 2>&1; then
  ping -c 1 -W 1 '$PEER_IP' -I '$EXP_IF' >/dev/null 2>&1 || true
fi
"
    done
  done
}

net_setup_all() {
  set -Eeuo pipefail

  vlog "background net_setup_all: waiting for $TAP_LEFT ..."
  wait_link_up "$TAP_LEFT" || {
    echo "[ns3_live_up][ERR] tap device not found in time: $TAP_LEFT" >&2
    return 1
  }

  for ((i=0; i<UAV_COUNT; ++i)); do
    eval "TAP_RIGHT=\${TAP_RIGHT_${i}}"
    vlog "background net_setup_all: waiting for ${TAP_RIGHT} ..."
    wait_link_up "$TAP_RIGHT" || {
      echo "[ns3_live_up][ERR] tap device not found in time: $TAP_RIGHT" >&2
      return 1
    }
  done

  log "all tap devices are present; phase-1 preparing taps ..."

  # Phase 1: prepare ALL taps first, before any bridge/veth wiring.
  prepare_tap "$TAP_LEFT" 1
  for ((i=0; i<UAV_COUNT; ++i)); do
    eval "TAP_RIGHT=\${TAP_RIGHT_${i}}"
    prepare_tap "$TAP_RIGHT" 1
  done

  # Only after every tap is up/ready, assign GS experiment IPs. With a GS BMv2
  # edge, tap-gs is the air-side port and the host IP lives on gs0.
  if [[ "$GS_BMV2_ENABLED" == "1" ]]; then
    configure_host_gs_bmv2_inline
    start_host_gs_bmv2
  else
    s ip link set "$TAP_LEFT" address "$GS_ENDPOINT_MAC"
    for ((i=0; i<GS_IP_COUNT; ++i)); do
      eval "GS_IP_ITEM=\${GS_IP_${i}}"
      s ip addr add "$GS_IP_ITEM" dev "$TAP_LEFT"
    done
  fi

  try_sysctl net.ipv4.conf.all.rp_filter=0
  try_sysctl net.ipv4.conf.default.rp_filter=0
  try_sysctl "net.ipv4.conf.${TAP_LEFT}.rp_filter=0"
  try_sysctl net.ipv4.conf.all.send_redirects=0
  try_sysctl net.ipv4.conf.default.send_redirects=0
  try_sysctl "net.ipv4.conf.${TAP_LEFT}.send_redirects=0"

  if [[ "$EXPERIMENT_MODE" == "l3_star" ]]; then
    # L3 star uses the host/GS as the visible inter-subnet forwarder.
    s sysctl -w net.ipv4.ip_forward=1 >/dev/null
    ensure_tap_forward_rule
  else
    # Stage 2 routes host subnet reachability via the ns-3 GS edge router.
    # Stage 3 installs direct on-link host routes so GS ARPs for real UAV IPs.
    for ((i=0; i<HOST_ROUTE_COUNT; ++i)); do
      eval "HOST_ROUTE_DST=\${HOST_ROUTE_DST_${i}}"
      eval "HOST_ROUTE_VIA=\${HOST_ROUTE_VIA_${i}}"
      eval "HOST_ROUTE_KIND=\${HOST_ROUTE_KIND_${i}}"
      if [[ -n "$HOST_ROUTE_VIA" ]]; then
        s ip route replace "$HOST_ROUTE_DST" via "$HOST_ROUTE_VIA" dev "$HOST_EXP_IF"
        vlog "configured host route: ${HOST_ROUTE_DST} via ${HOST_ROUTE_VIA} dev ${HOST_EXP_IF} kind=${HOST_ROUTE_KIND}"
      else
        s ip route replace "$HOST_ROUTE_DST" dev "$HOST_EXP_IF" scope link
        vlog "configured host route: ${HOST_ROUTE_DST} dev ${HOST_EXP_IF} scope link kind=${HOST_ROUTE_KIND}"
      fi
    done
  fi

  # Small settle window to avoid racing immediately into bridge writes.
  sleep 0.2

  log "phase-2 wiring edge dataplane/veth/netns ..."

  for ((i=0; i<UAV_COUNT; ++i)); do
    eval "UAV_ID=\${UAV_ID_${i}}"
    eval "UAV_CONTAINER=\${UAV_CONTAINER_${i}}"
    eval "TAP_RIGHT=\${TAP_RIGHT_${i}}"
    eval "BRIDGE=\${BRIDGE_${i}}"
    eval "VETH_HOST=\${VETH_HOST_${i}}"
    eval "VETH_CT=\${VETH_CT_${i}}"
    eval "UAV_IP=\${UAV_IP_${i}}"
    eval "EXP_IF=\${EXP_IF_${i}}"
    eval "UAV_ENDPOINT_MAC=\${UAV_ENDPOINT_MAC_${i}}"
    eval "GS_NEXT_HOP=\${GS_NEXT_HOP_${i}}"

    PID="$(docker inspect -f '{{.State.Pid}}' "$UAV_CONTAINER")"

    vlog "configuring ${UAV_ID}: tap=${TAP_RIGHT} bridge=${BRIDGE} edge_dp=${EDGE_DATAPLANE} ${EXP_IF}=${UAV_IP} mac=${UAV_ENDPOINT_MAC} via=${GS_NEXT_HOP}"

    s ip link del "$BRIDGE" 2>/dev/null || true
    s ip link del "$VETH_HOST" 2>/dev/null || true

    s ip link add "$BRIDGE" type bridge
    quiet_host_l2_if "$BRIDGE"
    quiet_host_l2_if "$TAP_RIGHT"
    s ip link set "$BRIDGE" up
    s ip link set "$TAP_RIGHT" master "$BRIDGE"

    s ip link add "$VETH_HOST" type veth peer name "$VETH_CT"
    quiet_host_l2_if "$VETH_HOST"
    s ip link set "$VETH_HOST" master "$BRIDGE"
    s ip link set "$VETH_HOST" up
    s ip link set "$VETH_CT" netns "$PID"

    if [[ "$EDGE_DATAPLANE" == "container_bmv2_inline" ]]; then
      configure_container_bmv2_inline "$UAV_ID" "$PID" "$VETH_CT" "$EXP_IF" "$UAV_IP" "$UAV_ENDPOINT_MAC"
    else
      s nsenter -t "$PID" -n bash -lc "
set -Eeuo pipefail
if ip link show '$EXP_IF' >/dev/null 2>&1; then
  ip link del '$EXP_IF'
fi
ip link set '$VETH_CT' name '$EXP_IF'
ip link set '$EXP_IF' address '$UAV_ENDPOINT_MAC'
ip link set '$EXP_IF' up
ip addr flush dev '$EXP_IF'
ip addr add '$UAV_IP' dev '$EXP_IF'
sysctl -w net.ipv4.conf.'$EXP_IF'.rp_filter=0 >/dev/null 2>&1 || true
"
    fi

    eval "ROUTE_COUNT=\${ROUTE_COUNT_${i}}"
    for ((j=0; j<ROUTE_COUNT; ++j)); do
      eval "ROUTE_DST=\${ROUTE_DST_${i}_${j}}"
      eval "ROUTE_VIA=\${ROUTE_VIA_${i}_${j}}"
      eval "ROUTE_KIND=\${ROUTE_KIND_${i}_${j}}"
      if [[ -n "$ROUTE_VIA" ]]; then
        s nsenter -t "$PID" -n ip route replace "$ROUTE_DST" via "$ROUTE_VIA" dev "$EXP_IF"
        vlog "configured route in ${UAV_CONTAINER}: ${ROUTE_DST} via ${ROUTE_VIA} dev ${EXP_IF} kind=${ROUTE_KIND}"
      else
        s nsenter -t "$PID" -n ip route replace "$ROUTE_DST" dev "$EXP_IF" scope link
        vlog "configured route in ${UAV_CONTAINER}: ${ROUTE_DST} dev ${EXP_IF} scope link kind=${ROUTE_KIND}"
      fi
    done

    if [[ "$EDGE_DATAPLANE" == "container_bmv2_inline" ]]; then
      eval "P4_DEVICE_ID=\${P4_DEVICE_ID_${i}}"
      eval "P4_GRPC_ADDR=\${P4_GRPC_ADDR_${i}}"
      start_container_bmv2 "$UAV_ID" "$UAV_CONTAINER" "$P4_DEVICE_ID" "$P4_GRPC_ADDR"
    fi

    vlog "configured ${UAV_CONTAINER} ${EXP_IF}=${UAV_IP}"
  done

  run_bmv2_controller_hook
  warm_experiment_neighbors

  log "network plumbing ready"
}

net_setup_all_with_status() {
  if net_setup_all; then
    mark_ready
  else
    local rc="$?"
    mark_failed
    return "$rc"
  fi
}

if [[ "$PLUMB_ONLY" -eq 1 ]]; then
  log "plumb-only mode: configuring existing tap/bridge/veth/routes; ns-3 will not be started"
  net_setup_all_with_status
  exit 0
fi

NETSETUP_PID=""
NS3_RUN_PID=""
NETSETUP_RC_FILE="$(mktemp /tmp/ucs_mesh_netsetup.XXXXXX.rc)"
NS3_RC_FILE="$(mktemp /tmp/ucs_mesh_ns3_run.XXXXXX.rc)"
cleanup() {
  set +e
  stop_host_gs_bmv2
  stop_bmv2_switches
  if [[ -n "${NETSETUP_PID}" ]]; then
    kill "${NETSETUP_PID}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${NS3_RUN_PID}" ]]; then
    kill "${NS3_RUN_PID}" >/dev/null 2>&1 || true
  fi
  rm -f "$RUNTIME_SH" "$NETSETUP_RC_FILE" "$NS3_RC_FILE"
}
trap cleanup EXIT INT TERM

ensure_ns3_scratch_suid || {
  mark_failed
  exit 1
}

ensure_bmv2_container_tools || {
  mark_failed
  exit 1
}

(
  set +e
  net_setup_all_with_status
  rc="$?"
  printf '%s\n' "$rc" > "$NETSETUP_RC_FILE"
  exit "$rc"
) &
NETSETUP_PID="$!"
vlog "background net_setup_all pid=${NETSETUP_PID}"

log "starting ns-3 live in foreground ..."
NS3_RUN_ARGS="scratch/${SCRATCH} --topologyFile=${TOPOLOGY_FILE} --live=1"
if [[ "$VERBOSE" -eq 1 ]]; then
  NS3_RUN_ARGS+=" --verboseOverride=1"
fi
(
  set +e
  cd "$NS3_DIR"
  ./ns3 run "$NS3_RUN_ARGS"
  rc="$?"
  printf '%s\n' "$rc" > "$NS3_RC_FILE"
  exit "$rc"
) &
NS3_RUN_PID="$!"

while true; do
  if [[ -s "$NETSETUP_RC_FILE" ]]; then
    NETSETUP_RC="$(cat "$NETSETUP_RC_FILE" 2>/dev/null || echo 1)"
    wait "$NETSETUP_PID" >/dev/null 2>&1 || true
    NETSETUP_PID=""
    if [[ "$NETSETUP_RC" != "0" ]]; then
      echo "[ns3_live_up][ERR] network setup failed; stopping ns-3 live runner" >&2
      mark_failed
      if [[ -n "${NS3_RUN_PID}" ]]; then
        kill "$NS3_RUN_PID" >/dev/null 2>&1 || true
        wait "$NS3_RUN_PID" >/dev/null 2>&1 || true
        NS3_RUN_PID=""
      fi
      exit "$NETSETUP_RC"
    fi
    vlog "background net_setup_all completed successfully"
    break
  fi

  if [[ -s "$NS3_RC_FILE" ]]; then
    NS3_RC="$(cat "$NS3_RC_FILE" 2>/dev/null || echo 1)"
    wait "$NS3_RUN_PID" >/dev/null 2>&1 || true
    NS3_RUN_PID=""
    if [[ -n "${NETSETUP_PID}" ]]; then
      kill "$NETSETUP_PID" >/dev/null 2>&1 || true
      wait "$NETSETUP_PID" >/dev/null 2>&1 || true
      NETSETUP_PID=""
    fi
    exit "$NS3_RC"
  fi

  sleep 0.2
done

if wait "$NS3_RUN_PID"; then
  NS3_RC=0
else
  NS3_RC="$?"
fi
NS3_RUN_PID=""
exit "$NS3_RC"
