"""Relay server: pairs one host app with many player browsers, per room.

It only reads the envelope fields `type` and `to`. It never looks inside
`payload`, so it works for every game without changes.

Run locally:   uvicorn main:app --host 0.0.0.0 --port 8000
"""
import asyncio
import json
import os
import secrets
import time
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.staticfiles import StaticFiles

from rooms import Room, RoomManager

PROTOCOL_VERSION = 1

# ---- settings (override with environment variables) ----
MAX_ROOMS = int(os.getenv("MAX_ROOMS", "500"))
MAX_PLAYERS_PER_ROOM = int(os.getenv("MAX_PLAYERS_PER_ROOM", "20"))
MAX_MESSAGE_BYTES = int(os.getenv("MAX_MESSAGE_BYTES", "16384"))
HOST_GRACE_SECONDS = float(os.getenv("HOST_GRACE_SECONDS", "120"))
IDLE_TIMEOUT_SECONDS = float(os.getenv("IDLE_TIMEOUT_SECONDS", "1800"))
CLEANUP_INTERVAL_SECONDS = float(os.getenv("CLEANUP_INTERVAL_SECONDS", "15"))
FIRST_MESSAGE_TIMEOUT = 10.0
PUBLIC_URL = os.getenv("PUBLIC_URL", "").rstrip("/")
PLAYER_CLIENT_DIR = Path(os.getenv(
    "PLAYER_CLIENT_DIR", Path(__file__).resolve().parent.parent / "1-player-client"))

manager = RoomManager(MAX_ROOMS, MAX_PLAYERS_PER_ROOM)


def envelope(type_: str, payload: dict | None = None, to: str = "host") -> str:
    return json.dumps({"v": PROTOCOL_VERSION, "type": type_, "from": "relay",
                       "to": to, "payload": payload or {}})


async def safe_send(ws: WebSocket | None, text: str) -> None:
    if ws is None:
        return
    try:
        await ws.send_text(text)
    except Exception:
        pass  # the socket's own receive loop will notice and clean up


async def safe_close(ws: WebSocket, code: int = 1000) -> None:
    try:
        await ws.close(code)
    except Exception:
        pass


async def close_room(room: Room, reason: str) -> None:
    manager.remove(room.code)
    msg = envelope("room.closed", {"reason": reason}, to="all")
    for ws in list(room.players.values()):
        await safe_send(ws, msg)
        await safe_close(ws)
    if room.host is not None:
        await safe_send(room.host, envelope("room.closed", {"reason": reason}))
        await safe_close(room.host)


async def cleanup_loop() -> None:
    while True:
        await asyncio.sleep(CLEANUP_INTERVAL_SECONDS)
        for room in manager.expired(HOST_GRACE_SECONDS, IDLE_TIMEOUT_SECONDS):
            await close_room(room, "expired")


@asynccontextmanager
async def lifespan(_: FastAPI):
    task = asyncio.create_task(cleanup_loop())
    yield
    task.cancel()


app = FastAPI(lifespan=lifespan)


def join_url_for(ws: WebSocket, code: str) -> str:
    if PUBLIC_URL:
        base = PUBLIC_URL
    else:
        proto = ws.headers.get("x-forwarded-proto") or \
            ("https" if ws.url.scheme == "wss" else "http")
        base = f"{proto}://{ws.headers.get('host', 'localhost')}"
    return f"{base}/?room={code}"


async def receive_json(ws: WebSocket) -> dict | None:
    """Next message as a dict, or None if it's too big or not valid JSON."""
    message = await ws.receive()
    if message["type"] == "websocket.disconnect":
        raise WebSocketDisconnect(message.get("code", 1000))
    text = message.get("text")
    if text is None or len(text.encode()) > MAX_MESSAGE_BYTES:
        return None
    try:
        msg = json.loads(text)
    except json.JSONDecodeError:
        return None
    return msg if isinstance(msg, dict) else None


@app.get("/health")
async def health():
    return {"ok": True, "rooms": len(manager.rooms), "protocol": PROTOCOL_VERSION}


