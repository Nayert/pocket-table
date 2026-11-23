"""Side pot building and awarding (prototype for pots.dart).

contribs: chips each player put in this hand, e.g. {"a": 100, "b": 50}
folded:   players who folded (their chips count but they can't win)
order:    players in seat order starting left of the dealer; used to give
          odd chips from a split pot to the first winner in that order
"""


def build_pots(contribs: dict[str, int], folded: set[str]) -> list[tuple[int, list[str]]]:
    left = {p: c for p, c in contribs.items() if c > 0}
    pots: list[tuple[int, list[str]]] = []
    while left:
        live = [p for p in left if p not in folded]
        if not live:
            # only folded money left: it belongs in the last pot
            extra = sum(left.values())
            if pots:
                amt, elig = pots[-1]
                pots[-1] = (amt + extra, elig)
            break
        level = min(left[p] for p in live)
        amount = 0
        for p in list(left):
            take = min(left[p], level)
            amount += take
            left[p] -= take
            if left[p] == 0:
                del left[p]
        pots.append((amount, sorted(live)))
    return pots


def award(pots, scores: dict[str, tuple], order: list[str]) -> dict[str, int]:
    """scores: best_hand score for every player still in. Returns chips won."""
    won: dict[str, int] = {}
    for amount, eligible in pots:
        best = max(scores[p] for p in eligible)
        winners = [p for p in order if p in eligible and scores[p] == best]
        share, rem = divmod(amount, len(winners))
        for i, p in enumerate(winners):
            won[p] = won.get(p, 0) + share + (1 if i < rem else 0)
    return won
