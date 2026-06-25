#!/usr/bin/env python3
"""Browser WebSocket relay for BMv2 control_core."""

from __future__ import annotations

import argparse
import asyncio
import contextlib
import json
import signal
import time
from typing import Dict, Optional, Set

import websockets


VALID_KEYS = {"w", "a", "s", "d", "q", "e", "z", "x", "c", "l", "h", "j", "k"}
VALID_COMMANDS = {"release_all", "set_throttle", "sync_status", "arm_offboard", "land", "rtl"}


class ControlCoreLink:
    def __init__(self, host: str, port: int):
        self.host = host
        self.port = port
        self.reader: Optional[asyncio.StreamReader] = None
        self.writer: Optional[asyncio.StreamWriter] = None
        self.connected = False
        self.outgoing: asyncio.Queue[dict] = asyncio.Queue()
        self.incoming: asyncio.Queue[dict] = asyncio.Queue()
        self.stop_event = asyncio.Event()
        self.tasks: list[asyncio.Task] = []

    async def run(self) -> None:
        self.tasks = [asyncio.create_task(self._connect_loop())]
        await self.stop_event.wait()

    async def shutdown(self) -> None:
        if self.stop_event.is_set():
            return
        self.stop_event.set()
        for task in self.tasks:
            task.cancel()
        for task in self.tasks:
            with contextlib.suppress(asyncio.CancelledError, Exception):
                await task
        if self.writer is not None:
            with contextlib.suppress(Exception):
                self.writer.close()
                await self.writer.wait_closed()
        self.writer = None
        self.reader = None
        self.connected = False

    async def send(self, payload: dict) -> None:
        await self.outgoing.put(payload)

    async def _connect_loop(self) -> None:
        while not self.stop_event.is_set():
            sender = None
            receiver = None
            try:
                self.reader, self.writer = await asyncio.open_connection(self.host, self.port)
                self.connected = True
                await self.send({"type": "hello", "client": "remote_web"})
                sender = asyncio.create_task(self._sender())
                receiver = asyncio.create_task(self._receiver())
                done, pending = await asyncio.wait({sender, receiver}, return_when=asyncio.FIRST_EXCEPTION)
                for task in pending:
                    task.cancel()
                    with contextlib.suppress(asyncio.CancelledError, Exception):
                        await task
                for task in done:
                    with contextlib.suppress(asyncio.CancelledError, Exception):
                        await task
            except asyncio.CancelledError:
                raise
            except Exception:
                await asyncio.sleep(1.0)
            finally:
                self.connected = False
                if sender is not None:
                    sender.cancel()
                if receiver is not None:
                    receiver.cancel()
                if self.writer is not None:
                    with contextlib.suppress(Exception):
                        self.writer.close()
                        await self.writer.wait_closed()
                self.reader = None
                self.writer = None
                if not self.stop_event.is_set():
                    await asyncio.sleep(1.0)

    async def _sender(self) -> None:
        while not self.stop_event.is_set():
            payload = await self.outgoing.get()
            if self.writer is None:
                continue
            self.writer.write((json.dumps(payload, ensure_ascii=False) + "\n").encode("utf-8"))
            await self.writer.drain()

    async def _receiver(self) -> None:
        while not self.stop_event.is_set():
            if self.reader is None:
                await asyncio.sleep(0.1)
                continue
            raw = await self.reader.readline()
            if not raw:
                raise ConnectionError("control_core closed")
            try:
                payload = json.loads(raw.decode("utf-8", errors="replace").strip())
            except json.JSONDecodeError:
                continue
            await self.incoming.put(payload)


