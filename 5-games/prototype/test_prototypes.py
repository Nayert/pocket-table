"""Run with:  python -m unittest test_prototypes.py   (from this folder)"""
import random
import unittest

from poker_eval import best_hand, evaluate5, describe
from pots import build_pots, award
from mafia import Mafia, assign_roles, MAFIA, DOCTOR, DETECTIVE, VILLAGER, NOBODY
from poker import Poker


def h(s):
    return s.split()


class HandEvaluator(unittest.TestCase):
    def test_categories(self):
        cases = [
            ("As Ks Qs Js Ts", "Straight flush"),
            ("9c 9d 9h 9s 2c", "Four of a kind"),
            ("3c 3d 3h 7s 7c", "Full house"),
            ("2h 7h 9h Jh Kh", "Flush"),
            ("5c 6d 7h 8s 9c", "Straight"),
            ("Ac 2d 3h 4s 5c", "Straight"),
            ("Qc Qd Qh 7s 2c", "Three of a kind"),
            ("Jc Jd 4h 4s Ac", "Two pair"),
            ("Tc Td 4h 8s Ac", "Pair"),
            ("2c 5d 9h Js Kc", "High card"),
        ]
        for cards, name in cases:
            self.assertEqual(describe(evaluate5(h(cards))), name, cards)

    def test_ordering(self):
        better = [
            ("As Ks Qs Js Ts", "9s 8s 7s 6s 5s"),   # higher straight flush
            ("2c 3c 4c 5c 6c", "Ac 2d 3h 4s 5c"),   # SF beats wheel straight
            ("6c 7d 8h 9s Tc", "Ac 2d 3h 4s 5c"),   # wheel is the lowest straight
            ("Kc Kd 2h 2s 3c", "Qc Qd Jh Js Ac"),   # two pair: top pair first
            ("Ac Ad 9h 5s 3c", "Ac Ad 9h 5s 2c"),   # kicker decides
            ("3c 3d 3h 2s 2c", "2c 2d 2h As Ac"),   # full house: trips first
        ]
        for a, b in better:
            self.assertGreater(evaluate5(h(a)), evaluate5(h(b)), f"{a} vs {b}")

    def test_split(self):
        board = h("As Ks Qd Jc Th")
        self.assertEqual(best_hand(board + h("2c 3d")), best_hand(board + h("4h 5h")))

    def test_best_of_seven(self):
        self.assertEqual(describe(best_hand(h("Ah Kh 2h 7h 9c 9d 3h"))), "Flush")
        self.assertEqual(describe(best_hand(h("9c 9d 9h 4s 4c 4d 2c"))), "Full house")


class Pots(unittest.TestCase):
    def test_single_pot(self):
        self.assertEqual(build_pots({"a": 50, "b": 50, "c": 50}, set()),
                         [(150, ["a", "b", "c"])])

    def test_side_pot_and_folded(self):
        pots = build_pots({"a": 20, "b": 100, "c": 100, "d": 30}, folded={"d"})
        self.assertEqual(pots, [(80, ["a", "b", "c"]), (170, ["b", "c"])])
        self.assertEqual(sum(a for a, _ in pots), 250)

    def test_award_with_split_and_odd_chip(self):
        pots = [(101, ["a", "b"])]
        won = award(pots, {"a": (5, 1), "b": (5, 1)}, order=["b", "a"])
        self.assertEqual(won, {"b": 51, "a": 50})

    def test_short_stack_wins_main_only(self):
        pots = build_pots({"a": 20, "b": 100, "c": 100}, set())
        won = award(pots, {"a": (9,), "b": (5,), "c": (1,)}, order=["a", "b", "c"])
        self.assertEqual(won, {"a": 60, "b": 160})


