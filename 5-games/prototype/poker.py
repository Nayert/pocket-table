"""No-limit Texas Hold'em betting engine (prototype for poker_game.dart).

No UI, no timers, no network. The Dart game adds the turn timer and screens;
here timeout() stands in for "the timer ran out".

Phases: betting -> hand_over -> betting ... -> over
        (or "waiting" between hands when fewer than two players can be dealt in
         because the others are disconnected)

Rules pinned down by test_prototypes.py:
- Blinds: small blind left of the dealer, big blind next. Heads-up the dealer
  posts the small blind and acts first before the flop, last after it.
- A blind that can't cover the amount goes all in; the others only have to
  match what was actually put in.
- Min raise: at least the size of the last full bet or raise (the big blind
  to start each street). Anyone may go all in for less.
- An all-in that is less than a full raise does NOT reopen the betting: players
  who already acted since the last full raise may only call or fold.
- Side pots via pots.build_pots; odd chips go to the first winner left of the
  dealer.
- Disconnected players sit out new hands (no cards, no blinds). In a hand,
  their turn is auto-played (check, else fold) when the timer runs out.
- A player who leaves for good folds and is never dealt in again.
- The game is over when fewer than two players who haven't left have chips.
"""
import random

from poker_eval import best_hand, describe
from pots import award, build_pots

STREETS = ["Pre-flop", "Flop", "Turn", "River"]
RANKS = "23456789TJQKA"
SUITS = "cdhs"


class Seat:
    def __init__(self, pid, chips):
        self.id = pid
        self.chips = chips
        self.hole: list[str] = []
        self.folded = False
        self.all_in = False
        self.acted = False
        self.may_raise = True   # False once they've acted since the last full raise
        self.round_bet = 0      # chips put in on this street
        self.hand_bet = 0       # chips put in this hand (for side pots)
        self.ready = False
        self.connected = True
        self.left = False

    @property
    def live(self):  # still in this hand
        return not self.folded and bool(self.hole)

    @property
    def can_act(self):
        return self.live and not self.all_in

    @property
    def can_play(self):  # can be dealt into the next hand
        return self.chips > 0 and not self.left and self.connected


