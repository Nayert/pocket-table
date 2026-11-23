# Layer 5: Games (plugins)

**Tech:** Dart (prototype in Python first)
**Runs on:** the host phone, inside the host app

## What it does

Each game is one self-contained class implementing the `Game` interface from layer 4. It holds all the rules and state for that game and decides what each player should see.

### Mafia

- Role assignment (random, from the settings' role mix)
- Phase state machine: **night → day → vote → results**, repeat
- Timers per phase
- Win checks (town wins / mafia wins)
- Narrator screen on the host showing phase and prompts

### Poker (Texas Hold'em)

- Secure shuffle (`Random.secure()`), dealing hole and community cards
- Betting rounds, blinds, chips, folding, all-in
- Hand evaluator and side pots
- Play chips only — no real money

## What it needs from other layers

| From | Needs |
|------|-------|
| **4 Platform core** | The `Game` interface; a player list on `start()`; actions passed into `handleAction()` already tied to a real, connected player |
| **Shared protocol** | The generic screens (`screen.private`, `screen.choice`, `screen.input`, `screen.results`) to describe what players see |

That's it. Games never use the transport, the UI or the network directly.

## What it provides to other layers

- To **4 Platform core**: `start`, `handleAction`, `publicState`, `privateState(player)`, `isOver`, plus `minPlayers`/`maxPlayers`
- To **6 Host app UI** (via core's `publicState`): what the table/TV view should show — pot and board for poker, phase and alive players for Mafia

## What it does NOT do

- Doesn't send messages itself — it returns state and the core sends it.
- Doesn't know whether it's Local or Online.

## Key notes

- **Private info only ever goes to its owner.** `privateState(p)` must contain only what player `p` is allowed to know. `publicState()` must never contain roles or hole cards (except at showdown/game end).
- `handleAction` re-checks legality (e.g. a raise is at least the minimum, a dead player can't vote).
- **Test the hand evaluator separately first**, with known hands, before building the betting logic around it.
- Prototype each game in Python as plain functions with no UI or networking, then port to Dart once the rules are right.

## Files

```
5-games/
  pubspec.yaml
  lib/games.dart                    # exports games + allGames list (the registry the lobby reads)
  lib/src/mafia/mafia_game.dart
  lib/src/poker/cards.dart          # deck, secure shuffle, pretty printing
  lib/src/poker/hand_evaluator.dart
  lib/src/poker/pots.dart           # side pots + awarding
  lib/src/poker/poker_game.dart
  test/poker_test.dart              # evaluator, pots, and game flow
  test/mafia_test.dart
  prototype/                        # Python versions of the rules, with tests
    poker_eval.py  pots.py  mafia.py  test_prototypes.py
```

## Running the tests

```bash
cd 5-games/prototype && python -m unittest test_prototypes.py   # Python prototypes
cd 5-games && dart pub get && dart test                         # Dart versions
```

The Dart hand evaluator, pots and Mafia rules are line-by-line ports of the Python prototypes, and the Dart tests use the same cases.

## Adding a game

1. Write `lib/src/<game>/<game>_game.dart` with a class that `extends Game`.
2. Export it from `lib/games.dart` and add `YourGame.new` to `allGames`.
3. Nothing else changes: the lobby picks it up, the player page draws its screens, and the table view draws its `publicState()`.
