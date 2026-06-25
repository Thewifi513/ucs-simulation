#!/usr/bin/env python3
"""Set a BMv2 P4Runtime forwarding pipeline and exit.

This script is intended to run inside the p4runtime-sh container image. It uses
the p4runtime_sh Python API directly instead of starting the interactive shell.
"""

import argparse
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


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Load a P4Runtime forwarding pipeline into a BMv2 target"
    )
    parser.add_argument("--device-id", type=int, required=True)
    parser.add_argument("--grpc-addr", required=True)
    parser.add_argument("--p4info", required=True)
    parser.add_argument("--bmv2-json", required=True)
    parser.add_argument("--entries-json")
    parser.add_argument("--election-id", type=parse_election_id, default=(1, 0))
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()

    if args.verbose:
        logging.basicConfig(level=logging.DEBUG)

    config = shell.FwdPipeConfig(args.p4info, args.bmv2_json)
    try:
        shell.setup(
            device_id=args.device_id,
            grpc_addr=args.grpc_addr,
            election_id=args.election_id,
            role_name=None,
            config=config,
            ssl_options=SSLOptions(True),
            verbose=args.verbose,
        )
        print(
            f"[p4runtime-load] loaded device={args.device_id} "
            f"grpc={args.grpc_addr}"
        )
        if args.entries_json:
            inserted, modified = install_table_entries(args.entries_json)
            print(
                f"[p4runtime-load] inserted_entries={inserted} "
                f"modified_entries={modified} "
                f"device={args.device_id}"
            )
        return 0
    finally:
        if shell.client is not None:
            shell.teardown()


if __name__ == "__main__":
    sys.exit(main())
