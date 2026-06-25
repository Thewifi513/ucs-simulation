#!/usr/bin/env python3
"""Monitor and audit ns-3 pairwise link impairment logs."""

from __future__ import annotations

import argparse
import glob
import math
import os
import re
import sys
import time
from collections import defaultdict, deque
from dataclasses import dataclass
from typing import Deque, Dict, Iterable, List, Optional, Tuple


LOG_PATTERNS = (
    "/tmp/ucs_mesh_ns3*.launcher.log",
    "/tmp/ucs_mesh_ns3*.log",
    "/tmp/*mesh*ns3*.log",
)
LINE_RE = re.compile(r"\[(?:pair-link|link)\]\s+(.*)")
FIELD_RE = re.compile(r"(\w+)=([^\s]+)")


def parse_float(value: Optional[str], default: float = math.nan) -> float:
    if value is None:
        return default
    try:
        return float(value)
    except ValueError:
        return default


def parse_int(value: Optional[str], default: int = 0) -> int:
    try:
        return int(float(value)) if value is not None else default
    except ValueError:
        return default


def parse_link_line(line: str) -> Optional[Dict[str, str]]:
    match = LINE_RE.search(line)
    if not match:
        return None
    fields = dict(FIELD_RE.findall(match.group(1)))
    return fields if "id" in fields else None


@dataclass
class LinkStats:
    link_id: str
    n: int = 0
    t0: float = math.inf
    t1: float = -math.inf
    sum_per: float = 0.0
    max_per: float = 0.0
    per_positive: int = 0
    sum_speed: float = 0.0
    max_speed: float = 0.0
    min_dist: float = math.inf
    max_dist: float = -math.inf
    last_dist: float = math.nan
    min_rx: float = math.inf
    max_rx: float = -math.inf
    max_shadow_abs: float = 0.0
    max_multipath_abs: float = 0.0
    resamples: int = 0
    static_samples: int = 0
    static_per_positive: int = 0
    static_max_per: float = 0.0
    static_resamples: int = 0
    static_drop_delta: int = 0
    first_forwarded: Optional[int] = None
    last_forwarded: Optional[int] = None
    first_dropped: Optional[int] = None
    last_dropped: Optional[int] = None
    previous_dropped: Optional[int] = None
    previous_static: bool = False

    def update(self, fields: Dict[str, str], static_speed_mps: float) -> None:
        self.n += 1
        t = parse_float(fields.get("t"))
        per = parse_float(fields.get("per"), parse_float(fields.get("loss"), 0.0))
        speed = abs(parse_float(fields.get("speed"), 0.0))
        dist = parse_float(fields.get("dist"))
        rx = parse_float(fields.get("rx_dbm"))
        shadow = parse_float(fields.get("shadow_db"), 0.0)
        multipath = parse_float(fields.get("multipath_db"), 0.0)
        resampled = parse_int(fields.get("multipath_resampled"), 0)
        is_static = speed <= static_speed_mps

        if math.isfinite(t):
            self.t0 = min(self.t0, t)
            self.t1 = max(self.t1, t)
        if math.isfinite(per):
            self.sum_per += per
            self.max_per = max(self.max_per, per)
            if per > 0.0:
                self.per_positive += 1
        if math.isfinite(speed):
            self.sum_speed += speed
            self.max_speed = max(self.max_speed, speed)
        if math.isfinite(dist):
            self.min_dist = min(self.min_dist, dist)
            self.max_dist = max(self.max_dist, dist)
            self.last_dist = dist
        if math.isfinite(rx):
            self.min_rx = min(self.min_rx, rx)
            self.max_rx = max(self.max_rx, rx)

        self.max_shadow_abs = max(self.max_shadow_abs, abs(shadow))
        self.max_multipath_abs = max(self.max_multipath_abs, abs(multipath))
        self.resamples += resampled

        if "forwarded" in fields:
            forwarded = parse_int(fields.get("forwarded"))
            if self.first_forwarded is None:
                self.first_forwarded = forwarded
            self.last_forwarded = forwarded

        dropped: Optional[int] = None
        if "dropped" in fields:
            dropped = parse_int(fields.get("dropped"))
            if self.first_dropped is None:
                self.first_dropped = dropped
            self.last_dropped = dropped

        if is_static:
            self.static_samples += 1
            self.static_max_per = max(self.static_max_per, per if math.isfinite(per) else 0.0)
            if math.isfinite(per) and per > 0.0:
                self.static_per_positive += 1
            if resampled:
                self.static_resamples += resampled
            if dropped is not None and self.previous_dropped is not None and self.previous_static:
                self.static_drop_delta += max(0, dropped - self.previous_dropped)

        self.previous_static = is_static
        if dropped is not None:
            self.previous_dropped = dropped

    @property
    def avg_per(self) -> float:
        return self.sum_per / self.n if self.n else 0.0

    @property
    def avg_speed(self) -> float:
        return self.sum_speed / self.n if self.n else 0.0

    @property
    def forwarded_delta(self) -> int:
        if self.first_forwarded is None or self.last_forwarded is None:
            return 0
        return max(0, self.last_forwarded - self.first_forwarded)

    @property
    def dropped_delta(self) -> int:
        if self.first_dropped is None or self.last_dropped is None:
            return 0
        return max(0, self.last_dropped - self.first_dropped)


