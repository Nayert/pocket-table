---
description: Long unattended build session for Pocket Table - polish the player page, finish Mafia + Poker, improve host app screens, keep the Render relay deploying. Uses the project subagents.
---

# Pocket Table: unattended build session

You're working on **Pocket Table**, a phone-hosted party game platform. Read `README.md` and each layer's `README.md` before you start. The owner (Treyan) is away for several hours and **cannot answer questions**. Don't stop to ask. Make the most reasonable choice, write it down in `SESSION_NOTES.md` (see the end), and carry on. Only stop early if something can't be undone and could reasonably go either way.

## Ground rules (from README.md, never break these)

- **Only layers 4 (platform core) and 5 (games) know game rules.** The player client, relay and transport just move messages.
- **Dependencies point downward.** Games never touch the transport, and the UI never touches sockets.
- **Never trust the client.** Every action is validated in layer 4 and the game before it changes state.
- **Private data only goes to its owner.** Roles, night results and hole cards use `sendTo(player)`, never `broadcast()`.
- **`shared-protocol/README.md` is the single source of truth for messages.** If you add or change a message, update that file in the same commit. Bump the protocol version only for breaking changes.
- **The player client exists twice:** `1-player-client/` (the source) and `6-host-app-ui/assets/player_client/` (a copy for Local mode). Only edit the source, then sync it with the `client-sync` agent.

## Git and deploy

- Work on `main` and **push straight to `main`** after each finished, tested chunk of work. Use small commits with clear messages (`player-client: add reconnect banner`, `poker: side pots for all-in`).
- Every push to `main` auto-deploys the relay on Render:
  - Service: `pocket-table-relay`, https://pocket-table-relay.onrender.com (free plan, Frankfurt)
  - Root Directory blank. Build `pip install -r 2-relay-server/requirements.txt`. Start `cd 2-relay-server && uvicorn main:app --host 0.0.0.0 --port $PORT`
  - Env: `PYTHON_VERSION=3.12.7`, `PUBLIC_URL=https://pocket-table-relay.onrender.com`
  - Don't move `2-relay-server/main.py` or `1-player-client/`, and don't rename the `app` object, without updating this setup.
- **Never push a red build.** Before each push, the `test-runner` agent must report no failures in the suites you touched.
- Never upgrade any Render service to a paid plan, never add payment details, and never commit secrets.

## Subagents: use them, don't do their work yourself

| Agent | Model | When to use it |
|---|---|---|
| `test-runner` | Haiku | After every change, and always before a push |
| `client-sync` | Haiku | After any edit in `1-player-client/` |
| `layer-guard` | Haiku | After adding imports, files or packages |
| `deploy-checker` | Haiku | Before pushing relay changes, and after each push (check `/health` and `/`) |
| `protocol-checker` | Sonnet | After adding or changing any message type or payload |
| `prototype-porter` | Sonnet | When a game rule changes. Change the Python prototype first, then have it port to Dart |
| `security-reviewer` | Opus | At the end of each phase, on that phase's diff (`git diff <phase-start>..HEAD`) |

You (the main agent) plan, design and write the feature code. Hand searching, test runs, syncing and checking to the agents. Fix every **high** and **medium** finding from `security-reviewer`, `protocol-checker` and `layer-guard` before moving on. Low findings go in `SESSION_NOTES.md`.

## Phase 0: setup (short)

1. `git pull` and make sure the working tree is clean.
2. Run `test-runner` on everything to get a baseline. Currently the Python prototypes have 13 tests and the relay has 6, all passing. If the Dart SDK is missing, try to install it (Flutter or Dart via the official installer or package manager). If that fails, skip the Dart suites and note it. Then be extra careful with Dart code: keep it simple and type-safe, and mirror the Python prototype tests.
3. Run `deploy-checker`. Then fetch https://pocket-table-relay.onrender.com/health, which should return `{"ok": true, ...}`, and `/`, which should return the player page. The first request may take about 60 seconds while the free service wakes up. If the deploy is broken, fix it first.