class RelayServer:
    def __init__(self, args: argparse.Namespace):
        self.args = args
        self.core_link = ControlCoreLink(args.core_host, args.core_port)
        self.ws_clients: Set = set()
        self.stop_event = asyncio.Event()
        self.ws_server = None
        self.tasks: list[asyncio.Task] = []
        self.last_status: Optional[Dict] = None
        self.log_buffer: list[str] = []

    async def log(self, text: str) -> None:
        self.log_buffer.append(f"[{time.strftime('%H:%M:%S')}] {text}")
        self.log_buffer = self.log_buffer[-200:]
        print(text, flush=True)

    async def broadcast(self, payload: Dict) -> None:
        if not self.ws_clients:
            return
        raw = json.dumps(payload, ensure_ascii=False)
        dead = []
        for ws in list(self.ws_clients):
            try:
                await ws.send(raw)
            except Exception:
                dead.append(ws)
        for ws in dead:
            self.ws_clients.discard(ws)

    async def broadcast_relay_status(self) -> None:
        await self.broadcast({
            "type": "relay_status",
            "relay_connected": True,
            "core_connected": self.core_link.connected,
            "target_uav": (self.last_status or {}).get("target_uav", ""),
            "ws_clients": len(self.ws_clients),
            "ts": time.time(),
        })

    async def core_rx_loop(self) -> None:
        while not self.stop_event.is_set():
            payload = await self.core_link.incoming.get()
            if payload.get("type") == "status":
                self.last_status = payload
            await self.broadcast(payload)

    async def relay_status_loop(self) -> None:
        while not self.stop_event.is_set():
            await self.broadcast_relay_status()
            await asyncio.sleep(1.0)

    async def ws_handler(self, websocket) -> None:
        self.ws_clients.add(websocket)
        await self.log(f"[relay] ws client connected: {getattr(websocket, 'remote_address', None)}")
        try:
            await self.broadcast_relay_status()
            if self.last_status is not None:
                await websocket.send(json.dumps(self.last_status, ensure_ascii=False))
            for line in self.log_buffer[-20:]:
                await websocket.send(json.dumps({"type": "log", "level": "info", "message": line, "ts": time.time()}, ensure_ascii=False))
            async for raw in websocket:
                try:
                    message = json.loads(raw)
                except json.JSONDecodeError:
                    continue
                mtype = str(message.get("type", "")).lower()
                if mtype == "hello":
                    await self.broadcast_relay_status()
                    if self.last_status is not None:
                        await websocket.send(json.dumps(self.last_status, ensure_ascii=False))
                    await self.log(
                        f"[relay] hello uav={message.get('uav', '')} "
                        f"core_connected={self.core_link.connected}"
                    )
                    await self.core_link.send({"type": "hello", "client": "browser", "uav": message.get("uav", "")})
                    continue
                if mtype == "ping":
                    await websocket.send(json.dumps({"type": "pong", "ts": time.time()}, ensure_ascii=False))
                    continue
                if mtype == "key":
                    key = str(message.get("key", "")).lower()
                    action = str(message.get("action", "")).lower()
                    if key in VALID_KEYS and action in {"press", "release"}:
                        await self.log(
                            f"[relay] key {action} {key} uav={message.get('uav', '')} "
                            f"core_connected={self.core_link.connected}"
                        )
                        await self.core_link.send({"type": "key", "key": key, "action": action, "uav": message.get("uav", "")})
                    continue
                if mtype == "command":
                    name = str(message.get("name", "")).lower()
                    if name in VALID_COMMANDS:
                        payload = {"type": "command", "name": name, "uav": message.get("uav", "")}
                        if "value" in message:
                            payload["value"] = message["value"]
                        await self.log(
                            f"[relay] command {name} uav={message.get('uav', '')} "
                            f"core_connected={self.core_link.connected}"
                        )
                        await self.core_link.send(payload)
                    continue
        finally:
            self.ws_clients.discard(websocket)
            await self.log(f"[relay] ws client disconnected: {getattr(websocket, 'remote_address', None)}")

    async def run(self) -> None:
        await self.log(f"[relay] websocket listen on {self.args.listen_host}:{self.args.listen_port}")
        await self.log(f"[relay] control_core target {self.args.core_host}:{self.args.core_port}")
        self.tasks = [
            asyncio.create_task(self.core_link.run()),
            asyncio.create_task(self.core_rx_loop()),
            asyncio.create_task(self.relay_status_loop()),
        ]
        self.ws_server = await websockets.serve(self.ws_handler, self.args.listen_host, self.args.listen_port)
        await self.stop_event.wait()

    async def shutdown(self) -> None:
        if self.stop_event.is_set():
            return
        self.stop_event.set()
        if self.ws_server is not None:
            self.ws_server.close()
            await self.ws_server.wait_closed()
        for ws in list(self.ws_clients):
            with contextlib.suppress(Exception):
                await ws.close()
        await self.core_link.shutdown()
        for task in self.tasks:
            task.cancel()
        for task in self.tasks:
            with contextlib.suppress(asyncio.CancelledError, Exception):
                await task


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--listen-host", default="0.0.0.0")
    parser.add_argument("--listen-port", type=int, default=8765)
    parser.add_argument("--core-host", default="127.0.0.1")
    parser.add_argument("--core-port", type=int, default=9001)
    return parser


async def async_main(args: argparse.Namespace) -> None:
    relay = RelayServer(args)
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        with contextlib.suppress(NotImplementedError):
            loop.add_signal_handler(sig, lambda: asyncio.create_task(relay.shutdown()))
    try:
        await relay.run()
    finally:
        await relay.shutdown()


def main() -> None:
    args = build_arg_parser().parse_args()
    asyncio.run(async_main(args))


if __name__ == "__main__":
    main()