def newest_log() -> Optional[str]:
    candidates: List[str] = []
    for pattern in LOG_PATTERNS:
        candidates.extend(glob.glob(pattern))
    files = sorted(set(path for path in candidates if os.path.isfile(path)))
    if not files:
        return None
    return max(files, key=os.path.getmtime)


def summarize(fields_iter: Iterable[Dict[str, str]], static_speed_mps: float) -> Dict[str, LinkStats]:
    stats: Dict[str, LinkStats] = {}
    for fields in fields_iter:
        link_id = fields.get("id")
        if not link_id:
            continue
        stats.setdefault(link_id, LinkStats(link_id)).update(fields, static_speed_mps)
    return stats


def sorted_rows(stats: Dict[str, LinkStats], key: str) -> List[LinkStats]:
    if key == "drop":
        return sorted(stats.values(), key=lambda row: (row.dropped_delta, row.max_per), reverse=True)
    if key == "per":
        return sorted(stats.values(), key=lambda row: (row.max_per, row.avg_per), reverse=True)
    return sorted(stats.values(), key=lambda row: row.link_id)


def fmt_float(value: float, digits: int = 1) -> str:
    if not math.isfinite(value):
        return "nan"
    return f"{value:.{digits}f}"


def print_rows(title: str, rows: List[LinkStats], limit: int) -> None:
    print(title)
    for row in rows[:limit]:
        print(
            "{id:11s} max_per={max_per:.3f} avg_per={avg_per:.4f} "
            "per_pos={per_pos:4d} max_speed={max_speed:6.3f} "
            "dist={min_dist:>6s}..{max_dist:<6s} min_rx={min_rx:>7s} "
            "resamp={resamp:4d} drop_delta={drop_delta:6d} fwd_delta={fwd_delta:7d}".format(
                id=row.link_id,
                max_per=row.max_per,
                avg_per=row.avg_per,
                per_pos=row.per_positive,
                max_speed=row.max_speed,
                min_dist=fmt_float(row.min_dist, 2),
                max_dist=fmt_float(row.max_dist, 2),
                min_rx=fmt_float(row.min_rx, 1),
                resamp=row.resamples,
                drop_delta=row.dropped_delta,
                fwd_delta=row.forwarded_delta,
            )
        )


def print_alerts(
    stats: Dict[str, LinkStats],
    *,
    focus: str,
    per_alert: float,
    static_speed_mps: float,
) -> None:
    never_moved_alerts = [
        row
        for row in stats.values()
        if row.max_speed <= static_speed_mps
        and (row.max_per >= per_alert or row.dropped_delta > 0)
    ]
    static_window_warnings = [
        row
        for row in stats.values()
        if row.static_samples > 0
        and (row.static_max_per >= per_alert or row.static_drop_delta > 0)
    ]

    print("\nNEVER_MOVED_ALERTS")
    if never_moved_alerts:
        for row in sorted_rows({row.link_id: row for row in never_moved_alerts}, "per"):
            print(
                "{id:11s} max_per={max_per:.3f} drop_delta={drop_delta} "
                "resamp={resamp} max_speed={max_speed:.3f} max_dist={max_dist:.2f}".format(
                    id=row.link_id,
                    max_per=row.max_per,
                    drop_delta=row.dropped_delta,
                    resamp=row.resamples,
                    max_speed=row.max_speed,
                    max_dist=row.max_dist,
                )
            )
    else:
        print("none")

    print("\nSTATIC_WINDOW_WARNINGS")
    if static_window_warnings:
        for row in sorted_rows({row.link_id: row for row in static_window_warnings}, "per"):
            print(
                "{id:11s} static_max_per={static_max_per:.3f} static_drop_delta={drop_delta} "
                "static_resamp={resamp} max_speed={max_speed:.3f} max_dist={max_dist:.2f}".format(
                    id=row.link_id,
                    static_max_per=row.static_max_per,
                    drop_delta=row.static_drop_delta,
                    resamp=row.static_resamples,
                    max_speed=row.max_speed,
                    max_dist=row.max_dist,
                )
            )
    else:
        print("none")

    if focus:
        focus_alerts = [
            row
            for row in stats.values()
            if focus not in row.link_id
            and (row.max_per >= per_alert or row.dropped_delta > 0)
        ]
        print(f"\nNON_FOCUS_DAMAGE focus={focus}")
        if focus_alerts:
            for row in sorted_rows({row.link_id: row for row in focus_alerts}, "per"):
                print(
                    "{id:11s} max_per={max_per:.3f} drop_delta={drop_delta} "
                    "resamp={resamp} max_speed={max_speed:.3f} max_dist={max_dist:.2f}".format(
                        id=row.link_id,
                        max_per=row.max_per,
                        drop_delta=row.dropped_delta,
                        resamp=row.resamples,
                        max_speed=row.max_speed,
                        max_dist=row.max_dist,
                    )
                )
        else:
            print("none")


