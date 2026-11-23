"""Room bookkeeping for the relay. Knows nothing about games."""
import secrets
import time
from dataclasses import dataclass, field

from fastapi import WebSocket

# No O/0 or I/1, so codes are easy to read out loud.
CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
CODE_LENGTH = 4


@dataclass
class Room:
    code: str
    host_token: str
    max_players: int
    host: WebSocket | None = None
    players: dict[str, WebSocket] = field(default_factory=dict)
    last_activity: float = field(default_factory=time.monotonic)
    host_lost_at: float | None = None

    def touch(self) -> None:
        self.last_activity = time.monotonic()

    @property
    def full(self) -> bool:
        return len(self.players) >= self.max_players


class RoomManager:
    def __init__(self, max_rooms: int, max_players_cap: int):
        self.rooms: dict[str, Room] = {}
        self.max_rooms = max_rooms
        self.max_players_cap = max_players_cap

    def create(self, max_players: int) -> Room | None:
        if len(self.rooms) >= self.max_rooms:
            return None
        while True:
            code = "".join(secrets.choice(CODE_ALPHABET) for _ in range(CODE_LENGTH))
            if code not in self.rooms:
                break
        room = Room(
            code=code,
            host_token=secrets.token_urlsafe(16),
            max_players=max(1, min(max_players, self.max_players_cap)),
        )
        self.rooms[code] = room
        return room

    def get(self, code: str | None) -> Room | None:
        if not code:
            return None
        return self.rooms.get(code.strip().upper())

    def remove(self, code: str) -> Room | None:
        return self.rooms.pop(code, None)

    def expired(self, host_grace: float, idle_timeout: float) -> list[Room]:
        now = time.monotonic()
        out = []
        for room in self.rooms.values():
            host_gone_too_long = room.host is None and room.host_lost_at is not None \
                and now - room.host_lost_at > host_grace
            idle = now - room.last_activity > idle_timeout
            if host_gone_too_long or idle:
                out.append(room)
        return out
