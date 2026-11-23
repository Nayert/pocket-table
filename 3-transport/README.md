# Layer 3: Transport

**Tech:** Dart
**Runs on:** the host phone, inside the host app

## What it does

Gives the rest of the host app **one interface** for talking to players, whichever mode it's in:

```dart
abstract class Transport {
  Future<void> start();                         // open server / connect to relay
  Future<void> stop();
  void sendTo(String playerId, Map msg);
  void broadcast(Map msg);
  Stream<IncomingMessage> get onMessage;
  Stream<String> get onJoin;                    // connection id
  Stream<String> get onLeave;
  JoinInfo get joinInfo;                        // what the UI shows: QR, code, URL
}
```

Two implementations:

| | `LocalTransport` | `OnlineTransport` |
|-|-------------------|--------------------|
| How | Runs an HTTP + WebSocket server on the phone | Connects to the relay as the host |
| Serves player page | Yes, from app assets | No — the relay does |
| `joinInfo` | QR code of `http://<phone-ip>:<port>` | Room code + QR of the relay link |

## What it needs from other layers

| From | Needs |
|------|-------|
| **Shared protocol** | Envelope format, relay messages |
| **2 Relay server** (Online) | Relay URL, `room.create` → `room.created`, forwarding by `to` |
| **1 Player client** (Local) | The built player page bundled as app assets to serve |
| **4 Platform core** | To call `start()`, `sendTo()`, `broadcast()` and listen to the streams |

## What it provides to other layers

- To **4 Platform core**: the `Transport` interface above
- To **6 Host app UI** (via core): `joinInfo` for the QR code / room code
- To **1 Player client**: a WebSocket endpoint (Local mode)

## What it does NOT do

- Doesn't know about players' names, seats, reconnect tokens or games — just connection ids and raw messages. Sessions belong to the core.
- Never decides who gets what. If the core says `sendTo(p)`, it goes only to `p`.

## Key notes

- **The games never know which mode they're running in.** If you find a game checking the mode, something's in the wrong layer.
- Local mode: find the phone's Wi-Fi IP; handle the case where there isn't one (hotspot, no network).
- iPhone needs the local network permission for Local mode.
- Write a `FakeTransport` for tests so the core and games can be tested with no sockets at all.

## Files

```
3-transport/
  pubspec.yaml
  lib/transport.dart                # exports everything below
  lib/src/transport_base.dart       # Transport interface, JoinInfo, IncomingMessage, protocolVersion
  lib/src/local_transport.dart      # HTTP + WebSocket server on the phone, finds the Wi-Fi IP
  lib/src/online_transport.dart     # relay client with automatic room.resume on drop
  lib/src/fake_transport.dart       # in-memory, for tests
```

This is a plain Dart package (no Flutter), used by `4-platform-core` and `6-host-app-ui` through `path:` dependencies.
