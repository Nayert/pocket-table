"""Small protections for the public join site: HTTPS redirect and rate limits.

Kept separate from main.py so the relay logic stays easy to read.
"""
import time
from collections import deque
from urllib.parse import urlsplit


class ForceHTTPSMiddleware:
    """Redirects plain-http page requests to https.

    Render (like most hosts) ends HTTPS at its proxy and passes the request on
    as http, adding `X-Forwarded-Proto: https` or `http`. We only act when that
    header says `http`, so running locally without a proxy is unaffected.
    Secure requests also get an HSTS header, so browsers go straight to https
    next time. WebSockets are left alone: the page is always https after the
    redirect, so it opens wss, and the host app already refuses plain ws.
    """

    def __init__(self, app, enabled: bool = True, public_url: str = ""):
        self.app = app
        self.enabled = enabled
        # With PUBLIC_URL set we redirect to that host, never to whatever
        # Host header a request made up.
        self.public_host = urlsplit(public_url).netloc if public_url else ""

    async def __call__(self, scope, receive, send):
        if not self.enabled or scope["type"] != "http":
            return await self.app(scope, receive, send)

        headers = {k.decode("latin-1").lower(): v.decode("latin-1")
                   for k, v in scope.get("headers", [])}
        proto = headers.get("x-forwarded-proto", "").split(",")[0].strip().lower()

        if proto == "http":
            host = self.public_host or headers.get("host", "")
            if not host:
                return await self.app(scope, receive, send)
            path = scope.get("raw_path") or scope.get("path", "/").encode()
            if isinstance(path, bytes):
                path = path.decode("latin-1")
            query = scope.get("query_string", b"").decode("latin-1")
            location = f"https://{host}{path}" + (f"?{query}" if query else "")
            # 301 for normal page loads; 308 keeps the method for anything else.
            status = 301 if scope.get("method") in ("GET", "HEAD") else 308
            await send({"type": "http.response.start", "status": status, "headers": [
                (b"location", location.encode("latin-1")),
                (b"content-length", b"0"),
                (b"cache-control", b"no-store"),
            ]})
            await send({"type": "http.response.body", "body": b""})
            return

        if proto == "https":
            async def send_with_hsts(message):
                if message["type"] == "http.response.start":
                    message.setdefault("headers", [])
                    message["headers"] = list(message["headers"]) + [
                        (b"strict-transport-security", b"max-age=31536000")]
                await send(message)
            return await self.app(scope, receive, send_with_hsts)

        return await self.app(scope, receive, send)


class RateLimiter:
    """Allows at most `limit` events per key in any `window` seconds."""

    def __init__(self, limit: int, window: float):
        self.limit = limit
        self.window = window
        self._hits: dict[str, deque] = {}

    def _prune(self, key: str, now: float) -> deque:
        hits = self._hits.setdefault(key, deque())
        while hits and now - hits[0] > self.window:
            hits.popleft()
        return hits

    def blocked(self, key: str) -> bool:
        """True if `key` has used up its allowance (doesn't count a hit)."""
        return len(self._prune(key, time.monotonic())) >= self.limit

    def hit(self, key: str) -> bool:
        """Counts one event. Returns False (and doesn't count it) if over the limit."""
        hits = self._prune(key, time.monotonic())
        if len(hits) >= self.limit:
            return False
        hits.append(time.monotonic())
        return True

    def forget_idle(self) -> None:
        """Drops keys with no recent hits so memory doesn't grow forever."""
        now = time.monotonic()
        for key in [k for k in self._hits if not self._prune(k, now)]:
            del self._hits[key]

    def reset(self) -> None:
        self._hits.clear()


def client_ip(headers, fallback: str | None) -> str:
    """Best guess at the visitor's IP address behind Render's proxy.

    Render sits behind Cloudflare, which sets CF-Connecting-IP itself (a client
    can't fake it). X-Forwarded-For is the fallback; its first entry is the
    original client. Locally there's no proxy, so we use the socket address.
    """
    ip = headers.get("cf-connecting-ip") or headers.get("true-client-ip")
    if not ip:
        forwarded = headers.get("x-forwarded-for", "")
        ip = forwarded.split(",")[0].strip()
    return ip or fallback or "unknown"
