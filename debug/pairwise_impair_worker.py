#!/usr/bin/env python3
import argparse
import ipaddress
import json
import math
import os
import random
import re
import shlex
import signal
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional, Tuple


@dataclass
class Endpoint:
    node_id: str
    ip: str
    tap: str


@dataclass
class LinkSpec:
    link_id: str
    src: str
    dst: str
    metrics_file: str
    data_rate: str
    base_delay_ms: float
    loss_min: float
    loss_max: float
    dist_no_loss: float
    dist_max: float
    jitter_per_mps_ms: float
    jitter_max_ms: float
    source: str


@dataclass
class DirectionSpec:
    link: LinkSpec
    src: Endpoint
    dst: Endpoint
    minor: int
    prio: int

    @property
    def classid(self) -> str:
        return f"1:{self.minor}"

    @property
    def handle(self) -> str:
        return f"{self.minor}:"


def die(msg: str) -> None:
    raise SystemExit(f"[pairwise_impair][ERR] {msg}")


def parse_ip(value: str) -> str:
    if "/" in value:
        return str(ipaddress.ip_interface(value).ip)
    return str(ipaddress.ip_address(value))


def parse_time_ms(value: str, fallback_ms: float) -> float:
    if value is None:
        return fallback_ms
    raw = str(value).strip()
    m = re.fullmatch(r"([0-9]+(?:\.[0-9]+)?)\s*(ns|us|ms|s)", raw)
    if not m:
        return fallback_ms
    num = float(m.group(1))
    unit = m.group(2)
    scale = {"ns": 1e-6, "us": 1e-3, "ms": 1.0, "s": 1000.0}[unit]
    return num * scale


def normalize_tc_rate(value: str, fallback: str = "1000mbit") -> str:
    raw = str(value or "").strip()
    m = re.fullmatch(r"([0-9]+(?:\.[0-9]+)?)\s*([kKmMgG]?)(?:bps|bit|b/s)?", raw)
    if not m:
        return fallback

    num = float(m.group(1))
    suffix = m.group(2).lower()
    unit = {"": "bit", "k": "kbit", "m": "mbit", "g": "gbit"}[suffix]
    if num.is_integer():
        return f"{int(num)}{unit}"
    return f"{num:g}{unit}"


def compute_loss(link: LinkSpec, dist: float) -> float:
    if dist <= link.dist_no_loss:
        return link.loss_min
    if dist >= link.dist_max:
        return link.loss_max
    if link.dist_max <= link.dist_no_loss:
        return link.loss_max

    ratio = (dist - link.dist_no_loss) / (link.dist_max - link.dist_no_loss)
    value = link.loss_min + ratio * (link.loss_max - link.loss_min)
    return max(link.loss_min, min(link.loss_max, value))


def compute_delay_ms(link: LinkSpec, speed: float) -> Tuple[float, float]:
    amp = min(abs(speed) * link.jitter_per_mps_ms, link.jitter_max_ms)
    jitter = random.uniform(-amp, amp) if amp > 0.0 else 0.0
    return max(0.0, link.base_delay_ms + jitter), jitter


def read_metrics(path: str) -> Tuple[float, float]:
    try:
        with open(path, "r", encoding="utf-8") as f:
            parts = f.read().strip().split()
    except FileNotFoundError:
        return 0.0, 0.0

    if len(parts) < 2:
        return 0.0, 0.0

    try:
        return float(parts[0]), float(parts[1])
    except ValueError:
        return 0.0, 0.0


