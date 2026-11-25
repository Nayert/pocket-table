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

Rules in detail (pinned by `prototype/test_prototypes.py`):

- **Roles:** Mafia = the setting, or automatic (players ÷ 4, at least 1), and always capped so the Mafia start outnumbered. One Doctor and one Detective if enabled and there's room. The minimum game is 4 players: Mafia, Doctor, Detective and Villager.
- **Night:** everyone (villagers too) picks from the same list, every living player including themselves, so a glance at a phone can't reveal a role. The Mafia's most-picked target dies unless the Doctor protected them. Ties are broken at random, and Mafia picks on themselves or a teammate count as no kill. The Detective privately learns whether their pick is Mafia.
- **Vote:** the player with the most votes is out, unless there's a tie for most or "Nobody" leads. With the *majority* setting they also need more than half of the living players' votes.
- **Timers and absence:** each phase has a timer, and missing actions count as no action or abstain. A phase ends early once every living, *connected* player has acted. A player who leaves or is kicked dies (role revealed if the setting is on), which can end the game.
- **Privacy:** roles and night results go only in a `secret` screen's body. Titles, lines and options are the same for every role.

### Poker (chip tracker for Texas Hold'em)

The cards are dealt at a real table. The app only keeps the chips.

- **Buy-in:** everyone starts with the buy-in. The host can change it mid-game (it sets what a rebuy gives); stacks already on the table stay as they are. With *Auto rebuy* on, a player who runs out gets the buy-in again automatically.
- **Dealer:** chosen at random to start, or picked by the host between hands. The button then moves one seat each hand, skipping players with no chips or sitting out. The table shows (D), (SB) and (BB).
- **Blinds** are posted automatically. Heads-up, the dealer posts the small blind and acts first before the flop. The host can change the blinds; it takes effect from the next hand.
- **Betting rounds:** each player bets from their phone (fold, check, call, bet/raise, all in). The table shows the pot, each player's bet this round, who still has to act, and a one-line summary of every finished round of the hand. Min-raise and short all-in rules are enforced.
- **Showdown:** after the river (or when nobody can bet any more) the host taps who won each pot, main pot first, then side pots. Picking several players splits it; odd chips go to the first winner left of the dealer. Uncalled chips go back automatically.
- **Reviving:** a player with no chips sits out until the host uses *Add chips*. The table tracks each player's total bought in and their net result.
- **Host tools:** *Play for* (make the current player's move, e.g. their phone died), *Sit out / back in*, and *Undo* (up to 50 steps).
- **Absence:** offline players are still dealt in (they're at the table); the host can play for them. The optional turn timer checks or folds. A player who leaves or is kicked folds and is never dealt in again.
- **End:** the game never ends by itself; the host presses End.

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
  lib/src/poker/cards.dart          # deck, pretty printing (not used by the chip tracker)
  lib/src/poker/hand_evaluator.dart # (not used by the chip tracker)
  lib/src/poker/pots.dart           # side pots
  lib/src/poker/poker_game.dart     # the chip tracker
  test/poker_test.dart              # evaluator, pots, and chip tracker flow
  test/mafia_test.dart
  prototype/                        # Python versions of the rules, with tests
    poker_eval.py  pots.py  poker.py  mafia.py  test_prototypes.py
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