@app.websocket("/ws/host")
async def host_socket(ws: WebSocket):
    await ws.accept()
    try:
        first = await asyncio.wait_for(receive_json(ws), FIRST_MESSAGE_TIMEOUT)
    except (asyncio.TimeoutError, WebSocketDisconnect):
        await safe_close(ws)
        return
    if not first:
        await safe_close(ws, 1003)
        return

    payload = first.get("payload") or {}
    room: Room | None = None

    if first.get("type") == "room.create":
        if payload.get("v", first.get("v")) != PROTOCOL_VERSION:
            await safe_send(ws, envelope("room.error", {"reason": "version_mismatch",
                                                        "protocolVersion": PROTOCOL_VERSION}))
            await safe_close(ws)
            return
        room = manager.create(int(payload.get("maxPlayers", MAX_PLAYERS_PER_ROOM)))
        if room is None:
            await safe_send(ws, envelope("room.error", {"reason": "server_full"}))
            await safe_close(ws)
            return
        room.host = ws
        await safe_send(ws, envelope("room.created", {
            "room": room.code, "hostToken": room.host_token,
            "joinUrl": join_url_for(ws, room.code), "maxPlayers": room.max_players}))

    elif first.get("type") == "room.resume":
        room = manager.get(payload.get("room"))
        if room is None or not secrets.compare_digest(
                room.host_token, str(payload.get("hostToken", ""))):
            await safe_send(ws, envelope("room.error", {"reason": "room_not_found"}))
            await safe_close(ws)
            return
        if room.host is not None:
            await safe_close(room.host)  # replace a stale host connection
        room.host = ws
        room.host_lost_at = None
        room.touch()
        await safe_send(ws, envelope("room.resumed", {
            "room": room.code, "joinUrl": join_url_for(ws, room.code),
            "players": list(room.players)}))
        await broadcast(room, envelope("host.reconnected", to="all"))
    else:
        await safe_close(ws, 1003)
        return

    try:
        while True:
            msg = await receive_json(ws)
            if msg is None:
                continue
            room.touch()
            to = msg.get("to")
            if msg.get("type") == "player.close":
                target = room.players.pop(str((msg.get("payload") or {}).get("connId")), None)
                if target:
                    await safe_close(target)
                continue
            text = json.dumps(msg)
            if to == "all":
                await broadcast(room, text)
            elif to in room.players:
                await safe_send(room.players[to], text)
    except WebSocketDisconnect:
        pass
    finally:
        if room.host is ws:  # not already replaced by a resumed connection
            room.host = None
            room.host_lost_at = time.monotonic()
            if room.code in manager.rooms:
                await broadcast(room, envelope("host.disconnected", to="all"))


async def broadcast(room: Room, text: str) -> None:
    for ws in list(room.players.values()):
        await safe_send(ws, text)


@app.websocket("/ws/player")
async def player_socket(ws: WebSocket):
    await ws.accept()
    room = manager.get(ws.query_params.get("room"))
    if room is None:
        await safe_send(ws, envelope("join.error", {"reason": "room_not_found"}, to="player"))
        await safe_close(ws)
        return
    if room.full:
        await safe_send(ws, envelope("join.error", {"reason": "room_full"}, to="player"))
        await safe_close(ws)
        return

    conn_id = "c_" + secrets.token_hex(4)
    room.players[conn_id] = ws
    room.touch()
    await safe_send(room.host, envelope("player.joined", {"connId": conn_id}))
    if room.host is None:
        await safe_send(ws, envelope("host.disconnected", to=conn_id))

    try:
        while True:
            msg = await receive_json(ws)
            if msg is None:
                continue
            room.touch()
            msg["from"] = conn_id  # players can't pretend to be someone else
            msg["to"] = "host"
            await safe_send(room.host, json.dumps(msg))
    except WebSocketDisconnect:
        pass
    finally:
        if room.players.get(conn_id) is ws:
            del room.players[conn_id]
            await safe_send(room.host, envelope("player.left", {"connId": conn_id}))


# Serve the player web page at "/" (mounted last so the routes above win).
if PLAYER_CLIENT_DIR.is_dir():
    app.mount("/", StaticFiles(directory=PLAYER_CLIENT_DIR, html=True), name="player")
