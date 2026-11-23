# Layer 1: Player Client

**Tech:** HTML/CSS/JavaScript (or Flutter Web / Dart)
**Runs on:** each player's phone, in the browser

## What it does

- Join screen: enter room code and name (or arrive pre-filled from a QR link)
- Opens a WebSocket to either the host phone (Local) or the relay (Online)
- Renders whatever generic screen it's sent: lobby, waiting, private info, choices, number/text input, results
- Sends the player's taps back as `action` messages
- Handles reconnects automatically

## What it needs from other layers

| From | Needs |
|------|-------|
| **Shared protocol** | The list of screen and action messages, and the current protocol version |
| **2 Relay server** (Online) | To be served from the relay's URL; a WebSocket endpoint that accepts `join` |
| **3 Transport – Local** (Local) | The host phone to serve this page and a WebSocket endpoint on the LAN |
| **4 Platform core** | `join.ok` with a `playerId` and `reconnectToken`; screen messages telling it what to show |

## What it provides to other layers

- `join` (with protocol version and, if it has one, a reconnect token)
- `action` messages with the player's choices
- `leave` when the player quits

## What it does NOT do

- **No game logic.** It doesn't know what Mafia or Poker is. It can't check whether a move is legal, and it never holds information it wasn't sent. This is what stops cheating.
- No talking to other players directly — everything goes via the host.

## Key notes

- **Reconnect token in `localStorage`** so a refresh or lock screen doesn't lose your seat. On load, if a token exists for this room, send it with `join`.
- **Mobile-first**: big buttons, one action per screen, works in portrait, no zoom-on-focus.
- Show a clear banner on `host.disconnected` and keep retrying.
- Screens are driven by `type` only; adding a new game should need zero changes here.

## Files

```
1-player-client/
  index.html      # join form + container for screens
  style.css       # mobile-first, big buttons
  app.js          # socket, join, reconnect token, message dispatch
  screens.js      # one render function per screen.* type, cards, countdown
```

## Running it

There's no build step. The page is served by whichever host the player connects to:

- **Online:** the relay serves this folder at `/` (see `2-relay-server`).
- **Local:** the host app serves a copy from its assets. After editing anything here, run
  `6-host-app-ui/tool/copy_player_client.sh` so the app gets the new version.

The page always connects back to `/ws/player?room=CODE` on the address it was loaded from, so the same files work in both modes.
