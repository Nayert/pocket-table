# Layer 6: Host App UI

**Tech:** Dart (Flutter)
**Runs on:** the host phone

## What it does

- **Mode choice:** Local (same Wi-Fi) or Online (via relay)
- **Lobby screen:** QR code / room code, player list as people join, game picker, settings, Start button
- **Table / TV view during the game:** whatever the current game's `publicState()` describes — Mafia narrator view, poker table with pot and community cards
- **Host controls:** pause, end game, kick a player, back to lobby

## What it needs from other layers

| From | Needs |
|------|-------|
| **4 Platform core** | Observable state (lobby players, selected game, current `publicState()`, connection status) and commands (`chooseMode`, `pickGame`, `updateSettings`, `startGame`, `endGame`, `kick`) |
| **3 Transport** (via core) | `joinInfo`: the URL/room code to turn into a QR code |
| **5 Games** (via core) | A host-view widget per game, or a `publicState()` shape the UI knows how to draw |

## What it provides to other layers

- User intent to **4 Platform core** (button presses become core commands)
- Nothing to the network — the UI never touches sockets

## What it does NOT do

- No game rules and no validation — it only displays state and forwards the host's choices.
- If the host is also playing, their private info still goes through their own player client, not this screen (everyone can see the host phone).

## Screens

- **Mode select:** Same Wi-Fi or Online. Online uses `https://pocket-table-relay.onrender.com` unless you change it (the last address is saved). The free relay sleeps when idle, so the app first polls `/health` and shows **"Waking server… Ns"** with a Cancel button. Waking can take up to a minute, and the app gives up after 100 s.
- **Lobby:** the room code in big letters, a QR code, and the join link with a copy button. Players are listed as connected or offline, each with a remove button that asks first. Below that are the game picker (Mafia / Poker), the game's settings, and Start. Start is disabled until the player count is valid, and the reason is shown underneath (`Platform.startProblem`).
- **Table:** draws only `publicState()`, so it can't show roles or hole cards. Whose turn it is gets highlighted with an arrow and the word "turn", not just a colour. There's a big countdown, a "What happened" log, a Players sheet with remove buttons, and an End button that asks first.

All logic lives in `host_controller.dart` and the platform core. Screens only read state and call controller actions.

## Tests

```bash
flutter test        # widget tests with FakeTransport: no network, no device
```

They cover the default relay, the waking state, Start being disabled with too few players, and that the table view shows no hole cards and no role names.

## Key notes

- **Wakelock** to keep the screen on while hosting (via `wakelock_plus`).
- **Local network permission** on iPhone for Local mode.
- Big, readable text on the table view; it's meant to be seen from across a room.
- Option to **cast to a TV** later — keep the table view a separate widget so it can be shown on another display.

## Files

```
6-host-app-ui/
  pubspec.yaml                       # depends on transport, platform_core, games by path
  lib/main.dart                      # picks the screen from the platform's state
  lib/host_controller.dart           # wraps Platform for Flutter, wakelock, saves relay URL
  lib/screens/mode_select_screen.dart
  lib/screens/lobby_screen.dart      # QR, room code, players, game picker, settings
  lib/screens/table_screen.dart      # draws any game's publicState()
  lib/widgets/playing_card.dart
  assets/player_client/              # copy of 1-player-client, served in Local mode
  tool/copy_player_client.sh         # refresh that copy
```

There are no per-game host views yet: `table_screen.dart` draws every game from the standard `publicState()` keys. Add a custom view later if a game needs one.

## First-time setup

The Android/iOS project folders aren't included (Flutter generates them). From this folder:

```bash
flutter create . --project-name host_app --platforms android,ios
flutter pub get
flutter run            # with your phone plugged in
```

`flutter create .` keeps the existing `lib/` and `pubspec.yaml`. Then add these permissions:

- **Android** – `android/app/src/main/AndroidManifest.xml`, inside `<manifest>`:
  ```xml
  <uses-permission android:name="android.permission.INTERNET"/>
  <uses-permission android:name="android.permission.ACCESS_NETWORK_STATE"/>
  ```
  and on the `<application>` tag add `android:usesCleartextTraffic="true"` (Local mode uses plain http on your Wi-Fi; testing Online against a non-https relay needs it too).
- **iOS** – `ios/Runner/Info.plist`:
  ```xml
  <key>NSLocalNetworkUsageDescription</key>
  <string>Players on your Wi-Fi connect to this phone to join the game.</string>
  ```
