# Shared: Message Protocol (JSON)

The single list of messages that cross a network in this platform. Every layer that sends or receives over a socket follows this file. **If it isn't written here, nobody sends it.**

## What it does

- Defines the envelope every message uses
- Lists every message type, who sends it and who receives it
- Carries a protocol version so mismatched host apps and player pages fail loudly instead of silently

## Used by

| Layer | How |
|-------|-----|
| 1 Player client | Sends join/action messages, renders screen messages |
| 2 Relay server | Reads only the envelope fields it needs (`type`, `room`, `to`); passes `payload` through untouched |
| 3 Transport | Wraps/unwraps envelopes for the core |
| 4 Platform core | Produces and consumes every platform and game message |
| 5 Games | Define the *contents* of `game.*` payloads (via the core, never directly on the wire) |

## What it needs from other layers

Nothing — it's a document. Every other layer depends on it, so change it carefully and bump the version when you break something.

## Envelope

```json
{
  "v": 1,
  "type": "lobby.update",
  "from": "host",
  "to": "p_7f3a",
  "payload": { }
}
```

| Field | Meaning |
|-------|---------|
| `v` | Protocol version (integer). Required on `join`; recommended on all |
| `type` | Message type, `area.name` |
| `from` | `"host"`, a player id, or `"relay"` |
| `to` | A player id, `"all"`, or `"host"` |
| `payload` | Type-specific body |

## Message types

### Connection (player ↔ host)

| Type | Direction | Payload |
|------|-----------|---------|
| `join` | player → host | `{ v, room, name, reconnectToken? }` |
| `join.ok` | host → player | `{ playerId, reconnectToken, protocolVersion }` |
| `join.error` | host/relay → player | `{ reason: "room_not_found" \| "room_full" \| "name_taken" \| "bad_name" \| "version_mismatch" \| "game_in_progress" }` |
| `leave` | player → host | `{}` |
| `room.closed` | host/relay → player, relay → host | `{ reason: "host_left" \| "kicked" \| "expired" }` (the relay also tells the host when it expires the room) |

Players connect to `/ws/player?room=CODE` on whatever served the page (the relay, or the host phone in Local mode).

### Relay only (host ↔ relay)

| Type | Direction | Payload |
|------|-----------|---------|
| `room.create` | host → relay | `{ v, maxPlayers }` |
| `room.created` | relay → host | `{ room, hostToken, joinUrl, maxPlayers }` |
| `room.resume` | host → relay | `{ room, hostToken }` (after the host's connection drops) |
| `room.resumed` | relay → host | `{ room, joinUrl, players: [connId] }` |
| `room.error` | relay → host | `{ reason: "version_mismatch" \| "server_full" \| "room_not_found" }` |
| `player.joined` / `player.left` | relay → host | `{ connId }` |
| `player.close` | host → relay | `{ connId }` (drop a connection) |
| `host.disconnected` / `host.reconnected` | relay → players | `{}` |

The relay sets `from` on every player message to that player's `connId`, so players can't pretend to be someone else.

### Platform (host → players)

| Type | Payload |
|------|---------|
| `lobby.update` | `{ players: [{ id, name, connected }], selectedGame, maxPlayers }` |
| `game.started` | `{ game, name }` |
| `game.ended` | `{}` (back to the lobby) |
| `action.error` | `{ message }` |

### Screens (host → one player)

Every screen payload can include `title`, `body`, `cards` (e.g. `["As","Td"]`, `"??"` = face down), `lines` (list of text), `secondsLeft`, `actionId` and `secret`.

A screen can also set `secret: true` (optional, added without a version bump). The page then hides `body` and `cards` behind a "Tap to reveal" button the player can toggle, so people nearby can't read a role or hole cards over their shoulder. `title` and `lines` stay visible, so put only public information (pot, whose turn) there. A reveal lasts while consecutive screens carry the same secret `body` and `cards`; anything else hides it again. Hosts that never send it get the old behaviour.

| Type | Extra payload |
|------|---------------|
| `screen.waiting` | – |
| `screen.private` | optional `options` (e.g. a "Ready" button) |
| `screen.choice` | `options: [{ id, label, sub?, input?: { min, max, step, label?, default? } }]`, `min`, `max`, `submitLabel?` |
| `screen.input` | `inputKind: "number" \| "text"`, `min?`, `max?` (for text: max length), `step?`, `default?`, `submitLabel?` |
| `screen.results` | optional `options` |

An option with `input` (like poker's Raise) asks for a number before sending.

### Actions (player → host)

| Type | Payload |
|------|---------|
| `action` | `{ actionId, choice: [optionId], value? }` (`choice` is `[]` for `screen.input`) |

The host only accepts an action whose `actionId` matches the screen it last sent that player, whose option ids were on that screen, and whose `value` is valid:

- **Numbers** (an option's `input`, or a number `screen.input`): a whole number from `min` to `max`, on a multiple of `step` counted from `min`. `max` itself is always allowed even when it's off the step grid (e.g. going all in).
- **Text** (`inputKind: "text"`): not empty or only spaces, and at most `max` characters (60 if the screen gives no `max`).

Anything else gets `action.error` and the player's current screen is sent again.

`GET /health` on the relay (`{"ok": true, "rooms", "protocol"}`) is plain HTTP, not part of this protocol. The host app polls it to wake a sleeping relay before opening `/ws/host`.

The player client only knows these generic screens. Games express everything through them, so the page never needs updating for a new game.

## Versioning rules

- Bump `v` when a change would break an older host or page.
- Host rejects a `join` with a different major version using `join.error { reason: "version_mismatch" }`.
- Adding an optional field doesn't need a bump.
