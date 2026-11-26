// Connection, joining, reconnecting and message dispatch.
// The same page works in Local mode (served by the host phone) and Online
// mode (served by the relay): it always connects back to wherever it came from.
// No game rules live here: we only render what the host sends and send taps back.
"use strict";

const PROTOCOL_VERSION = 1;
const CODE_LENGTH = 4;
const NAME_MAX = 16;
const CONNECT_TIMEOUT_MS = 10000;
const RETRY_MAX_MS = 10000;
const SHOW_RETRY_AFTER = 4; // failed attempts before offering "Retry now"
const CODE_CHARS = /^[A-HJ-NP-Z2-9]+$/; // the relay never uses O, I, 0 or 1
const RATE_LIMIT_WAIT_MS = 30000;

// Every join.error reason in shared-protocol/README.md
const JOIN_ERRORS = {
  room_not_found: "No room with that code. Check the code on the host's screen.",
  room_full: "That room is full. Ask the host to make space.",
  name_taken: "Someone in this room already has that name. Try another.",
  bad_name: `Pick a name between 1 and ${NAME_MAX} characters.`,
  version_mismatch: "This page doesn't match the host's app version. Refresh this page, or ask the host to update their app.",
  game_in_progress: "A game is already running. You can join when it's back in the lobby.",
  rate_limited: "Too many join attempts from your network. Wait a minute, then try again.",
};
const CLOSED_REASONS = {
  host_left: "The host closed the room.",
  kicked: "The host removed you from the room.",
  expired: "The room expired because the host was gone too long.",
};

const $ = (id) => document.getElementById(id);

const state = {
  room: "",
  name: "",
  ws: null,
  playerId: null,
  joined: false,     // host has accepted us (join.ok)
  wantSeat: false,   // we should keep trying to (re)connect
  resuming: false,   // rejoining a saved seat (retry instead of giving up)
  inGame: false,
  hostAway: false,
  lobby: null,
  failures: 0,
  retryTimer: null,
  connectTimer: null,
  waitUntil: 0,      // after "rate_limited", don't let the Join button spam the server
};

// ---- localStorage (wrapped: private browsing can throw) ----
const store = {
  get(k) { try { return localStorage.getItem(k); } catch { return null; } },
  set(k, v) { try { localStorage.setItem(k, v); } catch { /* ignore */ } },
  del(k) { try { localStorage.removeItem(k); } catch { /* ignore */ } },
};
const tokenKey = (room) => "pg.token." + room;
const TOKEN_MAX_AGE_MS = 12 * 60 * 60 * 1000; // longer than any room lives

// Seat tokens are saved with a timestamp; old or malformed ones are dropped.
function getToken(room) {
  const raw = store.get(tokenKey(room));
  if (!raw) return null;
  try {
    const v = JSON.parse(raw);
    if (v && typeof v.t === "string" && Date.now() - v.at < TOKEN_MAX_AGE_MS) return v.t;
  } catch { /* fall through */ }
  store.del(tokenKey(room));
  return null;
}
function saveToken(room, token) {
  // Only one seat is remembered: forget seats in other rooms.
  try {
    for (let i = localStorage.length - 1; i >= 0; i--) {
      const k = localStorage.key(i);
      if (k && k.startsWith("pg.token.") && k !== tokenKey(room)) localStorage.removeItem(k);
    }
  } catch { /* ignore */ }
  store.set(tokenKey(room), JSON.stringify({ t: token, at: Date.now() }));
}

// ---- input cleaning (mirrors the host's rules so errors show before sending) ----
function cleanCode(raw) {
  return String(raw || "").toUpperCase().replace(/[^A-Z0-9]/g, "").slice(0, CODE_LENGTH);
}
// What's wrong with a typed room code or name, or "" if it's fine.
// The host and relay check again: this is only for quick, clear feedback.
function codeProblem(raw) {
  const code = cleanCode(raw);
  if (!code) return "Enter the room code from the host's screen.";
  if (!CODE_CHARS.test(code)) return "Room codes never use O, I, 0 or 1. Check the code on the host's screen.";
  if (code.length !== CODE_LENGTH) return `The room code has ${CODE_LENGTH} characters. You typed ${code.length}.`;
  return "";
}
function nameProblem(raw) {
  const nm = cleanName(raw);
  if (!nm) return String(raw || "").length ? "Use letters, numbers or emoji in your name." : "Enter your name.";
  if (nm.length > NAME_MAX) return JOIN_ERRORS.bad_name;
  return "";
}