class PairwiseImpairmentWorker:
    def __init__(self, topology_file: str, dry_run: bool, no_sudo: bool, verbose: bool):
        self.topology_file = str(Path(topology_file).resolve())
        self.dry_run = dry_run
        self.no_sudo = no_sudo
        self.verbose = verbose
        self.stop = False
        self.scenario_id = ""
        self.tick_ms = 200.0
        self.endpoints: Dict[str, Endpoint] = {}
        self.links: List[LinkSpec] = []
        self.directions: List[DirectionSpec] = []

        signal.signal(signal.SIGINT, self._handle_signal)
        signal.signal(signal.SIGTERM, self._handle_signal)

    def log(self, msg: str) -> None:
        print(f"[pairwise_impair] {msg}", flush=True)

    def vlog(self, msg: str) -> None:
        if self.verbose:
            self.log(msg)

    def _handle_signal(self, signum, _frame) -> None:
        self.log(f"received signal {signum}, stopping ...")
        self.stop = True

    def load(self) -> None:
        with open(self.topology_file, "r", encoding="utf-8") as f:
            topo = json.load(f)

        self.scenario_id = topo.get("scenario_id") or die("missing scenario_id")
        globals_ = topo.get("globals", {})
        experiment_net = globals_.get("experiment_net", {})
        if experiment_net.get("mode") != "l2_link_mesh":
            die("pairwise impairment requires experiment_net.mode=l2_link_mesh")

        self.tick_ms = parse_time_ms(globals_.get("tick", "200ms"), 200.0)
        default_rate = globals_.get("default_data_rate", "100Mbps")
        default_delay = globals_.get("default_delay", "2ms")

        for inst in topo.get("instances", []):
            node_id = inst.get("id")
            if not node_id:
                die("instance missing id")
            tap = inst.get("tap_name")
            exp_ip = inst.get("exp_ip")
            if not tap or not exp_ip:
                continue
            self.endpoints[node_id] = Endpoint(node_id=node_id, ip=parse_ip(str(exp_ip)), tap=str(tap))

        if not self.endpoints:
            die("no endpoints with exp_ip/tap_name found")

        self.links = []
        for source_name in ("links", "mesh_links"):
            raw_links = topo.get(source_name, [])
            if not isinstance(raw_links, list):
                die(f"{source_name} must be an array when present")

            for raw in raw_links:
                if not raw.get("enabled", True):
                    continue

                link_id = raw.get("id")
                src = raw.get("src")
                dst = raw.get("dst")
                if not link_id or not src or not dst:
                    die(f"{source_name} entry missing id/src/dst")
                if src not in self.endpoints:
                    die(f"link src is not an endpoint: {link_id} src={src}")
                if dst not in self.endpoints:
                    die(f"link dst is not an endpoint: {link_id} dst={dst}")

                metrics_file = raw.get("metrics_file")
                if not metrics_file:
                    die(f"link missing metrics_file: {link_id}")

                self.links.append(
                    LinkSpec(
                        link_id=str(link_id),
                        src=str(src),
                        dst=str(dst),
                        metrics_file=str(metrics_file),
                        data_rate=str(raw.get("data_rate", default_rate)),
                        base_delay_ms=parse_time_ms(raw.get("base_delay", default_delay), 2.0),
                        loss_min=float(raw.get("loss_min", 0.0)),
                        loss_max=float(raw.get("loss_max", 0.30)),
                        dist_no_loss=float(raw.get("dist_no_loss", 50.0)),
                        dist_max=float(raw.get("dist_max", 500.0)),
                        jitter_per_mps_ms=parse_time_ms(raw.get("jitter_per_mps", "0.05ms"), 0.05),
                        jitter_max_ms=parse_time_ms(raw.get("jitter_max", "10ms"), 10.0),
                        source=source_name,
                    )
                )

        self._build_directions()

    def _build_directions(self) -> None:
        by_dev_count: Dict[str, int] = {}
        directions: List[DirectionSpec] = []

        for link in self.links:
            for src_id, dst_id in ((link.src, link.dst), (link.dst, link.src)):
                src = self.endpoints[src_id]
                dst = self.endpoints[dst_id]
                count = by_dev_count.get(src.tap, 0)
                by_dev_count[src.tap] = count + 1
                minor = 10 + count
                directions.append(
                    DirectionSpec(
                        link=link,
                        src=src,
                        dst=dst,
                        minor=minor,
                        prio=10 + count,
                    )
                )

        self.directions = directions

    def tc_prefix(self) -> List[str]:
        if self.no_sudo or os.geteuid() == 0:
            return ["tc"]
        return ["sudo", "-n", "tc"]

    def run_tc(self, args: List[str], check: bool = True) -> subprocess.CompletedProcess:
        cmd = self.tc_prefix() + args
        if self.dry_run:
            print("+ " + shlex.join(cmd))
            return subprocess.CompletedProcess(cmd, 0, "", "")

        proc = subprocess.run(cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if check and proc.returncode != 0:
            if proc.stdout:
                sys.stderr.write(proc.stdout)
            if proc.stderr:
                sys.stderr.write(proc.stderr)
            raise SystemExit(proc.returncode)
        if self.verbose and proc.returncode != 0:
            self.vlog(f"ignored tc failure rc={proc.returncode}: {shlex.join(cmd)}")
            if proc.stderr:
                self.vlog(proc.stderr.strip())
        return proc

    def setup_qdiscs(self) -> None:
        by_dev: Dict[str, List[DirectionSpec]] = {}
        for direction in self.directions:
            by_dev.setdefault(direction.src.tap, []).append(direction)

        self.log(f"scenario={self.scenario_id}")
        self.log(f"endpoints={len(self.endpoints)} links={len(self.links)} directions={len(self.directions)}")

        for dev, directions in sorted(by_dev.items()):
            self.log(f"configuring {dev}: {len(directions)} directional peer filters")
            self.run_tc(["qdisc", "del", "dev", dev, "root"], check=False)
            self.run_tc(["qdisc", "add", "dev", dev, "root", "handle", "1:", "htb", "default", "999"])
            self.run_tc(
                [
                    "class",
                    "add",
                    "dev",
                    dev,
                    "parent",
                    "1:",
                    "classid",
                    "1:999",
                    "htb",
                    "rate",
                    "1000mbit",
                    "ceil",
                    "1000mbit",
                ]
            )

            for direction in directions:
                rate = normalize_tc_rate(direction.link.data_rate)
                self.run_tc(
                    [
                        "class",
                        "add",
                        "dev",
                        dev,
                        "parent",
                        "1:",
                        "classid",
                        direction.classid,
                        "htb",
                        "rate",
                        rate,
                        "ceil",
                        rate,
                    ]
                )
                self.run_tc(
                    [
                        "qdisc",
                        "add",
                        "dev",
                        dev,
                        "parent",
                        direction.classid,
                        "handle",
                        direction.handle,
                        "netem",
                        "delay",
                        "0ms",
                        "loss",
                        "0%",
                    ]
                )
                self.run_tc(
                    [
                        "filter",
                        "add",
                        "dev",
                        dev,
                        "protocol",
                        "ip",
                        "parent",
                        "1:",
                        "prio",
                        str(direction.prio),
                        "u32",
                        "match",
                        "ip",
                        "dst",
                        f"{direction.dst.ip}/32",
                        "flowid",
                        direction.classid,
                    ]
                )

    def update_once(self) -> None:
        for direction in self.directions:
            speed, dist = read_metrics(direction.link.metrics_file)
            loss = compute_loss(direction.link, dist)
            delay_ms, jitter_ms = compute_delay_ms(direction.link, speed)
            loss_pct = max(0.0, min(100.0, loss * 100.0))

            self.run_tc(
                [
                    "qdisc",
                    "replace",
                    "dev",
                    direction.src.tap,
                    "parent",
                    direction.classid,
                    "handle",
                    direction.handle,
                    "netem",
                    "delay",
                    f"{delay_ms:.3f}ms",
                    "loss",
                    f"{loss_pct:.4f}%",
                ]
            )

            self.vlog(
                f"{direction.link.link_id} {direction.src.node_id}->{direction.dst.node_id} "
                f"dev={direction.src.tap} dst={direction.dst.ip} speed={speed:.3f} "
                f"dist={dist:.3f} loss={loss:.5f} delay_ms={delay_ms:.3f} jitter_ms={jitter_ms:.3f}"
            )

    def cleanup(self) -> None:
        devices = sorted({endpoint.tap for endpoint in self.endpoints.values()})
        for dev in devices:
            self.log(f"clearing qdisc on {dev}")
            self.run_tc(["qdisc", "del", "dev", dev, "root"], check=False)

    def run(self, once: bool, cleanup_only: bool) -> int:
        self.load()

        if cleanup_only:
            self.cleanup()
            return 0

        self.setup_qdiscs()
        self.update_once()

        if once:
            return 0

        interval = max(0.05, self.tick_ms / 1000.0)
        self.log(f"loop interval={interval:.3f}s")
        next_ts = time.monotonic() + interval

        while not self.stop:
            now = time.monotonic()
            if now < next_ts:
                time.sleep(min(0.05, next_ts - now))
                continue
            self.update_once()
            next_ts += interval
            if next_ts < time.monotonic():
                next_ts = time.monotonic() + interval

        return 0


def parse_args() -> argparse.Namespace:
    ap = argparse.ArgumentParser(description="Apply pairwise experiment-net impairment with Linux tc")
    ap.add_argument("--topology", required=True, help="Topology JSON file")
    ap.add_argument("--dry-run", action="store_true", help="Print tc commands without applying them")
    ap.add_argument("--once", action="store_true", help="Apply one setup/update cycle and exit")
    ap.add_argument("--cleanup", action="store_true", help="Remove qdiscs from topology endpoint taps and exit")
    ap.add_argument("--no-sudo", action="store_true", help="Call tc directly instead of sudo -n tc")
    ap.add_argument("--verbose", action="store_true", help="Print per-link update details")
    return ap.parse_args()


def main() -> int:
    args = parse_args()
    worker = PairwiseImpairmentWorker(
        topology_file=args.topology,
        dry_run=args.dry_run,
        no_sudo=args.no_sudo,
        verbose=args.verbose,
    )
    return worker.run(once=args.once or args.dry_run, cleanup_only=args.cleanup)


if __name__ == "__main__":
    sys.exit(main())