class Poker:
    def __init__(self, players, chips=1000, big_blind=20, rng=None, dealer=None, deck=None):
        self.rng = rng or random.Random()
        self.seats = [Seat(p, chips) for p in players]
        self.big_blind = big_blind
        self.small_blind = max(1, big_blind // 2)
        self.phase = "betting"
        self.hand = 0
        self.dealer = (dealer if dealer is not None else self.rng.randrange(len(self.seats))) - 1
        self.street = 0
        self.to_act = -1
        self.current_bet = 0
        self.min_raise = 0
        self.board: list[str] = []
        self.deck: list[str] = []
        self.fixed_deck = deck  # tests: cards are dealt from the end of this list
        self.log: list[str] = []
        self.last_result: list[str] = []
        self.winner = None
        self.start_hand()

    # ---------------------------------------------------------------- helpers

    def seat(self, pid) -> Seat:
        for s in self.seats:
            if s.id == pid:
                return s
        raise ValueError("You are not in this game.")

    def _next(self, frm, test):
        n = len(self.seats)
        for i in range(1, n + 1):
            idx = (frm + i) % n
            if test(self.seats[idx]):
                return idx
        return -1

    @property
    def pot(self):
        return sum(s.hand_bet for s in self.seats)

    def _post(self, s, amount):
        amt = min(amount, s.chips)
        s.chips -= amt
        s.round_bet += amt
        s.hand_bet += amt
        if s.chips == 0:
            s.all_in = True

    # ---------------------------------------------------------------- dealing

    def start_hand(self):
        if sum(1 for s in self.seats if s.chips > 0 and not s.left) < 2:
            self.phase = "over"
            self.to_act = -1
            alive = [s for s in self.seats if s.chips > 0 and not s.left]
            self.winner = alive[0].id if alive else None
            self.log.append(f"{self.winner} wins the game!" if self.winner else "Game over.")
            return
        if sum(1 for s in self.seats if s.can_play) < 2:
            self.phase = "waiting"  # someone has to reconnect first
            self.to_act = -1
            return

        self.hand += 1
        self.phase = "betting"
        self.street = 0
        self.board = []
        self.last_result = []
        if self.fixed_deck is not None:
            self.deck = list(self.fixed_deck)
        else:
            self.deck = [r + s for r in RANKS for s in SUITS]
            self.rng.shuffle(self.deck)
        for s in self.seats:
            s.hole, s.folded, s.all_in, s.acted, s.may_raise = [], False, False, False, True
            s.round_bet = s.hand_bet = 0
            s.ready = False
        in_hand = [s for s in self.seats if s.can_play]
        for _ in range(2):
            for s in in_hand:
                s.hole.append(self.deck.pop())

        self.dealer = self._next(self.dealer, lambda s: s.live)
        heads_up = len(in_hand) == 2
        sb = self.dealer if heads_up else self._next(self.dealer, lambda s: s.live)
        bb = self._next(sb, lambda s: s.live)
        self._post(self.seats[sb], self.small_blind)
        self._post(self.seats[bb], self.big_blind)
        self.current_bet = max(self.seats[sb].round_bet, self.seats[bb].round_bet)
        self.min_raise = self.big_blind
        self.log.append(f"Hand {self.hand}: {self.seats[sb].id} posts {self.seats[sb].round_bet}, "
                        f"{self.seats[bb].id} posts {self.seats[bb].round_bet}.")

        actors = [s for s in self.seats if s.can_act]
        if not actors or (len(actors) == 1 and actors[0].round_bet >= self.current_bet):
            return self._next_street()
        self.to_act = self._next(bb, lambda s: s.can_act)

    # ---------------------------------------------------------------- betting

    def legal(self, pid):
        """What this player may do now: to_call, call amount, raise range."""
        s = self.seat(pid)
        to_call = max(0, self.current_bet - s.round_bet)
        max_to = s.round_bet + s.chips
        full_min_to = self.current_bet + self.min_raise
        others_can_act = any(o.can_act for o in self.seats if o is not s)
        can_raise = s.chips > to_call and s.may_raise and others_can_act
        return {
            "to_call": to_call,
            "call": min(to_call, s.chips),
            "can_check": to_call == 0,
            "can_raise": can_raise,
            "min_to": min(full_min_to, max_to),
            "max_to": max_to,
        }

    def act(self, pid, move, amount=None):
        s = self.seat(pid)
        if self.phase != "betting":
            raise ValueError("Wait for the next hand." if self.phase != "over" else "The game is over.")
        if self.to_act < 0 or self.seats[self.to_act] is not s:
            raise ValueError("It's not your turn.")
        o = self.legal(pid)

        if move == "fold":
            s.folded = True
            self.log.append(f"{s.id} folds.")
        elif move == "check":
            if not o["can_check"]:
                raise ValueError("You can't check, there's a bet.")
            self.log.append(f"{s.id} checks.")
        elif move == "call":
            if o["can_check"]:
                raise ValueError("Nothing to call.")
            self._post(s, o["to_call"])
            self.log.append(f"{s.id} calls {o['call']}{' (all in)' if s.all_in else ''}.")
        elif move == "raise":
            if not o["can_raise"]:
                raise ValueError("You can't raise now.")
            if not isinstance(amount, int) or isinstance(amount, bool) or not o["min_to"] <= amount <= o["max_to"]:
                raise ValueError(f"Raise to between {o['min_to']} and {o['max_to']}.")
            to = amount
            raise_by = to - self.current_bet
            self._post(s, to - s.round_bet)
            full = raise_by >= self.min_raise
            if full:
                self.min_raise = raise_by
            for other in self.seats:
                if other is not s:
                    other.acted = False         # everyone has to respond again
                    if full:
                        other.may_raise = True  # a full raise reopens the betting
            self.current_bet = to
            verb = "bets" if raise_by == to else "raises to"
            self.log.append(f"{s.id} {verb} {to}{' (all in)' if s.all_in else ''}.")
        else:
            raise ValueError("Unknown move.")
        s.acted = True
        s.may_raise = False
        self._advance()

    def timeout(self):
        """The timer ran out: auto check/fold, or deal the next hand."""
        if self.phase == "betting" and self.to_act >= 0:
            s = self.seats[self.to_act]
            self.act(s.id, "check" if self.legal(s.id)["can_check"] else "fold")
        elif self.phase == "hand_over":
            self.start_hand()

    def _advance(self):
        live = [s for s in self.seats if s.live]
        if len(live) == 1:
            return self._win_uncontested(live[0])
        actors = [s for s in self.seats if s.can_act]
        done = (not actors
                or all(s.acted and s.round_bet == self.current_bet for s in actors)
                or (len(actors) == 1 and actors[0].round_bet >= self.current_bet))
        if not done:
            self.to_act = self._next(self.to_act, lambda s: s.can_act and (not s.acted or s.round_bet < self.current_bet))
            return
        self._next_street()

    def _next_street(self):
        for s in self.seats:
            s.round_bet = 0
            s.acted = False
            s.may_raise = True
        self.current_bet = 0
        self.min_raise = self.big_blind
        if self.street == 3:
            return self._showdown()
        self.street += 1
        self.deck.pop()  # burn
        for _ in range(3 if self.street == 1 else 1):
            self.board.append(self.deck.pop())
        self.log.append(f"{STREETS[self.street]}: {' '.join(self.board)}")
        if sum(1 for s in self.seats if s.can_act) < 2:
            return self._next_street()  # nobody left to bet against: deal it out
        self.to_act = self._next(self.dealer, lambda s: s.can_act)

    # ---------------------------------------------------------------- results

    def _order_from_dealer(self):
        n = len(self.seats)
        return [self.seats[(self.dealer + i) % n].id for i in range(1, n + 1)]

    def _showdown(self):
        live = [s for s in self.seats if s.live]
        scores = {s.id: best_hand(s.hole + self.board) for s in live}
        pots = build_pots({s.id: s.hand_bet for s in self.seats}, {s.id for s in self.seats if not s.live})
        won = award(pots, scores, self._order_from_dealer())
        self.last_result = [f"{s.id}: {' '.join(s.hole)} ({describe(scores[s.id])})" for s in live]
        for pid, amount in won.items():
            self.seat(pid).chips += amount
            line = f"{pid} wins {amount} with {describe(scores[pid])}"
            self.last_result.append(line)
            self.log.append(line + ".")
        self._end_hand()

    def _win_uncontested(self, winner):
        pot = self.pot
        winner.chips += pot
        self.last_result = [f"{winner.id} wins {pot} (everyone else folded)"]
        self.log.append(f"{winner.id} wins {pot}.")
        self._end_hand()

    def _end_hand(self):
        for s in self.seats:
            s.hand_bet = s.round_bet = 0
            if s.hole and s.chips == 0 and not s.left:
                self.log.append(f"{s.id} is out of chips.")
        self.to_act = -1
        if sum(1 for s in self.seats if s.chips > 0 and not s.left) < 2:
            return self.start_hand()  # sets the game over
        self.phase = "hand_over"

    # ---------------------------------------------------------------- between hands

    def ready(self, pid):
        s = self.seat(pid)
        if self.phase != "hand_over":
            raise ValueError("Wait for the next hand.")
        if not s.can_play:
            raise ValueError("You're out of chips.")
        s.ready = True
        if all(x.ready for x in self.seats if x.can_play):
            self.start_hand()

    def set_connected(self, pid, connected):
        s = self.seat(pid)
        s.connected = connected
        if connected and self.phase == "waiting":
            self.start_hand()
        elif not connected and self.phase == "hand_over" and all(x.ready for x in self.seats if x.can_play):
            self.start_hand()

    def remove_player(self, pid):
        """Left for good (kicked or pressed Leave): fold now, never dealt in again."""
        s = self.seat(pid)
        if s.left:
            return
        s.left = True
        s.connected = False
        self.log.append(f"{pid} left the game.")
        if self.phase == "betting" and s.live:
            if self.seats[self.to_act] is s:
                return self.act(pid, "fold")
            s.folded = True
            live = [x for x in self.seats if x.live]
            if len(live) == 1:
                return self._win_uncontested(live[0])
            actors = [x for x in self.seats if x.can_act]
            if (not actors or all(x.acted and x.round_bet == self.current_bet for x in actors)
                    or (len(actors) == 1 and actors[0].round_bet >= self.current_bet)):
                return self._next_street()
        elif self.phase in ("hand_over", "waiting"):
            if sum(1 for x in self.seats if x.chips > 0 and not x.left) < 2:
                self.start_hand()  # game over
            elif self.phase == "hand_over" and all(x.ready for x in self.seats if x.can_play):
                self.start_hand()
