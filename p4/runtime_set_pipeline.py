#!/usr/bin/env python3
"""Set a BMv2 P4Runtime forwarding pipeline and exit.

This script is intended to run inside the p4runtime-sh container image. It uses
the p4runtime_sh Python API directly instead of starting the interactive shell.
"""

import argparse
import csv
import json
import logging
import sys

import grpc
from p4runtime_sh import shell
from p4runtime_sh.p4runtime import SSLOptions


def parse_election_id(value: str) -> tuple[int, int]:
    parts = value.split(",", 1)
    if len(parts) != 2:
        raise argparse.ArgumentTypeError("expected <high>,<low>")
    try:
        return int(parts[0]), int(parts[1])
    except ValueError as exc:
        raise argparse.ArgumentTypeError("election id values must be integers") from exc


def is_already_exists(exc: Exception) -> bool:
    code = getattr(exc, "code", lambda: None)()
    if code == grpc.StatusCode.ALREADY_EXISTS:
        return True
    text = str(exc)
    return "ALREADY_EXISTS" in text or "already exists" in text.lower()


def install_table_entries(entries_path: str) -> tuple[int, int]:
    with open(entries_path, "r", encoding="utf-8") as f:
        payload = json.load(f)

    entries = payload.get("entries", [])
    if not isinstance(entries, list):
        raise ValueError("entries JSON must contain an array field named 'entries'")

    inserted = 0
    modified = 0
    for entry in entries:
        if not isinstance(entry, dict):
            raise ValueError("each table entry must be an object")

        table_name = entry["table"]
        action_name = entry["action"]
        match = entry.get("match", {})
        params = entry.get("params", {})
        priority = entry.get("priority")

        table_entry = shell.TableEntry(table_name)(action=action_name)
        for key, value in match.items():
            table_entry.match[key] = str(value)
        for key, value in params.items():
            table_entry.action[key] = str(value)
        if priority is not None:
            table_entry.priority = int(priority)
        try:
            table_entry.insert()
            inserted += 1
        except Exception as exc:
            if not is_already_exists(exc):
                raise
            table_entry.modify()
            modified += 1

    return inserted, modified


def load_target(
    *,
    config: shell.FwdPipeConfig,
    device_id: int,
    grpc_addr: str,
    entries_json: str | None,
    election_id: tuple[int, int],
    verbose: bool,
    target_id: str = "",
) -> None:
    try:
        shell.setup(
            device_id=device_id,
            grpc_addr=grpc_addr,
            election_id=election_id,
            role_name=None,
            config=config,
            ssl_options=SSLOptions(True),
            verbose=verbose,
        )
        target_part = f" target={target_id}" if target_id else ""
        print(
            f"[p4runtime-load] loaded{target_part} device={device_id} "
            f"grpc={grpc_addr}"
        )
        if entries_json:
            inserted, modified = install_table_entries(entries_json)
            print(
                f"[p4runtime-load] inserted_entries={inserted} "
                f"modified_entries={modified} "
                f"device={device_id}"
            )
    finally:
        if shell.client is not None:
            shell.teardown()


def load_batch(args: argparse.Namespace) -> int:
    config = shell.FwdPipeConfig(args.p4info, args.bmv2_json)
    with open(args.batch_tsv, "r", encoding="utf-8", newline="") as handle:
        rows = list(csv.reader(handle, delimiter="\t"))
    for row in rows:
        if not row or (len(row) == 1 and not row[0].strip()):
            continue
        if len(row) != 4:
            raise ValueError(f"batch TSV rows must have 4 fields, got {len(row)}: {row!r}")
        target_id, device_id_raw, grpc_addr, entries_json = row
        load_target(
            config=config,
            device_id=int(device_id_raw),
            grpc_addr=grpc_addr,
            entries_json=entries_json or None,
            election_id=args.election_id,
            verbose=args.verbose,
            target_id=target_id,
        )
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Load a P4Runtime forwarding pipeline into a BMv2 target"
    )
    parser.add_argument("--device-id", type=int)
    parser.add_argument("--grpc-addr")
    parser.add_argument("--p4info", required=True)
    parser.add_argument("--bmv2-json", required=True)
    parser.add_argument("--entries-json")
    parser.add_argument("--batch-tsv")
    parser.add_argument("--election-id", type=parse_election_id, default=(1, 0))
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()

    if args.verbose:
        logging.basicConfig(level=logging.DEBUG)

    if args.batch_tsv:
        return load_batch(args)

    if args.device_id is None or not args.grpc_addr:
        parser.error("--device-id and --grpc-addr are required unless --batch-tsv is used")

    config = shell.FwdPipeConfig(args.p4info, args.bmv2_json)
    load_target(
        config=config,
        device_id=args.device_id,
        grpc_addr=args.grpc_addr,
        entries_json=args.entries_json,
        election_id=args.election_id,
        verbose=args.verbose,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