function cleanName(raw) {
  // Control characters and invisible formatting characters (zero-width,
  // direction overrides) are removed so nobody can look like someone else.
  let s = String(raw || "");
  try { s = s.normalize("NFKC"); } catch { /* old browser */ }
  // eslint-disable-next-line no-control-regex
  return s.replace(/[\x00-\x1F\x7F\u00AD\u200B-\u200F\u202A-\u202E\u2060-\u2069\uFEFF]/g, "").trim();
}

// ---- views ----
function showOnly(id) {
  for (const v of ["join-view", "closed-view", "game-view"]) $(v).classList.toggle("hidden", v !== id);
  const inRoom = id === "game-view";
  $("leave-btn").classList.toggle("hidden", !inRoom);
  $("room-label").textContent = inRoom ? "Room " + state.room : "";
  if (!inRoom) setConn(null);
}

function showJoin(error) {
  showOnly("join-view");
  $("join-btn").disabled = false;
  $("join-btn").textContent = "Join";
  $("join-error").textContent = error || "";
  if (state.room) $("room-input").value = state.room;
}

function showClosed(text) {
  showOnly("closed-view");
  $("closed-text").textContent = text;
  $("closed-btn").focus();
}

function showGameView() {
  if ($("game-view").classList.contains("hidden")) showOnly("game-view");
}

function announce(text) {
  const a = $("announce");
  a.textContent = "";
  // a fresh text node after a tick makes screen readers re-read it
  setTimeout(() => { a.textContent = text || ""; }, 30);
}

// Banner + small status label. `kind` is one of: null, "connecting",
// "connected", "reconnecting", "host_away". Each state has its own text,
// so nothing depends on colour alone.
function setConn(kind, detail) {
  const label = $("conn-label");
  const LABELS = { connecting: "Connecting…", connected: "● Connected", reconnecting: "Reconnecting…", host_away: "Host away" };
  label.textContent = LABELS[kind] || "";
  label.className = "conn-label" + (kind ? " " + kind : " hidden");

  let text = "";
  if (kind === "connecting" && state.joined) text = "Connecting…";
  if (kind === "reconnecting") text = detail || "Connection lost. Reconnecting…";
  if (kind === "host_away") text = "The host lost connection. Waiting for them to come back…";
  const b = $("banner");
  $("banner-text").textContent = text;
  b.classList.toggle("hidden", !text);
  b.classList.toggle("warn", kind === "host_away");
  $("banner-retry").classList.toggle("hidden", !(kind === "reconnecting" && state.failures >= SHOW_RETRY_AFTER));
}

function toast(text) { Screens.toast(text); }

// ---- connection ----
function send(type, payload) {
  if (state.ws && state.ws.readyState === WebSocket.OPEN) {
    state.ws.send(JSON.stringify({ v: PROTOCOL_VERSION, type, to: "host", payload: payload || {} }));
    return true;
  }
  return false;
}

function connect() {
  clearTimeout(state.retryTimer);
  clearTimeout(state.connectTimer);
  if (state.ws) { const old = state.ws; state.ws = null; try { old.close(); } catch { /* ignore */ } }

  const proto = location.protocol === "https:" ? "wss" : "ws";
  const url = `${proto}://${location.host}/ws/player?room=${encodeURIComponent(state.room)}`;
  let ws;
  try { ws = new WebSocket(url); } catch { return onDrop(); }
  state.ws = ws;
  setConn(state.joined ? "reconnecting" : "connecting");

  // A socket stuck "connecting" (e.g. a sleeping server) counts as a failure.
  state.connectTimer = setTimeout(() => {
    if (state.ws === ws && ws.readyState !== WebSocket.OPEN) { try { ws.close(); } catch { /* ignore */ } onDrop(ws); }
  }, CONNECT_TIMEOUT_MS);

  ws.onopen = () => {
    if (state.ws !== ws) return;
    clearTimeout(state.connectTimer);
    send("join", {
      v: PROTOCOL_VERSION,
      room: state.room,
      name: state.name,
      reconnectToken: getToken(state.room) || undefined,
    });
  };

  ws.onmessage = (ev) => {
    if (state.ws !== ws) return;
    let msg;
    try { msg = JSON.parse(ev.data); } catch { return; }
    if (!msg || typeof msg.type !== "string") return;
    handle(msg.type, (msg.payload && typeof msg.payload === "object") ? msg.payload : {});
  };

  ws.onclose = () => onDrop(ws);
}

