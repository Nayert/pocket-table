"""Mafia rules (prototype for mafia_game.dart). No UI, no timers, no network.

Phases loop: reveal -> night -> dawn -> day -> vote -> verdict -> night ...
Any phase ends early once every living player has acted; otherwise the
host's timer calls timeout(), which fills in defaults (no action / abstain).
"""
import random

MAFIA, DOCTOR, DETECTIVE, VILLAGER = "mafia", "doctor", "detective", "villager"
NOBODY = "nobody"


def assign_roles(players, mafia_count=0, doctor=True, detective=True, rng=random):
    n = len(players)
    k = mafia_count or max(1, n // 4)
    specials = ([DOCTOR] if doctor else []) + ([DETECTIVE] if detective else [])
    while specials and k + len(specials) > n - 1:
        specials.pop()  # drop detective first, then doctor
    roles = [MAFIA] * k + specials
    roles += [VILLAGER] * (n - len(roles))
    rng.shuffle(roles)
    return dict(zip(players, roles))


class Mafia:
    def __init__(self, players, rng=None, reveal_roles=True, **role_opts):
        self.rng = rng or random.Random()
        self.players = list(players)
        self.roles = assign_roles(self.players, rng=self.rng, **role_opts)
        self.alive = set(self.players)
        self.reveal_roles = reveal_roles
        self.round = 1
        self.phase = "reveal"
        self.acted: dict[str, str] = {}
        self.log: list[str] = []
        self.detective_results: dict[str, str] = {}  # detective -> text
        self.winner = None

    # ---- what each player may choose right now ----
    def options(self, pid):
        if pid not in self.alive or pid in self.acted or self.phase == "over":
            return []
        if self.phase in ("reveal", "dawn", "day", "verdict"):
            return ["ready"]
        others = [p for p in self.players if p in self.alive and p != pid]
        if self.phase == "night":
            role = self.roles[pid]
            if role == MAFIA:
                return [p for p in others if self.roles[p] != MAFIA]
            if role == DOCTOR:
                return [p for p in self.players if p in self.alive]
            return others  # detective checks; villagers pick a decoy "suspect"
        if self.phase == "vote":
            return others + [NOBODY]
        return []

    def act(self, pid, choice):
        if choice not in self.options(pid):
            raise ValueError(f"{pid} can't choose {choice} in {self.phase}")
        self.acted[pid] = choice
        if all(p in self.acted for p in self.alive):
            self._end_phase()

    def timeout(self):
        if self.phase != "over":
            self._end_phase()

    # ---- phase transitions ----
    def _end_phase(self):
        acted, self.acted = self.acted, {}
        if self.phase == "reveal":
            self.phase = "night"
        elif self.phase == "night":
            self._resolve_night(acted)
            self.phase = "over" if self._check_win() else "dawn"
        elif self.phase == "dawn":
            self.detective_results = {}
            self.phase = "day"
        elif self.phase == "day":
            self.phase = "vote"
        elif self.phase == "vote":
            self._resolve_vote(acted)
            self.phase = "over" if self._check_win() else "verdict"
        elif self.phase == "verdict":
            self.round += 1
            self.phase = "night"

    def _plurality(self, votes):
        """Most-voted choice; ties broken at random."""
        if not votes:
            return None
        tally: dict[str, int] = {}
        for v in votes:
            tally[v] = tally.get(v, 0) + 1
        top = max(tally.values())
        return self.rng.choice(sorted(c for c, n in tally.items() if n == top))

    def _resolve_night(self, acted):
        target = self._plurality([c for p, c in acted.items() if self.roles[p] == MAFIA])
        saved = {c for p, c in acted.items() if self.roles[p] == DOCTOR}
        for p, c in acted.items():
            if self.roles[p] == DETECTIVE:
                is_mafia = self.roles[c] == MAFIA
                self.detective_results[p] = f"{c} is {'' if is_mafia else 'NOT '}Mafia"
        if target and target not in saved:
            self.alive.discard(target)
            self.log.append(f"Night {self.round}: {target} was killed.")
        else:
            self.log.append(f"Night {self.round}: nobody died.")

    def _resolve_vote(self, acted):
        tally: dict[str, int] = {}
        for c in acted.values():
            tally[c] = tally.get(c, 0) + 1
        if not tally:
            self.log.append(f"Day {self.round}: nobody voted.")
            return
        top = max(tally.values())
        leaders = [c for c, n in tally.items() if n == top]
        if len(leaders) > 1 or leaders[0] == NOBODY:
            self.log.append(f"Day {self.round}: no one was voted out.")
            return
        out = leaders[0]
        self.alive.discard(out)
        extra = f" They were {self.roles[out]}." if self.reveal_roles else ""
        self.log.append(f"Day {self.round}: {out} was voted out.{extra}")

    def _check_win(self):
        mafia = sum(1 for p in self.alive if self.roles[p] == MAFIA)
        town = len(self.alive) - mafia
        if mafia == 0:
            self.winner = "town"
        elif mafia >= town:
            self.winner = "mafia"
        return self.winner is not None
