"""Run with:  python -m unittest test_prototypes.py   (from this folder)"""
import random
import unittest

from poker_eval import best_hand, evaluate5, describe
from pots import build_pots, award
from mafia import Mafia, assign_roles, MAFIA, DOCTOR, DETECTIVE, NOBODY


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
            g.act(m, m)  # mafia can't target themselves


if __name__ == "__main__":
    unittest.main()