def load_records(path: str) -> Tuple[List[Dict[str, str]], Dict[str, int], float, float]:
    records: List[Dict[str, str]] = []
    model_counts: Dict[str, int] = defaultdict(int)
    t0 = math.inf
    t1 = -math.inf
    with open(path, "r", errors="replace") as handle:
        for line in handle:
            fields = parse_link_line(line)
            if not fields:
                continue
            records.append(fields)
            model_counts[fields.get("loss_model", "?")] += 1
            t = parse_float(fields.get("t"))
            if math.isfinite(t):
                t0 = min(t0, t)
                t1 = max(t1, t)
    return records, dict(model_counts), t0, t1


def analyze_once(args: argparse.Namespace) -> int:
    log_path = args.log or newest_log()
    if not log_path:
        print("[monitor][ERR] no ns-3 mesh log found under /tmp", file=sys.stderr)
        return 2
    if not os.path.isfile(log_path):
        print(f"[monitor][ERR] log not found: {log_path}", file=sys.stderr)
        return 2

    records, model_counts, t0, t1 = load_records(log_path)
    stats = summarize(records, args.static_speed_mps)

    print(f"log={log_path}")
    print(f"total_samples={len(records)} links={len(stats)} t_range={fmt_float(t0, 3)}..{fmt_float(t1, 3)}")
    print("model_counts=" + ", ".join(f"{key}:{value}" for key, value in sorted(model_counts.items())))
    print_rows("\nTOP_BY_MAX_PER", sorted_rows(stats, "per"), args.top)
    print_rows("\nTOP_BY_DROP_DELTA", sorted_rows(stats, "drop"), args.top)
    print_alerts(stats, focus=args.focus, per_alert=args.per_alert, static_speed_mps=args.static_speed_mps)

    if math.isfinite(t1) and args.last_window_sec > 0:
        cutoff = t1 - args.last_window_sec
        last_records = [fields for fields in records if parse_float(fields.get("t")) >= cutoff]
        last_stats = summarize(last_records, args.static_speed_mps)
        print(f"\nLAST_WINDOW t={fmt_float(cutoff, 3)}..{fmt_float(t1, 3)}")
        print_rows("LAST_WINDOW_TOP_BY_MAX_PER", sorted_rows(last_stats, "per"), args.top)
        print_alerts(last_stats, focus=args.focus, per_alert=args.per_alert, static_speed_mps=args.static_speed_mps)

    return 0


