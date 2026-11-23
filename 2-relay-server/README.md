# Layer 2: Relay Server

**Tech:** Python (FastAPI + WebSockets)
**Runs on:** a cloud host. Only used in Online mode.

## What it does

- Creates rooms and short room codes when a host asks
- Holds one WebSocket to the host and one per player in each room
- Forwards messages: player → host, and host → one player or all players
- Serves the player web page (layer 1), so online players have one URL to visit
- Cleans up idle rooms and enforces a player limit per room
- Tells players when the host disconnects or comes back

## What it needs from other layers

| From | Needs |
|------|-------|
| **Shared protocol** | The envelope format and the relay-only messages (`room.create`, `player.joined`, `host.disconnected`, …) |
| **3 Transport – Online** | To connect as the host, send `room.create`, and address messages with `to` |
| **1 Player client** | The built static files to serve; players to send `join` with a room code |

## What it provides to other layers

- Room code + join URL for the host app to display
- A stable connection id per player, passed to the host with `player.joined`
- Message delivery between host and players
- Connection events (`player.joined`, `player.left`, `host.disconnected`, `host.reconnected`)

## What it does NOT do

- **Knows nothing about games.** It never reads `payload`. It only looks at `type`, `room` and `to`. This keeps it small and lets every future game reuse it untouched.
- Doesn't validate actions or keep game state — the host does that.
- Doesn't decide who's allowed in beyond room capacity; the host accepts or rejects joins.

## Key notes

- **WSS (secure WebSockets)** once deployed; plain WS is fine locally.
- Idle timeout (e.g. room closed after 10 min with no host).
- Max players per room and max message size to stop abuse.
- Give the host a grace period to reconnect before closing the room.
- Room codes: 4–5 characters, no confusable letters (no O/0, I/1).

## Files

```
2-relay-server/
  main.py           # FastAPI app: /ws/host, /ws/player, /health, serves the player page at /
  rooms.py          # Room + RoomManager: codes, capacity, idle/host-gone expiry
  test_relay.py     # pytest tests (create, join, forward, full room, resume, version check)
  requirements.txt
```

## Running it

```bash
cd 2-relay-server
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
python -m pytest                                   # run the tests
uvicorn main:app --host 0.0.0.0 --port 8000        # start it
```

Open `http://localhost:8000/health` to check it's up. In the host app choose **Online** and enter `http://<this computer's IP>:8000` to test on your own network.

Settings (environment variables): `MAX_ROOMS`, `MAX_PLAYERS_PER_ROOM` (20), `MAX_MESSAGE_BYTES` (16384), `HOST_GRACE_SECONDS` (120), `IDLE_TIMEOUT_SECONDS` (1800), `PUBLIC_URL` (set this when deployed so join links use your real https address), `PLAYER_CLIENT_DIR`.

### Deploying

Any host that runs Python and supports WebSockets works (Render, Railway, Fly.io). Upload the repo, set the start command to
`uvicorn main:app --host 0.0.0.0 --port $PORT` with `2-relay-server` as the working directory, and set `PUBLIC_URL`. These hosts give you HTTPS, which makes the sockets WSS automatically.
