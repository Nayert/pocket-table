# Session notes: unattended build session (2026-11-23)

Written for the owner. Most important first.

## ⚠ Action needed: Render isn't auto-deploying

Every push this session landed on `main`, but **https://pocket-table-relay.onrender.com still serves the player page from before the session.** The live `app.js` is stamped `Last-Modified: 18:17 UTC`, which is older than every commit since `4b28a4c`, and it doesn't contain the new code (no `CLOSED_REASONS`, no `id="closed-view"`). `/health` is fine.

Render has never posted a deploy status on any commit in the GitHub repo, not even the commit that is live. That usually means one of these:

1. The service was created from the **public Git URL** rather than through the connected GitHub app. Render doesn't auto-deploy those.
2. **Auto-Deploy is off** in Settings → Build & Deploy.
3. A build is failing. That's unlikely: the build only runs `pip install -r 2-relay-server/requirements.txt`, which this session didn't change.

**To fix:** in the Render dashboard, open `pocket-table-relay` and click *Manual Deploy → Deploy latest commit* to go live now. Then check Settings → Build & Deploy → Auto-Deploy, and connect the GitHub account if it says the repo is public/unlinked. I didn't change anything on Render. The Render tool asks the account owner to confirm which workspace to act on, and you weren't here to confirm it.

## Environment set up this session (on this machine, not in the repo)

- **Dart SDK 3.14.1** in `~/.local/share/dart-sdk`, linked as `~/.local/bin/dart`. It wasn't installed before.
- **Flutter 3.50.1 stable** in `~/.local/share/flutter`, a shallow clone of the official repo. This machine has no `unzip` and I couldn't use sudo, so I bootstrapped it with a tiny Python `unzip` stand-in kept in the session scratchpad. If `flutter` complains about `unzip` later, run `sudo pacman -S unzip` and it bootstraps normally.
- **Relay venv** at `2-relay-server/.venv` (gitignored), because system Python has no pytest or fastapi.

## What was done

Baseline before the session: prototypes 13, relay 6, core 6, games 15 tests, all passing.
At the end: **prototypes 38, relay 6, transport 3, core 13, games 52, host app 6 (Flutter widget tests)**, all passing. There's also an end-to-end run (local relay + real `OnlineTransport` host + 2 WebSocket phones playing a poker hand) and a jsdom smoke test of the player page with ~60 checks. Both were run from the scratchpad and are not committed (see "Ideas" below).

### Phase 0: setup
- Installed Dart and Flutter, and created the relay venv (see above). Baseline green. Live `/health` and `/` OK.

### Phase 1: player web page (`ec19755`, `c918ab1`, `5568afb`)
- Mobile-first rewrite of `1-player-client` (no build step, still plain JS):
  - **Join:** the room code is cleaned and uppercased (4 characters), pre-filled from `?room=`. Names are validated, and every `join.error` reason has its own message.
  - **Connection:** a status label plus an `aria-live` banner for connecting, reconnecting and host away. Reconnects back off from 1 s to 10 s with jitter, and there's a "Retry now" button. The page reconnects as soon as it's visible again or the phone is back online.
  - **Closed screen** for `room.closed` (host left, kicked, expired) and for a saved seat whose room no longer exists.
  - **Tap-to-reveal** for secrets (new optional `secret: true` screen field), with "Hide" to cover them again. Secrets are covered again automatically when the phone locks or the connection drops.
  - **Bets:** slider + number box + Min/Half/Max, snapped to legal amounts, so an illegal amount can't be sent. A half-entered raise survives other players' moves.
  - **Accessibility:** AA contrast, 44 px+ targets, labelled cards, ✓ + `aria-pressed` for selections, safe areas on all sides.
- After the security review: "Continue as <name>?" (with "Not me") before retaking a saved seat after a refresh. Seat tokens expire after 12 h and only one is kept. Invisible and bidi characters are stripped from names.

### Phase 2: Mafia and Poker (`c72550c`, `14dd511`, `36a99eb`, `7004847`, plus `ed02774`)
- **Core:** `secret` screens, `Game.onPlayerRemoved` (kick or Leave mid-game removes the seat for good), action values must be whole numbers in range and on the step (the max is always allowed), name cleaning, `startProblem`, and safe parsing of a malformed `choice`.
- **Mafia:** the full rules are in `5-games/README.md`. Roles scale with player count (Mafia capped below half). Everyone's night options are identical. Doctor and Detective, plurality or majority voting with tie rules, elimination reveals, both win conditions. Disconnected players don't block a phase, and leaving kills the player. The minimum 4-player game is tested.
- **Poker:** new `prototype/poker.py` betting engine, ported to Dart:
  - blinds and button rotation (including heads-up), min-raise, and short all-ins that don't reopen raising
  - side pots, split pots with the odd chip, busting out and game over
  - disconnected players sit out new hands; a 20 s grace on their turn, which reconnecting never extends
  - leaving mid-hand folds the player for good
- Hole cards and roles appear only in each owner's secret screen body. Titles and lines are public.

### Phase 3: host app (`5671750`, plus `ed02774`)
- **Mode select:** Same Wi-Fi or Online. Online defaults to the Render relay, with a "Waking server… Ns" card and Cancel. `OnlineTransport.wakeRelay` polls `/health` for up to 100 s, because `start()` itself only waits 10 s and would always fail on a cold free instance.
- **Lobby:** big room code, QR, link with copy, players with confirm-to-remove, game picker, settings, and Start disabled with the reason shown.
- **Table:** draws only `publicState()`. The turn is shown by an arrow and the word "turn", plus a countdown, log, players sheet and End.
- After the security review: plain `http://` relays are refused unless they're on the local network, the QR link must point at the relay host, `/health` reads are capped, and the relay URL is saved only after it answers.