function onDrop(ws) {
  if (ws && state.ws !== ws) return; // an old socket we already replaced
  clearTimeout(state.connectTimer);
  state.ws = null;
  Screens.hideSecret();
  if (!state.wantSeat) return;

  if (!state.joined && !state.resuming) {
    // First attempt, never got in: let them fix the code or their network.
    state.wantSeat = false;
    showJoin(navigator.onLine === false
      ? "You're offline. Check your Wi-Fi or data."
      : "Couldn't reach the room. Check the code and your connection, then try again.");
    return;
  }
  state.failures += 1;
  const delay = Math.min(1000 * 2 ** Math.min(state.failures - 1, 4), RETRY_MAX_MS) + Math.random() * 400;
  const offline = navigator.onLine === false;
  setConn("reconnecting", offline
    ? "You're offline. We'll reconnect when your connection is back."
    : `Connection lost. Reconnecting… (attempt ${state.failures})`);
  if (!state.joined) showWaitingSeat();
  state.retryTimer = setTimeout(connect, delay);
}

// While rejoining a saved seat, show something better than an empty page.
function showWaitingSeat() {
  showGameView();
  const view = $("game-view");
  if (!view.childElementCount) {
    Screens.render(view, "screen.waiting", { title: "Rejoining…", body: "Getting your seat back." }, () => {});
  }
}

function retryNow() {
  state.failures = Math.max(0, SHOW_RETRY_AFTER - 1);
  connect();
}

// Close without triggering the reconnect logic in onclose.
function closeSocket() {
  clearTimeout(state.retryTimer);
  clearTimeout(state.connectTimer);
  state.wantSeat = false;
  const ws = state.ws;
  state.ws = null;
  if (ws) { try { ws.close(); } catch { /* ignore */ } }
}

function resetSeat() {
  state.joined = false;
  state.resuming = false;
  state.inGame = false;
  state.hostAway = false;
  state.playerId = null;
  state.lobby = null;
  state.failures = 0;
  Screens.reset();
  $("game-view").replaceChildren();
}

function leave() {
  if (state.inGame && !window.confirm("Leave the game? You'll lose your seat.")) return;
  send("leave");
  store.del(tokenKey(state.room));
  closeSocket();
  resetSeat();
  showJoin();
}

// ---- incoming messages ----
function sendAction(payload) {
  if (!send("action", payload)) {
    toast("Not connected. Your move wasn't sent. Try again once reconnected.");
    return false;
  }
  return true;
}

function renderLobby() {
  Screens.renderLobby($("game-view"), state.lobby || { players: [] }, state.playerId, state.hostAway);
}

function handle(type, p) {
  switch (type) {
    case "join.ok":
      if (p.protocolVersion !== undefined && p.protocolVersion !== PROTOCOL_VERSION) {
        handle("join.error", { reason: "version_mismatch" });
        break;
      }
      state.joined = true;
      state.playerId = typeof p.playerId === "string" ? p.playerId : null;
      state.failures = 0;
      state.resuming = false;
      if (typeof p.reconnectToken === "string") saveToken(state.room, p.reconnectToken);
      store.set("pg.name", state.name);
      setConn(state.hostAway ? "host_away" : "connected");
      showGameView();
      if (!state.inGame) { renderLobby(); announce("Joined room " + state.room); }
      break;

    case "join.error": {
      const reason = String(p.reason || "");
      const msg = JOIN_ERRORS[reason] || "Couldn't join (" + reason + ").";
      const hadSeat = state.joined || state.resuming;
      // Slowed down while reconnecting: keep the seat; the normal retry
      // (with growing delays) gets us back in once the limit passes.
      if (reason === "rate_limited" && hadSeat) break;
      if (reason === "rate_limited") state.waitUntil = Date.now() + RATE_LIMIT_WAIT_MS;
      store.del(tokenKey(state.room));
      closeSocket();
      resetSeat();
      if (hadSeat && reason === "room_not_found") showClosed("This room doesn't exist any more. The host may have closed it.");
      else showJoin(msg);
      break;
    }

    case "lobby.update":
      state.lobby = p;
      if (state.joined && !state.inGame) renderLobby();
      break;

    case "game.started":
      state.inGame = true;
      announce("Game started" + (p.name ? ": " + p.name : ""));
      break;

    case "game.ended":
      state.inGame = false;
      Screens.reset();
      if (state.joined) { renderLobby(); announce("Back in the lobby"); }
      break;

    case "action.error":
      toast(String(p.message || "That move isn't allowed."));
      break;

    case "host.disconnected":
      state.hostAway = true;
      setConn("host_away");
      if (state.joined && !state.inGame) renderLobby();
      break;

    case "host.reconnected":
      state.hostAway = false;
      setConn(state.joined ? "connected" : null);
      if (state.joined && !state.inGame) renderLobby();
      break;

    case "room.closed":
      store.del(tokenKey(state.room));
      closeSocket();
      resetSeat();
      showClosed(CLOSED_REASONS[p.reason] || "The room has closed.");
      break;

    default:
      if (type.startsWith("screen.") && state.joined) {
        state.inGame = true;
        showGameView();
        const changed = Screens.render($("game-view"), type, p, sendAction);
        if (changed && p.title) announce(String(p.title));
      }
  }
}

