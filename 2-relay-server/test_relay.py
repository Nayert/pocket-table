"""Run with:  python -m pytest test_relay.py   (from this folder)"""
import json

import pytest
from fastapi.testclient import TestClient

import main
from main import app


@pytest.fixture(autouse=True)
def fresh_limits():
    for limiter in main.LIMITERS:
        limiter.reset()
    yield


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


# ---- website polish: 404, https, favicon, robots/sitemap ----

def test_unknown_page_gets_custom_404():
    with TestClient(app) as c:
        r = c.get("/no/such/page")
        assert r.status_code == 404
        if main.PLAYER_CLIENT_DIR.is_dir():
            assert "Page not found" in r.text and "/style.css" in r.text


def test_http_is_redirected_to_https():
    with TestClient(app) as c:
        r = c.get("/?room=ABCD", headers={"x-forwarded-proto": "http", "host": "games.example"},
                  follow_redirects=False)
        assert r.status_code == 301
        assert r.headers["location"] == "https://games.example/?room=ABCD"


def test_https_gets_hsts_and_local_http_is_untouched():
    with TestClient(app) as c:
        r = c.get("/health", headers={"x-forwarded-proto": "https"})
        assert r.status_code == 200 and "max-age" in r.headers["strict-transport-security"]
        r = c.get("/health")  # no proxy header, like running on your own computer
        assert r.status_code == 200 and "strict-transport-security" not in r.headers


def test_robots_and_sitemap():
    with TestClient(app) as c:
        h = {"x-forwarded-proto": "https", "host": "games.example"}
        robots = c.get("/robots.txt", headers=h)
        assert robots.status_code == 200
        assert "Disallow: /ws/" in robots.text
        assert "Sitemap: https://games.example/sitemap.xml" in robots.text
        sm = c.get("/sitemap.xml", headers=h)
        assert sm.status_code == 200 and sm.headers["content-type"].startswith("application/xml")
        assert "<loc>https://games.example/</loc>" in sm.text


def test_favicon():
    with TestClient(app) as c:
        r = c.get("/favicon.ico")
        if (main.PLAYER_CLIENT_DIR / "favicon.ico").is_file():
            assert r.status_code == 200 and r.headers["content-type"] == "image/x-icon"


# ---- join validation and spam protection ----

def test_badly_formed_codes_are_rejected():
    with TestClient(app) as c:
        for bad in ["", "AB", "ABCDE", "AB1O", "<scr"]:
            with c.websocket_connect(f"/ws/player?room={bad}") as p:
                assert json.loads(p.receive_text())["payload"]["reason"] == "room_not_found"


def test_guessing_codes_gets_rate_limited(monkeypatch):
    with TestClient(app) as c, c.websocket_connect("/ws/host") as host:
        code = create_room(host)["room"]
        for _ in range(main.BAD_CODES_PER_MINUTE):
            with c.websocket_connect("/ws/player?room=ZZZZ") as p:
                assert json.loads(p.receive_text())["payload"]["reason"] == "room_not_found"
        # even the right code is refused for a while after that
        with c.websocket_connect(f"/ws/player?room={code}") as p:
            assert json.loads(p.receive_text())["payload"]["reason"] == "rate_limited"
        # someone on another network is unaffected
        with c.websocket_connect(f"/ws/player?room={code}",
                                 headers={"x-forwarded-for": "203.0.113.9"}) as p:
            assert json.loads(host.receive_text())["type"] == "player.joined"


def test_too_many_joins_get_rate_limited(monkeypatch):
    monkeypatch.setattr(main.join_limiter, "limit", 3)
    with TestClient(app) as c:
        for _ in range(3):
            with c.websocket_connect("/ws/player?room=ZZZZ") as p:
                assert json.loads(p.receive_text())["payload"]["reason"] == "room_not_found"
        with c.websocket_connect("/ws/player?room=ZZZZ") as p:
            assert json.loads(p.receive_text())["payload"]["reason"] == "rate_limited"


def test_too_many_rooms_get_rate_limited(monkeypatch):
    monkeypatch.setattr(main.room_limiter, "limit", 2)
    with TestClient(app) as c:
        for _ in range(2):
            with c.websocket_connect("/ws/host") as host:
                create_room(host)
        with c.websocket_connect("/ws/host") as host:
            host.send_text(msg("room.create", {"v": 1}))
            assert json.loads(host.receive_text())["payload"]["reason"] == "rate_limited"


def test_message_flood_is_dropped(monkeypatch):
    monkeypatch.setattr(main, "PLAYER_MESSAGES_PER_10S", 3)
    with TestClient(app) as c, c.websocket_connect("/ws/host") as host:
        code = create_room(host)["room"]
        with c.websocket_connect(f"/ws/player?room={code}") as p:
            json.loads(host.receive_text())  # player.joined
            for i in range(5):
                p.send_text(json.dumps({"v": 1, "type": "tap", "payload": {"i": i}}))
            got = [json.loads(host.receive_text())["payload"].get("i") for _ in range(3)]
            assert got == [0, 1, 2]