class MafiaRules(unittest.TestCase):
    def test_role_counts(self):
        r = assign_roles([f"p{i}" for i in range(8)], rng=random.Random(1))
        roles = list(r.values())
        self.assertEqual(roles.count(MAFIA), 2)
        self.assertEqual(roles.count(DOCTOR), 1)
        self.assertEqual(roles.count(DETECTIVE), 1)
        small = list(assign_roles(["a", "b", "c", "d"], rng=random.Random(1)).values())
        self.assertEqual(small.count(MAFIA), 1)
        self.assertLessEqual(len([x for x in small if x != "villager"]), 3)

    def setup_game(self):
        g = Mafia([f"p{i}" for i in range(6)], rng=random.Random(3))
        by_role = {}
        for p, r in g.roles.items():
            by_role.setdefault(r, []).append(p)
        for p in g.players:
            g.act(p, "ready")
        self.assertEqual(g.phase, "night")
        return g, by_role

    def night(self, g, mafia_target, save):
        for p in sorted(g.alive):
            role = g.roles[p]
            if role == MAFIA:
                g.act(p, mafia_target)
            elif role == DOCTOR:
                g.act(p, save)
            elif p in g.alive and g.phase == "night":
                g.act(p, g.options(p)[0])

    def test_doctor_save_and_kill(self):
        g, roles = self.setup_game()
        victim = roles["villager"][0]
        self.night(g, victim, save=victim)
        self.assertEqual(g.phase, "dawn")
        self.assertIn(victim, g.alive)
        self.assertIn(roles[DETECTIVE][0], g.detective_results)
        for p in sorted(g.alive):
            g.act(p, "ready")  # dawn -> day
        for p in sorted(g.alive):
            g.act(p, "ready")  # day -> vote
        self.assertEqual(g.phase, "vote")
        for p in sorted(g.alive):
            g.act(p, NOBODY)
        self.assertEqual(g.phase, "verdict")
        self.assertEqual(len(g.alive), 6)

    def test_town_wins_by_voting_out_mafia(self):
        g, roles = self.setup_game()
        g.timeout()                      # night with no actions: nobody dies
        g.timeout(); g.timeout()         # dawn, day
        mafia = roles[MAFIA][0]
        for p in sorted(g.alive):
            g.act(p, mafia if p != mafia else NOBODY)
        self.assertEqual(g.phase, "over")
        self.assertEqual(g.winner, "town")

    def test_mafia_wins_on_parity(self):
        g = Mafia(["a", "b", "c", "d"], rng=random.Random(5), doctor=False, detective=False)
        m = next(p for p, r in g.roles.items() if r == MAFIA)
        g.timeout()  # reveal
        town = [p for p in g.players if p != m]
        g.act(m, town[0]); g.timeout()            # kill one: 1 mafia vs 2 town
        self.assertEqual(g.phase, "dawn")
        g.timeout(); g.timeout()
        for p in sorted(g.alive):                 # town votes out one of their own
            g.act(p, town[1] if p != town[1] else m)
        self.assertEqual(g.winner, "mafia")

    def test_illegal_action_rejected(self):
        g, roles = self.setup_game()
        m = roles[MAFIA][0]
        with self.assertRaises(ValueError):
            g.act(m, NOBODY)  # "nobody" is only a day-vote option
        with self.assertRaises(ValueError):
            g.act(m, "zz")    # not a player
        g.act(m, roles[VILLAGER][0])
        with self.assertRaises(ValueError):
            g.act(m, roles[VILLAGER][0])  # can't act twice

    def test_night_options_identical_for_every_role(self):
        g, roles = self.setup_game()
        lists = {r: g.options(ps[0]) for r, ps in roles.items()}
        self.assertEqual(len({tuple(v) for v in lists.values()}), 1)
        self.assertEqual(sorted(lists[MAFIA]), sorted(g.alive))

    def test_mafia_picking_self_or_teammate_kills_nobody(self):
        g = Mafia([f"p{i}" for i in range(8)], rng=random.Random(4), doctor=False, detective=False)
        mafia = [p for p in g.players if g.roles[p] == MAFIA]
        self.assertEqual(len(mafia), 2)
        g.timeout()  # reveal
        g.act(mafia[0], mafia[0]); g.act(mafia[1], mafia[0])
        g.timeout()
        self.assertEqual(len(g.alive), 8)
        self.assertIn("nobody died", g.log[-1])

    def test_pick_on_player_who_left_does_not_split_the_kill(self):
        g = Mafia([f"p{i}" for i in range(8)], rng=random.Random(4), doctor=False, detective=False)
        m1, m2 = [p for p in g.players if g.roles[p] == MAFIA]
        town = [p for p in g.players if g.roles[p] != MAFIA]
        g.timeout()  # reveal
        g.act(m1, town[0]); g.act(m2, town[1])
        g.remove_player(town[0])        # m1's target left: only m2's pick counts
        g.timeout()
        self.assertNotIn(town[1], g.alive)

    def test_target_who_left_is_not_reported_killed(self):
        g, roles = self.setup_game()
        victim = roles[VILLAGER][0]
        for m in roles[MAFIA]:
            g.act(m, victim)
        g.remove_player(victim)
        g.timeout()
        self.assertIn("nobody died", [l for l in g.log if l.startswith("Night")][-1])


    def test_mafia_count_is_capped(self):
        roles = list(assign_roles(["a", "b", "c", "d", "e"], mafia_count=4, rng=random.Random(1)).values())
        self.assertEqual(roles.count(MAFIA), 2)  # mafia must start outnumbered

    def test_minimum_game_four_players(self):
        g = Mafia(["a", "b", "c", "d"], rng=random.Random(2))
        roles = sorted(g.roles.values())
        self.assertEqual(roles, sorted([MAFIA, DOCTOR, DETECTIVE, VILLAGER]))
        m = next(p for p, r in g.roles.items() if r == MAFIA)
        doc = next(p for p, r in g.roles.items() if r == DOCTOR)
        det = next(p for p, r in g.roles.items() if r == DETECTIVE)
        vil = next(p for p, r in g.roles.items() if r == VILLAGER)
        for p in g.players:
            g.act(p, "ready")
        g.act(m, vil); g.act(doc, doc); g.act(det, m); g.act(vil, m)
        self.assertEqual(g.phase, "dawn")
        self.assertNotIn(vil, g.alive)
        self.assertEqual(g.detective_results[det], f"{m} is Mafia")
        for _ in range(2):
            for p in sorted(g.alive):
                g.act(p, "ready")
        for p in sorted(g.alive):
            g.act(p, m if p != m else doc)
        self.assertEqual((g.phase, g.winner), ("over", "town"))

    def test_vote_tie_means_nobody_out(self):
        g = Mafia(["a", "b", "c", "d"], rng=random.Random(5), doctor=False, detective=False)
        g.phase = "vote"
        g.act("a", "b"); g.act("b", "a"); g.act("c", "a"); g.act("d", "b")
        self.assertEqual(len(g.alive), 4)
        self.assertIn("no one was voted out", g.log[-1])

    def test_majority_rule(self):
        g = Mafia([f"p{i}" for i in range(6)], rng=random.Random(5), majority_vote=True)
        g.phase = "vote"
        town = [p for p in g.players if g.roles[p] != MAFIA]
        target = town[0]
        v = [p for p in g.players if p != target]
        votes = {v[0]: target, v[1]: target, target: v[0], v[2]: v[3], v[3]: v[4], v[4]: NOBODY}
        for p in g.players:  # target has 2 of 6 votes: the most, but not a majority
            g.act(p, votes[p])
        self.assertEqual(len(g.alive), 6)
        self.assertIn("majority", g.log[-1])

    def test_phase_ends_without_disconnected_players(self):
        g = Mafia(["a", "b", "c", "d"], rng=random.Random(1))
        g.set_connected("d", False)
        for p in "abc":
            g.act(p, "ready")
        self.assertEqual(g.phase, "night")  # didn't wait for d

    def test_leaving_kills_and_can_end_the_game(self):
        g = Mafia(["a", "b", "c", "d"], rng=random.Random(1), doctor=False, detective=False)
        m = next(p for p, r in g.roles.items() if r == MAFIA)
        g.remove_player(m)
        self.assertEqual((g.phase, g.winner), ("over", "town"))