## Decisions I made on your behalf

1. **`secret: true` screen field** (protocol addition, no version bump). It hides `body` and `cards` behind tap-to-reveal, while `title` and `lines` stay visible, so games keep public info (pot, whose turn, the morning news) in lines.
2. **Mafia night: everyone picks from the same list**, all living players including themselves. Role-specific option lists leaked roles over the shoulder, which the security review rated high. Mafia picks on a teammate are ignored, and the Doctor may self-protect. Mafia teammates no longer see each other's live picks, because those redraws leaked who was Mafia. They see the team list and "most picks wins, ties random".
3. **Vote rules:** the most votes is out, and a tie or a "Nobody" lead means no one is out. **Majority** (more than half of the living) is an optional host setting, off by default.
4. **Disconnects:** a Mafia phase ends early once all *connected* living players have acted. Poker sits disconnected players out of new hands, and if fewer than two can play, the table waits. A disconnected player's turn auto-checks or folds after 20 s, even with "no limit" turn time, and reconnecting doesn't extend it.
5. **Leave or kick mid-game = out for good**, through `onPlayerRemoved`. A dropped connection keeps the seat for reconnecting.
6. **Short blind all-in:** the others only need to match what was actually posted (the existing Dart behaviour, kept).
7. **Refresh asks "Continue as <name>?"** instead of silently retaking the seat, because phones get passed around at parties. A lock screen still reconnects silently.
8. **Plain http relays are refused** unless the address is on the local network.
9. I set up `prototype/poker.py` first, because there was no Python betting prototype and the workflow says the prototype comes first.

## Untested or needs a device

- **Host app on a real phone:** the widget tests run headless (`flutter test`), but no Android or iOS build was made, because there's no Android SDK or Xcode here. Untested: QR scanning, wakelock, `shared_preferences`, Local mode serving the page from assets, and the iOS local-network prompt. Follow "First-time setup" in `6-host-app-ui/README.md`.
- **Player page in a real mobile browser:** checked in jsdom only, not on real Safari or Chrome. Worth a look at 360 px wide and with the iOS notch.
- **Live deploy:** see the top section. Nothing from this session is live yet.
- The relay venv here is Python 3.14, while Render uses 3.12.7. No 3.14-only features are used.

## Open issues and low-severity findings (not fixed)

- **Render auto-deploy** (top of this file).
- Poker: a player can skip blinds by being offline between hands, because sitting out skips the blinds (no dead-blind rule). It would be fixed with "missed blinds are posted on return".
- Poker with "no limit" turn time: a brief disconnect still starts the 20 s grace, and reconnecting doesn't cancel it. That's intentional, to stop stalling, but it's strict.
- The kick isn't a ban: a kicked player can rejoin the *lobby* with the same name. During a game, `game_in_progress` blocks them. The dialog text now says exactly that.
- A cancelled "Waking server…" keeps polling `/health` in the background until its 100 s timeout. Harmless.
- `room.error` replies to `room.resume` aren't read by reason in `OnlineTransport` (it just stops retrying).
- `Screen.input` can't set `step`, `default` or `secret` yet. No game uses input screens.
- Flutter 3.50 marks `package:flutter/material.dart` as deprecated in favour of `package:material_ui`. That's 6 analyzer *infos*, left alone because it's a framework-wide migration.
- The prototypes use Python's `random`, which is fine because they never ship. The Dart games use `Random.secure()` via the platform.
- Layer 3's `transport_base.dart` comment no longer mentions game terms (fixed). The core's `game.dart` docs mention roles and cards, which is fine for layer 4.

## How to try it

1. **Deploy first** (Manual Deploy, see the top section). Then check https://pocket-table-relay.onrender.com/health. The first request may take about a minute.
2. **Host app:** from `6-host-app-ui`, run `flutter create . --project-name host_app --platforms android,ios`, then `flutter pub get` and `flutter run` with the phone plugged in. Add the permissions listed in the README.
3. In the app, pick **Online**. The default server is already filled in. Wait for "Waking server…", and the lobby shows a room code and QR.
4. On two or more other phones, scan the QR, or open https://pocket-table-relay.onrender.com and type the code. Enter a name and Join.
5. Pick **Poker** (2+ players) or **Mafia** (4+ players), adjust the settings, and press Start. Private info appears on each phone behind "Tap to reveal". The host phone shows only the shared table.
6. **Same Wi-Fi** mode: pick "Host on this Wi-Fi" and have players scan the QR (`http://<phone-ip>:<port>/?room=CODE`).

Tests: `cd 5-games/prototype && python -m unittest test_prototypes.py`; `cd 2-relay-server && python -m pytest`; `dart test` in `3-transport`, `4-platform-core` and `5-games`; `flutter test` in `6-host-app-ui`.

## Ideas for next time (not started)

- Commit the jsdom smoke test for the player page (it needs `npm i jsdom`) and the end-to-end Dart script as a CI check.
- A dead-blind rule for poker, a lobby ban list for kicks, and a host "pause" button (in the layer 6 README but not built).
