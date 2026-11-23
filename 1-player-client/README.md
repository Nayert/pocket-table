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

- **Reconnect token in `localStorage`** so a refresh or lock screen doesn't lose your seat. It's saved with a timestamp, ignored after 12 hours, and only the latest room's token is kept. After a refresh the page asks "Continue as <name>?" (with "Not me") before rejoining, because phones get passed around at parties. A lock screen reconnects without asking, since the page never reloaded.
- **Revealed secrets are covered again** when the page is hidden (phone locked or put away) or the connection drops.
- **Names:** control and invisible formatting characters (zero-width, direction overrides) are removed, and the name is NFKC-normalised, before sending. The host enforces its own rules too.
- **Mobile-first**: big buttons, one action per screen, works in portrait, no zoom-on-focus.
- Show a clear banner on `host.disconnected` and keep retrying.
- Screens are driven by `type` only; adding a new game should need zero changes here.
- **Connection states:** a status label (Connecting / Connected / Reconnecting / Host away) and a banner for anything that needs attention. Reconnects back off from 1s to 10s with jitter, retry immediately when the page becomes visible or the phone comes back online, and offer "Retry now" after a few failures.
- **Closed screen** for `room.closed` (host left, kicked, expired) and for a saved seat whose room no longer exists.
- **Secrets:** on screens with `secret: true`, the body and cards start hidden behind "Tap to reveal" / "Hide" (title and lines stay visible). The reveal lasts while the same secret stays on screen and hides again on any change.
- **Amounts:** options with `input` get a slider, a number box and Min / Half / Max buttons, all snapped to `min`/`max`/`step`; an illegal amount can't be sent. A half-entered amount survives a refresh of the same screen (another player acting).
- **Accessibility:** WCAG AA contrast, 44px+ tap targets, screen titles announced through an `aria-live` region, selections marked with ✓ and `aria-pressed`, cards labelled ("Ace of spades"), and nothing shown by colour alone.

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