// ---- start up ----
function init() {
  const params = new URLSearchParams(location.search);
  const room = cleanCode(params.get("room"));
  const name = store.get("pg.name") || "";
  const roomInput = $("room-input");
  const nameInput = $("name-input");
  roomInput.value = room;
  nameInput.value = name;

  roomInput.addEventListener("input", () => {
    const pos = roomInput.selectionStart;
    const clean = cleanCode(roomInput.value);
    if (clean !== roomInput.value) {
      roomInput.value = clean;
      try { roomInput.setSelectionRange(pos, pos); } catch { /* ignore */ }
    }
    roomInput.removeAttribute("aria-invalid");
    if (clean.length === CODE_LENGTH && !nameInput.value) nameInput.focus();
  });
  nameInput.addEventListener("input", () => nameInput.removeAttribute("aria-invalid"));

  const flag = (input, message) => {
    input.setAttribute("aria-invalid", "true");
    $("join-error").textContent = message;
  };
  // Check a field when the player leaves it, but only once they've typed
  // something, so tabbing through an empty form doesn't shout at them.
  roomInput.addEventListener("blur", () => {
    const problem = roomInput.value && codeProblem(roomInput.value);
    if (problem) flag(roomInput, problem);
  });
  nameInput.addEventListener("blur", () => {
    const problem = nameInput.value && nameProblem(nameInput.value);
    if (problem) flag(nameInput, problem);
  });

  $("join-form").addEventListener("submit", (e) => {
    e.preventDefault();
    // Spam trap: a person never sees this field. Look busy and do nothing.
    if ($("website-input").value) {
      $("join-btn").disabled = true;
      $("join-btn").textContent = "Joining…";
      return;
    }
    const wait = Math.ceil((state.waitUntil - Date.now()) / 1000);
    if (wait > 0) {
      $("join-error").textContent = `Too many join attempts. Try again in ${wait} seconds.`;
      return;
    }
    const code = cleanCode(roomInput.value);
    const nm = cleanName(nameInput.value);
    const codeErr = codeProblem(roomInput.value);
    if (codeErr) {
      flag(roomInput, codeErr);
      roomInput.focus();
      return;
    }
    const nameErr = nameProblem(nameInput.value);
    if (nameErr) {
      flag(nameInput, nameErr);
      nameInput.focus();
      return;
    }
    if (state.room && state.room !== code) resetSeat();
    state.room = code;
    state.name = nm;
    state.wantSeat = true;
    state.failures = 0;
    $("join-btn").disabled = true;
    $("join-btn").textContent = "Joining…";
    $("join-error").textContent = "";
    connect();
  });

  $("leave-btn").addEventListener("click", leave);
  $("banner-retry").addEventListener("click", retryNow);
  $("closed-btn").addEventListener("click", () => { state.room = ""; showJoin(); roomInput.value = ""; roomInput.focus(); });

  // Came back after a refresh with a saved seat. Phones get passed around at
  // parties, so ask before taking the seat back instead of doing it silently.
  if (room && name && getToken(room)) {
    $("resume-text").textContent = `Continue as ${cleanName(name)} in room ${room}?`;
    $("resume-box").classList.remove("hidden");
    $("join-form").classList.add("hidden");
    $("resume-btn").addEventListener("click", () => {
      $("resume-box").classList.add("hidden");
      $("join-form").classList.remove("hidden");
      state.room = room;
      state.name = cleanName(name);
      state.wantSeat = true;
      state.resuming = true;
      state.failures = 0;
      showWaitingSeat();
      connect();
    });
    $("not-me-btn").addEventListener("click", () => {
      store.del(tokenKey(room));
      store.del("pg.name");
      nameInput.value = "";
      $("resume-box").classList.add("hidden");
      $("join-form").classList.remove("hidden");
      nameInput.focus();
    });
    $("resume-btn").focus();
  } else if (room) {
    nameInput.focus();
  }

  // Phones pause pages in the background; reconnect as soon as we're visible again.
  const wake = () => {
    if (state.wantSeat && (!state.ws || state.ws.readyState > WebSocket.OPEN)) {
      state.failures = 0;
      connect();
    }
  };
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible") wake();
    else Screens.hideSecret(); // phone locked or put down: cover roles and cards again
  });
  window.addEventListener("online", wake);
  window.addEventListener("pageshow", (e) => { if (e.persisted) wake(); });
}

init();
