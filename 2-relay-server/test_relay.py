"""Run with:  python -m pytest test_relay.py   (from this folder)"""
import json

from fastapi.testclient import TestClient

import main
from main import app


def msg(type_, payload=None, to="host", v=1):
    return json.dumps({"v": v, "type": type_, "to": to, "payload": payload or {}})


def create_room(host):
    host.send_text(msg("room.create", {"v": 1, "maxPlayers": 2}))
    reply = json.loads(host.receive_text())
    assert reply["type"] == "room.created"
    return reply["payload"]


def test_health():
    with TestClient(app) as c:
        assert c.get("/health").json()["ok"] is True


def test_full_flow():
    with TestClient(app) as c, c.websocket_connect("/ws/host") as host:
        info = create_room(host)
        code = info["room"]
        assert len(code) == 4 and "?room=" + code in info["joinUrl"]

        with c.websocket_connect(f"/ws/player?room={code.lower()}") as p1:
            joined = json.loads(host.receive_text())
            assert joined["type"] == "player.joined"
            cid = joined["payload"]["connId"]

            # player -> host; "from" is overwritten so it can't be spoofed
            p1.send_text(json.dumps({"v": 1, "type": "join", "from": "host",
                                     "payload": {"name": "Ana"}}))
            got = json.loads(host.receive_text())
            assert got["type"] == "join" and got["from"] == cid
            assert got["payload"] == {"name": "Ana"}

            # host -> one player, and host -> all
            host.send_text(msg("join.ok", {"playerId": "p1"}, to=cid))
            assert json.loads(p1.receive_text())["type"] == "join.ok"
            host.send_text(msg("lobby.update", {"players": []}, to="all"))
            assert json.loads(p1.receive_text())["type"] == "lobby.update"

            # room full at 2 players
            with c.websocket_connect(f"/ws/player?room={code}") as p2:
                json.loads(host.receive_text())  # player.joined
                with c.websocket_connect(f"/ws/player?room={code}") as p3:
                    err = json.loads(p3.receive_text())
                    assert err["payload"]["reason"] == "room_full"
            left = json.loads(host.receive_text())
            assert left["type"] == "player.left"


def test_unknown_room():
    with TestClient(app) as c, c.websocket_connect("/ws/player?room=ZZZZ") as p:
        assert json.loads(p.receive_text())["payload"]["reason"] == "room_not_found"


def test_version_mismatch():
    with TestClient(app) as c, c.websocket_connect("/ws/host") as host:
        host.send_text(msg("room.create", {"v": 99}, v=99))
        assert json.loads(host.receive_text())["payload"]["reason"] == "version_mismatch"


def test_host_disconnect_and_resume():
    with TestClient(app) as c:
        with c.websocket_connect("/ws/host") as host:
            info = create_room(host)
        code, token = info["room"], info["hostToken"]
        with c.websocket_connect(f"/ws/player?room={code}") as p:
            assert json.loads(p.receive_text())["type"] == "host.disconnected"
            with c.websocket_connect("/ws/host") as host2:
                host2.send_text(msg("room.resume", {"room": code, "hostToken": "wrong"}))
                assert json.loads(host2.receive_text())["type"] == "room.error"
            with c.websocket_connect("/ws/host") as host3:
                host3.send_text(msg("room.resume", {"room": code, "hostToken": token}))
                resumed = json.loads(host3.receive_text())
                assert resumed["type"] == "room.resumed"
                assert len(resumed["payload"]["players"]) == 1
                assert json.loads(p.receive_text())["type"] == "host.reconnected"


def test_player_page_is_served():
    with TestClient(app) as c:
        r = c.get("/")
        if main.PLAYER_CLIENT_DIR.is_dir():
            assert r.status_code == 200 and "<html" in r.text.lower()