## Phase 1: polish the player web page (`1-player-client/`)

The page players open on their phones. It's plain HTML/CSS/JS with no build step.

- **Mobile first:** works at 360px wide, big tap targets (44px or more), no horizontal scroll, readable in portrait, respects the iOS safe areas.
- **Join flow:** room code input (auto-uppercase, 4 characters, pre-filled from `?room=`), name input with validation, and clear messages for every `join.error` reason in the protocol.
- **Connection states:** connecting / connected / reconnecting banner, automatic reconnect with the stored `reconnectToken`, and a clear screen for `room.closed` (host left, kicked, expired) and for host disconnect/reconnect.
- **Game screens:** clean screens for lobby (player list, waiting for host), private info (Mafia role reveal with tap-to-reveal and hide again; poker hole cards), actions (vote or target picker, poker fold/check/call/raise with a bet slider and input limited to legal amounts), and results.
- Keep it driven by the screen messages from the host. **No game rules in the client.** It only renders and sends actions.
- Accessibility: good contrast, `aria-live` for status changes, and no meaning carried by colour alone.
- After the edits: `client-sync`, then `test-runner` (relay tests cover serving the page), then commit and push, then `deploy-checker` to confirm the live page.

## Phase 2: finish Mafia and Poker (`5-games/` + `4-platform-core/`)

Make both games fully playable from start to finish through the platform core.

- **Workflow for every rule:** update the Python prototype (`5-games/prototype/`) and its tests first, then `prototype-porter` ports it to Dart (`5-games/lib/src/...`, tests in `5-games/test/`).
- **Mafia:** role assignment scaled to player count, night actions (mafia kill, doctor save, detective check) with private results, day discussion, then a vote with majority and tie rules, elimination reveals, win conditions for both sides, and handling of players who disconnect mid-game. The host can configure roles and timers.
- **Poker (Texas Hold'em):** blinds and dealer rotation, the full betting rounds, min-raise rules, all-ins with correct **side pots** (`pots.py` / `pots.dart`), the showdown with hand evaluation and split pots, busting out, and the end of the game. Hole cards only via `sendTo`.
- Every player action is validated (turn, phase, legality, amount). Illegal actions get a clear error message back to that player only.
- Add tests for the edge cases: ties, everyone all-in, a player leaving mid-hand, a minimum-size Mafia game.
- Then: `protocol-checker` for any new `game.*` payloads, `layer-guard`, `test-runner`, commit and push, then `security-reviewer` on the phase diff.

## Phase 3: host app screens (`6-host-app-ui/`, Flutter)

- **Mode select:** clear Same Wi-Fi vs Online choice. Online defaults to `https://pocket-table-relay.onrender.com` and shows a "waking server…" state for the cold start.
- **Lobby:** big room code and QR code, join URL, a live player list with kick, a game picker (Mafia / Poker) with each game's settings, and a start button that's only enabled when the player count is valid.
- **Table screen:** a shared "table" view for the host phone, like the poker board, pot and whose turn it is, or the Mafia phase, timer and who's alive. **Never show private info** (roles, hole cards) on the host screen.
- Keep all logic in `host_controller.dart` and the platform core. Screens only read state and call actions.
- If Flutter isn't available, write the code carefully and say clearly in the notes that it's untested.
- Then: `layer-guard`, `test-runner`, commit and push, then `security-reviewer`.

## If you run out of planned work

Fix low-severity findings, improve READMEs where code and docs disagree, and add tests. Don't start big new features, such as a third game, without the owner.

## When you finish (or before stopping for any reason)

Write and commit `SESSION_NOTES.md` at the repo root, then push. Include:
- what you finished in each phase, with commit hashes
- the decisions you made on the owner's behalf, and why
- anything untested (for example Dart/Flutter if the SDK was missing) and how to test it
- open issues and low-severity findings
- how to try it: open https://pocket-table-relay.onrender.com on two phones, plus the host app steps