def stacked_deck(holes, board):
    """Deck that deals these hole cards (seat order) and this board."""
    deal = [h[0] for h in holes] + [h[1] for h in holes]
    deal += ["Xx", *board[:3], "Xx", board[3], "Xx", board[4]]
    return list(reversed(deal))


class PokerBetting(unittest.TestCase):
    def total(self, g):
        return sum(s.chips for s in g.seats) + g.pot

    def test_heads_up_blinds_and_order(self):
        g = Poker(["a", "b"], chips=1000, big_blind=20, dealer=0)
        a, b = g.seats
        self.assertEqual((a.round_bet, b.round_bet), (10, 20))  # dealer posts the small blind
        self.assertEqual(g.seats[g.to_act].id, "a")             # and acts first pre-flop
        g.act("a", "call")
        self.assertEqual(g.seats[g.to_act].id, "b")             # big blind gets the option
        self.assertTrue(g.legal("b")["can_raise"])
        g.act("b", "check")
        self.assertEqual(g.street, 1)
        self.assertEqual(g.seats[g.to_act].id, "b")             # big blind acts first after the flop

    def test_three_handed_blinds_rotate(self):
        g = Poker(["a", "b", "c"], dealer=0)
        self.assertEqual([s.round_bet for s in g.seats], [0, 10, 20])
        self.assertEqual(g.seats[g.to_act].id, "a")
        g.act("a", "fold"); g.act("b", "fold")
        self.assertEqual(g.phase, "hand_over")
        for p in "abc":
            g.ready(p)
        self.assertEqual(g.dealer, 1)
        self.assertEqual([s.round_bet for s in g.seats], [20, 0, 10])

    def test_min_raise(self):
        g = Poker(["a", "b", "c"], dealer=0)
        self.assertEqual(g.legal("a")["min_to"], 40)
        with self.assertRaises(ValueError):
            g.act("a", "raise", 30)
        g.act("a", "raise", 60)               # raise by 40
        self.assertEqual(g.legal("b")["min_to"], 100)  # next raise must be 40 more
        with self.assertRaises(ValueError):
            g.act("b", "raise", 99)
        g.act("b", "raise", 100)

    def test_illegal_moves(self):
        g = Poker(["a", "b", "c"], dealer=0)
        with self.assertRaises(ValueError):
            g.act("b", "call")                # not b's turn
        with self.assertRaises(ValueError):
            g.act("a", "check")               # facing the big blind
        with self.assertRaises(ValueError):
            g.act("a", "raise", 40.5)         # not a whole number
        with self.assertRaises(ValueError):
            g.act("a", "raise", 5000)         # more than they have
        with self.assertRaises(ValueError):
            g.act("zz", "fold")               # not in the game

    def test_short_all_in_does_not_reopen_betting(self):
        g = Poker(["a", "b", "c"], chips=1000, dealer=0)
        g.seats[2].chips = 150                # c (big blind) has 150 behind
        g.act("a", "call"); g.act("b", "call"); g.act("c", "check")   # flop, b acts first
        self.assertEqual(g.street, 1)
        g.act("b", "raise", 100)              # b bets 100
        g.act("c", "raise", 150)              # c all in for 150: only 50 more, not a full raise
        g.act("a", "call")                    # a hadn't acted: a could have raised
        self.assertEqual(g.seats[g.to_act].id, "b")
        self.assertFalse(g.legal("b")["can_raise"])  # b already acted: call or fold only
        with self.assertRaises(ValueError):
            g.act("b", "raise", 400)
        g.act("b", "call")
        self.assertEqual(g.street, 2)

    def test_full_raise_reopens_betting(self):
        g = Poker(["a", "b", "c"], chips=1000, dealer=0)
        g.act("a", "call"); g.act("b", "call"); g.act("c", "check")
        g.act("b", "raise", 100)
        g.act("c", "raise", 200)              # full raise
        g.act("a", "fold")
        self.assertTrue(g.legal("b")["can_raise"])

    def test_everyone_all_in_runs_the_board_with_side_pots(self):
        holes = [["As", "Ad"], ["Ks", "Kd"], ["Qs", "Qd"]]
        board = ["2c", "7h", "9d", "3s", "4h"]
        # c deals, a posts the small blind, b the big blind; stacks 100 / 300 / 600
        g = Poker(["a", "b", "c"], chips=1000, dealer=2, deck=stacked_deck(holes, board))
        for s, c in zip(g.seats, (100, 300, 600)):
            s.chips = c - s.round_bet
        start = 1000
        g.act("c", "raise", 600)
        g.act("a", "call")
        g.act("b", "call")
        self.assertEqual(g.phase, "hand_over")
        self.assertEqual(len(g.board), 5)
        a, b, c = g.seats
        self.assertEqual(a.chips, 300)        # main pot 3 x 100
        self.assertEqual(b.chips, 400)        # side pot 2 x 200
        self.assertEqual(c.chips, 300)        # uncalled 300 comes back
        self.assertEqual(a.chips + b.chips + c.chips, start)

    def test_split_pot(self):
        holes = [["2c", "3d"], ["2d", "3c"]]
        board = ["As", "Ks", "Qd", "Jc", "Th"]  # board plays
        g = Poker(["a", "b"], chips=500, dealer=0, deck=stacked_deck(holes, board))
        g.act("a", "raise", 500)
        g.act("b", "call")
        self.assertEqual([s.chips for s in g.seats], [500, 500])
        self.assertEqual(g.phase, "hand_over")

    def test_odd_chip_goes_left_of_dealer(self):
        holes = [["2c", "3d"], ["2d", "3c"], ["4c", "5c"]]
        board = ["As", "Ks", "Qd", "Jc", "Th"]
        g = Poker(["a", "b", "c"], chips=1000, big_blind=20, dealer=0, deck=stacked_deck(holes, board))
        g.act("a", "call")
        g.act("b", "fold")                    # b's small blind (10) stays in: pot 50
        g.act("c", "check")
        for _ in range(3):
            g.act("c", "check"); g.act("a", "check")
        # pot 50 split between c and a; odd chip to the first winner left of dealer (b folded -> c)
        self.assertEqual(g.seats[2].chips, 1005)
        self.assertEqual(g.seats[0].chips, 1005)
        self.assertEqual(g.seats[1].chips, 990)

    def test_bust_out_and_game_over(self):
        holes = [["As", "Ad"], ["7c", "2d"]]
        board = ["Ac", "Kd", "9h", "5s", "3c"]
        g = Poker(["a", "b"], chips=500, dealer=0, deck=stacked_deck(holes, board))
        g.act("a", "raise", 500)
        g.act("b", "call")
        self.assertEqual(g.phase, "over")
        self.assertEqual(g.winner, "a")
        self.assertEqual(g.seats[0].chips, 1000)
        with self.assertRaises(ValueError):
            g.act("a", "check")

    def test_player_leaving_mid_hand(self):
        g = Poker(["a", "b", "c"], dealer=0)
        total = self.total(g)
        g.remove_player("b")                  # b (small blind) leaves out of turn
        self.assertTrue(g.seats[1].folded)
        g.act("a", "fold")                    # only c left: wins uncontested
        self.assertEqual(g.phase, "hand_over")
        self.assertEqual(self.total(g), total)
        g.ready("a"); g.ready("c")
        self.assertEqual(g.phase, "betting")
        self.assertEqual(g.seats[1].hole, [])  # never dealt in again

    def test_leaving_on_your_turn_folds(self):
        g = Poker(["a", "b"], dealer=0)
        g.remove_player("a")
        self.assertEqual(g.phase, "over")     # only b has chips and hasn't left
        self.assertEqual(g.winner, "b")

    def test_disconnected_players_sit_out(self):
        g = Poker(["a", "b", "c"], dealer=0)
        g.act("a", "fold"); g.act("b", "fold")
        g.set_connected("b", False)
        g.ready("a"); g.ready("c")
        self.assertEqual(g.seats[1].hole, [])
        self.assertEqual(sum(1 for s in g.seats if s.hole), 2)
        g.act(g.seats[g.to_act].id, "fold")
        g.set_connected("c", False)
        g.ready("a")
        self.assertEqual(g.phase, "waiting")  # only a is here
        g.set_connected("b", True)
        self.assertEqual(g.phase, "betting")

    def test_timeout_checks_or_folds(self):
        g = Poker(["a", "b", "c"], dealer=0)
        g.timeout()                           # a faces the big blind: fold
        self.assertTrue(g.seats[0].folded)
        g.act("b", "call")
        g.timeout()                           # c can check
        self.assertFalse(g.seats[2].folded)
        self.assertEqual(g.street, 1)

    def test_random_games_conserve_chips(self):
        for seed in range(40):
            rng = random.Random(seed)
            g = Poker(["a", "b", "c", "d"], chips=200, big_blind=20, rng=rng)
            for _ in range(2000):
                if g.phase == "over":
                    break
                if g.phase == "hand_over":
                    g.timeout()
                    continue
                pid = g.seats[g.to_act].id
                o = g.legal(pid)
                moves = ["fold", "check" if o["can_check"] else "call"] + (["raise"] if o["can_raise"] else [])
                m = rng.choice(moves)
                g.act(pid, m, rng.randint(o["min_to"], o["max_to"]) if m == "raise" else None)
                self.assertEqual(self.total(g), 800, f"seed {seed}")
            self.assertTrue(all(s.chips >= 0 for s in g.seats))


if __name__ == "__main__":
    unittest.main()
