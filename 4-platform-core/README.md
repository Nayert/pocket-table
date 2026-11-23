# Layer 4: Platform Core

**Tech:** Dart
**Runs on:** the host phone, inside the host app

## What it does

- **Lobby:** player list, host name, ready state
- **Sessions:** maps transport connection ids ↔ players; issues reconnect tokens; puts a returning player back in their seat
- **Game picker and settings:** which game, its options (timers, starting chips, roles)
- **Runs the game:** start/end, routes player actions to the active game, sends each player the right screen
- **Validation:** checks every action before the game sees it — is this player in the game, is it their turn, is this a valid option on their current screen

## The standard game interface

Every game in layer 5 implements this. The core only ever talks to games through it.

```dart
abstract class Game {
  String get id;                     // "mafia", "poker"
  String get displayName;
  String get description;
  int get minPlayers;
  int get maxPlayers;
  List<GameSetting> get settings;    // shown in the lobby

  void start(GameContext ctx, List<Player> players, Map<String, Object> settings);
  ActionResult handleAction(String playerId, PlayerAction action);
  Map<String, dynamic> publicState();   // for the host's table/TV view
  Screen privateState(String playerId); // what this one player should see now
  bool get isOver;
  void onPlayerConnectionChanged(String playerId, bool connected) {}
  void onPlayerRemoved(String playerId) {}   // kicked, or pressed Leave mid-game
  void dispose() {}
}
```

`GameContext` gives the game `requestUpdate()` (call it when a timer changes the state) and a secure `random`.

## What it needs from other layers

| From | Needs |
|------|-------|
| **3 Transport** | `sendTo`, `broadcast`, `onMessage`, `onJoin`, `onLeave`, `joinInfo` |
| **5 Games** | Classes implementing `Game`; legal-move checks inside `handleAction` |
| **Shared protocol** | `join`, `action`, all `screen.*` and `lobby.*` messages, version number |
| **6 Host app UI** | Calls to choose mode, pick a game, change settings, start, end, kick |

## What it provides to other layers

- To **6 Host app UI**: observable state (lobby, current game's `publicState()`, join info) and commands (`startGame`, `endGame`, `kick`…)
- To **5 Games**: a player list and a call into `handleAction` with already-authenticated actions
- To **1 Player client** (through transport): `join.ok`/`join.error` and the screen each player should see

## What it does NOT do

- No rules for any specific game — those live in layer 5.
- No socket code — that's layer 3.
- No widgets — that's layer 6.

## Key notes

- **Never trust the client.** Reject actions from unknown players, out-of-turn actions, and option ids that weren't on that player's screen. Numbers must be whole, in range, and on the option's `step` (the maximum, e.g. all in, is always allowed).
- **Leaving:** a dropped connection keeps the seat (`onPlayerConnectionChanged(false)`), so a refresh or lock screen can come back. Pressing **Leave** or being **kicked** mid-game removes the seat for good and calls `onPlayerRemoved`.
- **Names:** control characters and invisible formatting characters (zero-width, direction overrides) are stripped, then 1–16 characters, unique ignoring case.
- **Secrets:** games can mark a `Screen` with `secret: true`; the page hides its `body` and `cards` behind tap-to-reveal. `title` and `lines` stay visible, so they must never carry private information.
- **Adding a game means writing a new class, not changing the core.** Keep a registry (`List<Game Function()>`) the picker reads from.
- After every accepted action: send each player their `privateState`, update the host view with `publicState`.
- On reconnect, immediately resend that player's current screen.
- Check `v` on `join`; reply `version_mismatch` if it doesn't match.

## Files

```
4-platform-core/
  pubspec.yaml
  lib/platform_core.dart       # exports everything below
  lib/src/game.dart            # Game interface, GameContext, GameSetting, PlayerAction, ActionResult
  lib/src/screen.dart          # Screen + Option: the generic screens games return
  lib/src/player.dart          # Player seat + reconnect token
  lib/src/platform.dart        # lobby, sessions, join rules, action validation, sending screens
  test/platform_test.dart      # uses FakeTransport and a tiny test game
```

## Running the tests

```bash
cd 4-platform-core
dart pub get
dart test
```
