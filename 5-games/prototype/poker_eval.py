"""Poker hand evaluator (prototype for hand_evaluator.dart).

Cards are 2-character strings: rank + suit, e.g. "As", "Td", "9h".
Ranks: 23456789TJQKA   Suits: c d h s

evaluate5() returns a tuple that compares correctly with > and ==:
(category, tiebreak1, tiebreak2, ...)
"""
from itertools import combinations

RANKS = "23456789TJQKA"
SUITS = "cdhs"

CATEGORY_NAMES = [
    "High card", "Pair", "Two pair", "Three of a kind", "Straight",
    "Flush", "Full house", "Four of a kind", "Straight flush",
]


def rank_value(card: str) -> int:
    return RANKS.index(card[0]) + 2  # 2..14


def straight_high(values: list[int]) -> int:
    """Highest card of a straight in these 5 distinct values, or 0 if none."""
    v = sorted(set(values), reverse=True)
    if len(v) != 5:
        return 0
    if v[0] - v[4] == 4:
        return v[0]
    if v == [14, 5, 4, 3, 2]:  # wheel: A-2-3-4-5
        return 5
    return 0


def evaluate5(cards: list[str]) -> tuple:
    assert len(cards) == 5
    values = [rank_value(c) for c in cards]
    flush = len({c[1] for c in cards}) == 1
    high = straight_high(values)

    counts: dict[int, int] = {}
    for v in values:
        counts[v] = counts.get(v, 0) + 1
    # groups sorted by count then rank, both descending
    groups = sorted(counts.items(), key=lambda kv: (kv[1], kv[0]), reverse=True)
    shape = [c for _, c in groups]
    ordered = [r for r, _ in groups]

    if flush and high:
        return (8, high)
    if shape == [4, 1]:
        return (7, *ordered)
    if shape == [3, 2]:
        return (6, *ordered)
    if flush:
        return (5, *sorted(values, reverse=True))
    if high:
        return (4, high)
    if shape == [3, 1, 1]:
        return (3, *ordered)
    if shape == [2, 2, 1]:
        return (2, *ordered)
    if shape == [2, 1, 1, 1]:
        return (1, *ordered)
    return (0, *sorted(values, reverse=True))


def best_hand(cards: list[str]) -> tuple:
    """Best 5-card score from 5-7 cards."""
    return max(evaluate5(list(c)) for c in combinations(cards, 5))


def describe(score: tuple) -> str:
    return CATEGORY_NAMES[score[0]]
