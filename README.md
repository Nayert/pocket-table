# Party Game Platform

A phone-hosted party game platform (Mafia, Poker, more later). One phone runs the **host app**; everyone else joins from their own phone's browser, either on the same Wi-Fi (Local mode) or over the internet through a small relay server (Online mode).

## Layers

| # | Folder | What it is | Tech |
|---|--------|------------|------|
| 1 | [`1-player-client/`](1-player-client/README.md) | Web page players open on their phones | HTML/CSS/JS (or Flutter Web) |
| 2 | [`2-relay-server/`](2-relay-server/README.md) | Cloud server that pairs host and players for Online mode | Python (FastAPI + WebSockets) |
| 3 | [`3-transport/`](3-transport/README.md) | Hides Local vs Online from the rest of the host app | Dart |
| 4 | [`4-platform-core/`](4-platform-core/README.md) | Lobby, sessions, game picker, action validation | Dart |
| 5 | [`5-games/`](5-games/README.md) | Game plugins: Mafia, Poker | Dart (prototype in Python) |
| 6 | [`6-host-app-ui/`](6-host-app-ui/README.md) | Screens on the host phone | Flutter |
| — | [`shared-protocol/`](shared-protocol/README.md) | JSON message types every layer speaks | JSON |

## How the layers depend on each other

```
            Host phone (one Flutter app)
 ┌──────────────────────────────────────────────┐
 │ 6 Host app UI                                │
 │      │ reads state / calls actions           │
 │ 4 Platform core  ◄──►  5 Games (plugins)     │
 │      │ sendTo / broadcast / onMessage        │
 │ 3 Transport  (Local server | Online client)  │
 └──────┬───────────────────────────┬───────────┘
        │ Local: direct WebSocket   │ Online: WebSocket
        │                           ▼
        │                    2 Relay server (cloud)
        │                           │
        ▼                           ▼
            1 Player client (browser)

 Everything that crosses a network uses the shared protocol.
```

Rules that hold everywhere:

- **Only layer 4 and 5 know game rules.** The player client, relay and transport just move messages.
- **Dependencies point downward.** Games never touch the transport; the UI never touches sockets.
- **Never trust the client.** Every action is checked in layer 4 (and the game in layer 5) before it changes anything.
- **Private data only goes to its owner.** Roles and hole cards are sent with `sendTo(player)`, never `broadcast()`.

## Folder layout

Layers 3, 4 and 5 are plain Dart packages. Layer 6 is the Flutter app, and it depends on them through `path:` dependencies in its `pubspec.yaml`, so they ship as one host app while each layer keeps its own folder, README and tests.

## Getting started

1. **Test the game rules:** `cd 5-games/prototype && python -m unittest test_prototypes.py`
2. **Test the relay:** see `2-relay-server/README.md` (`pip install -r requirements.txt`, then `python -m pytest`)
3. **Test the Dart layers:** `dart test` in `4-platform-core` and `5-games` (needs the Dart/Flutter SDK)
4. **Run the host app:** follow "First-time setup" in `6-host-app-ui/README.md`, then pick **Same Wi-Fi**, and scan the QR code with another phone on the same Wi-Fi
5. **Go online:** run or deploy the relay, then pick **Online** in the host app and enter its address