def report_live_window(
    window: Deque[Tuple[float, Dict[str, str]]],
    lifetime: Dict[str, LinkStats],
    args: argparse.Namespace,
) -> None:
    stats = summarize((fields for _, fields in window), args.static_speed_mps)
    print(f"[monitor] window_samples={len(window)} lifetime_links={len(lifetime)} window_links={len(stats)}")
    for row in sorted_rows(stats, "per")[: args.top]:
        print(
            "[monitor] id={id:11s} max_per={max_per:.3f} avg_per={avg_per:.4f} "
            "max_speed={max_speed:.3f} dist={dist:>7s} min_rx={min_rx:>6s} "
            "resamp={resamp:3d} drop_delta={drop_delta:5d}".format(
                id=row.link_id,
                max_per=row.max_per,
                avg_per=row.avg_per,
                max_speed=row.max_speed,
                dist=fmt_float(row.last_dist, 2),
                min_rx=fmt_float(row.min_rx, 1),
                resamp=row.resamples,
                drop_delta=row.dropped_delta,
            )
        )

    window_warnings = [
        row
        for row in stats.values()
        if row.static_samples > 0
        and (row.static_max_per >= args.per_alert or row.static_drop_delta > 0)
    ]
    never_moved_alerts = [
        row
        for row in lifetime.values()
        if row.max_speed <= args.static_speed_mps
        and (row.max_per >= args.per_alert or row.dropped_delta > 0)
    ]
    if window_warnings:
        print("[monitor][warn] static-window PER/drop observed:")
        for row in sorted_rows({row.link_id: row for row in window_warnings}, "per")[: args.top]:
            print(
                "[monitor][warn] id={id:11s} static_max_per={per:.3f} static_drop_delta={drop} "
                "static_resamp={resamp} max_dist={dist:.2f}".format(
                    id=row.link_id,
                    per=row.static_max_per,
                    drop=row.static_drop_delta,
                    resamp=row.static_resamples,
                    dist=row.max_dist,
                )
            )
    if never_moved_alerts:
        print("[monitor][alert] never-moved link PER/drop observed:")
        for row in sorted_rows({row.link_id: row for row in never_moved_alerts}, "per")[: args.top]:
            print(
                "[monitor][alert] id={id:11s} max_per={per:.3f} drop_delta={drop} "
                "resamp={resamp} max_dist={dist:.2f}".format(
                    id=row.link_id,
                    per=row.max_per,
                    drop=row.dropped_delta,
                    resamp=row.resamples,
                    dist=row.max_dist,
                )
            )


def follow_log(args: argparse.Namespace) -> int:
    log_path: Optional[str] = None
    handle = None
    window: Deque[Tuple[float, Dict[str, str]]] = deque()
    lifetime: Dict[str, LinkStats] = {}
    last_report = 0.0

    try:
        while True:
            candidate = args.log or newest_log()
            if candidate and candidate != log_path:
                if handle:
                    handle.close()
                log_path = candidate
                handle = open(log_path, "r", errors="replace")
                if args.from_end:
                    handle.seek(0, os.SEEK_END)
                print(f"[monitor] attached log={log_path} offset={handle.tell()}")

            if not handle:
                if args.wait:
                    print("[monitor] waiting for ns-3 mesh log under /tmp ...")
                    time.sleep(1.0)
                    continue
                print("[monitor][ERR] no ns-3 mesh log found under /tmp", file=sys.stderr)
                return 2

            line = handle.readline()
            if not line:
                now = time.time()
                if now - last_report >= args.report_every_sec:
                    while window and window[0][0] < now - args.window_sec:
                        window.popleft()
                    if window:
                        report_live_window(window, lifetime, args)
                    else:
                        print(f"[monitor] attached log={log_path}, waiting for link samples ...")
                    last_report = now
                time.sleep(0.2)
                continue

            fields = parse_link_line(line)
            if not fields:
                continue
            now = time.time()
            window.append((now, fields))
            link_id = fields["id"]
            lifetime.setdefault(link_id, LinkStats(link_id)).update(fields, args.static_speed_mps)
    except KeyboardInterrupt:
        print("[monitor] stopped")
        return 130
    finally:
        if handle:
            handle.close()


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--log", help="ns-3 launcher log to read; defaults to the newest /tmp/ucs_mesh_ns3*.log")
    parser.add_argument("--follow", action="store_true", help="follow the log and print rolling live windows")
    parser.add_argument("--wait", action="store_true", help="wait for a log to appear when following")
    parser.add_argument("--from-end", action="store_true", help="when following, start at end of current log")
    parser.add_argument("--window-sec", type=float, default=60.0, help="live rolling window length")
    parser.add_argument("--last-window-sec", type=float, default=60.0, help="offline final-window audit length")
    parser.add_argument("--report-every-sec", type=float, default=10.0, help="live report interval")
    parser.add_argument("--static-speed-mps", type=float, default=0.05, help="speed threshold for static samples")
    parser.add_argument("--per-alert", type=float, default=0.05, help="PER threshold used by alerts")
    parser.add_argument("--top", type=int, default=8, help="number of rows to print in each section")
    parser.add_argument("--focus", default="", help="optional substring, e.g. uav04, for NON_FOCUS_DAMAGE checks")
    return parser


def main() -> int:
    args = build_parser().parse_args()
    if args.follow:
        return follow_log(args)
    return analyze_once(args)


if __name__ == "__main__":
    raise SystemExit(main())
