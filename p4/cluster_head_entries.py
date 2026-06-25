#!/usr/bin/env python3
"""Generate P4Runtime table entries for the UCS cluster-head routing smoke.

The generated entries do not change Linux routes. Linux keeps ordinary on-link
reachability; BMv2 rewrites the Ethernet next hop at each programmable edge.
"""

from __future__ import annotations

import argparse
import ipaddress
import json
import os
import subprocess
from pathlib import Path


TABLE = "IngressImpl.ipv4_lpm"
ACTION = "IngressImpl.set_nhop"
MATCH_FIELD = "hdr.ipv4.dst_addr"
PARAM_DST_MAC = "dst_mac"
PARAM_SRC_MAC = "src_mac"
PARAM_PORT = "port"
DEFAULT_AIR_PORT = 2


def cidr_ip(cidr: str) -> str:
    return str(ipaddress.ip_interface(cidr).ip)


def read_host_mac(ifname: str) -> str:
    path = Path("/sys/class/net") / ifname / "address"
    return path.read_text(encoding="utf-8").strip().lower()


def read_container_mac(container: str, ifname: str) -> str:
    cmd = ["docker", "exec", container, "cat", f"/sys/class/net/{ifname}/address"]
    return subprocess.check_output(cmd, text=True).strip().lower()


def parse_cluster_heads(value: str) -> dict[int, str]:
    result: dict[int, str] = {}
    if not value:
        return result
    for item in value.split(","):
        item = item.strip()
        if not item:
            continue
        if ":" not in item:
            raise ValueError(f"bad cluster-head item: {item!r}; expected CLUSTER:UAV_ID")
        cluster_raw, head_id = item.split(":", 1)
        result[int(cluster_raw)] = head_id.strip()
    return result


def resolve_air_port(topo: dict) -> int:
    programmable = topo.get("programmable_net", topo.get("globals", {}).get("programmable_net", {}))
    ports = programmable.get("ports", {}) if isinstance(programmable, dict) else {}
    air = ports.get("air", {}) if isinstance(ports, dict) else {}
    topology_port = air.get("port_id", DEFAULT_AIR_PORT) if isinstance(air, dict) else DEFAULT_AIR_PORT
    return int(os.environ.get("UCS_MESH_BMV2_AIR_PORT", topology_port))


def table_entry(dst_ip: str, dst_mac: str, src_mac: str, port: int) -> dict:
    return {
        "table": TABLE,
        "match": {
            MATCH_FIELD: f"{dst_ip}/32",
        },
        "action": ACTION,
        "params": {
            PARAM_DST_MAC: dst_mac,
            PARAM_SRC_MAC: src_mac,
            PARAM_PORT: str(port),
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Generate BMv2 cluster-head routing table entries"
    )
    parser.add_argument("--topology", required=True)
    parser.add_argument("--target-id", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--cluster-heads", default="")
    parser.add_argument("--gs-id", default="")
    parser.add_argument("--gs-app-if", default=os.environ.get("UCS_MESH_GS_APP_IF", "gs0"))
    parser.add_argument("--uav-exp-if", default="eth1")
    args = parser.parse_args()

    with open(args.topology, "r", encoding="utf-8") as f:
        topo = json.load(f)

    globals_ = topo.get("globals", {})
    gs_id = args.gs_id or str(globals_.get("gs_id", "gs"))
    air_port = resolve_air_port(topo)

    programmable = topo.get("programmable_net", globals_.get("programmable_net", {}))
    routing = programmable.get("routing", {}) if isinstance(programmable, dict) else {}
    configured_heads = routing.get("cluster_heads", {}) if isinstance(routing, dict) else {}

    cluster_heads = {int(k): str(v) for k, v in configured_heads.items()}
    cluster_heads.update(parse_cluster_heads(args.cluster_heads))
    if not cluster_heads:
        raise SystemExit("[cluster-entries][ERR] no cluster heads configured")

    instances = topo.get("instances", [])
    gs_inst = next((inst for inst in instances if inst.get("id") == gs_id), None)
    if not gs_inst:
        raise SystemExit(f"[cluster-entries][ERR] GS instance not found: {gs_id}")

    uavs = [inst for inst in instances if inst.get("type") == "uav"]
    by_id = {str(inst.get("id")): inst for inst in uavs}

    gs_ip = cidr_ip(str(gs_inst.get("exp_ip") or gs_inst.get("exp_ips", ["10.10.0.254/24"])[0]))
    gs_mac = read_host_mac(args.gs_app_if)

    endpoint_mac: dict[str, str] = {gs_id: gs_mac}
    endpoint_ip: dict[str, str] = {gs_id: gs_ip}
    endpoint_cluster: dict[str, int] = {gs_id: int(gs_inst.get("cluster_id", 0))}

    for inst in uavs:
        uav_id = str(inst.get("id"))
        container = str(inst.get("container_name", uav_id))
        exp_if = str(inst.get("exp_if", args.uav_exp_if))
        endpoint_mac[uav_id] = read_container_mac(container, exp_if)
        endpoint_ip[uav_id] = cidr_ip(str(inst["exp_ip"]))
        endpoint_cluster[uav_id] = int(inst.get("cluster_id", 1))

    for cluster_id, head_id in cluster_heads.items():
        if head_id not in by_id:
            raise SystemExit(
                f"[cluster-entries][ERR] cluster {cluster_id} head is not a UAV: {head_id}"
            )
        head_cluster = int(by_id[head_id].get("cluster_id", -1))
        if head_cluster != cluster_id:
            raise SystemExit(
                f"[cluster-entries][ERR] head {head_id} is in cluster {head_cluster}, "
                f"not {cluster_id}"
            )

    target = args.target_id
    entries: list[dict] = []

    if target == gs_id:
        src_mac = endpoint_mac[gs_id]
        for inst in uavs:
            uav_id = str(inst.get("id"))
            cluster_id = endpoint_cluster[uav_id]
            head_id = cluster_heads.get(cluster_id)
            if not head_id:
                continue
            next_hop_id = head_id
            entries.append(
                table_entry(endpoint_ip[uav_id], endpoint_mac[next_hop_id], src_mac, air_port)
            )
    elif target in by_id:
        cluster_id = endpoint_cluster[target]
        head_id = cluster_heads.get(cluster_id)
        if not head_id:
            entries = []
        elif target == head_id:
            src_mac = endpoint_mac[target]
            entries.append(table_entry(gs_ip, endpoint_mac[gs_id], src_mac, air_port))
            for inst in uavs:
                uav_id = str(inst.get("id"))
                if uav_id == target:
                    continue
                if endpoint_cluster[uav_id] != cluster_id:
                    continue
                entries.append(table_entry(endpoint_ip[uav_id], endpoint_mac[uav_id], src_mac, air_port))
        else:
            src_mac = endpoint_mac[target]
            entries.append(table_entry(gs_ip, endpoint_mac[head_id], src_mac, air_port))
    else:
        raise SystemExit(f"[cluster-entries][ERR] unknown target id: {target}")

    payload = {
        "mode": "cluster_heads",
        "target_id": target,
        "cluster_heads": {str(k): v for k, v in sorted(cluster_heads.items())},
        "air_port": air_port,
        "entries": entries,
    }

    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"[cluster-entries] wrote {output} entries={len(entries)} target={target}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
