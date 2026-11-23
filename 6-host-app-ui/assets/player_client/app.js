// Connection, joining, reconnecting and message dispatch.
// The same page works in Local mode (served by the host phone) and Online
// mode (served by the relay): it always connects back to wherever it came from.
"use strict";

const PROTOCOL_VERSION = 1;
const JOIN_ERRORS = {
  room_not_found: "No room with that code.",
  room_full: "That room is full.",
  name_taken: "Someone already has that name.",
  version_mismatch: "This page doesn't match the host's app version. Refresh, or update the host app.",
  game_in_progress: "A game has already started. Wait for the next one.",
  bad_name: "Pick a name (1–16 characters).",
};
// Errors where retrying won't help
const FATAL = new Set(Object.keys(JOIN_ERRORS));

const $ = (id) => document.getElementById(id);

const state = {
  room: "",
  name: "",
  ws: null,
  playerId: null,
  joined: false,
  inGame: false,
  lobby: null,
  retryDelay: 1000,
  retryTimer: null,
};

// ---- localStorage (wrapped: private browsing can throw) ----
const store = {
  get(k) { try { return localStorage.getItem(k); } catch { return null; } },
  set(k, v) { try { localStorage.setItem(k, v); } catch { /* ignore */ } },
  del(k) { try { localStorage.removeItem(k); } catch { /* ignore */ } },
};
const tokenKey = (room) => "pg.token." + room;

// ---- views ----
function showJoin(error) {
  $("join-view").classList.remove("hidden");
  $("game-view").classList.add("hidden");
  $("leave-btn").classList.add("hidden");
  $("room-label").textContent = "";
  $("join-btn").disabled = false;
  $("join-error").textContent = error || "";
}

function showGameView() {
  $("join-view").classList.add("hidden");
  $("game-view").classList.remove("hidden");
  $("leave-btn").classList.remove("hidden");
  $("room-label").textContent = "Room " + state.room;
}

function banner(text) {
  const b = $("banner");
  b.textContent = text || "";
  b.classList.toggle("hidden", !text);
}

// ---- connection ----
function send(type, payload) {
  if (state.ws && state.ws.readyState === WebSocket.OPEN) {
    state.ws.send(JSON.stringify({ v: PROTOCOL_VERSION, type, to: "host", payload: payload || {} }));
  }
}

function connect() {
  clearTimeout(state.retryTimer);
  const proto = location.protocol === "https:" ? "wss" : "ws";
  const url = `${proto}://${location.host}/ws/player?room=${encodeURIComponent(state.room)}`;
  const ws = new WebSocket(url);
  state.ws = ws;

  ws.onopen = () => {
    send("join", {
      v: PROTOCOL_VERSION,
      room: state.room,
      name: state.name,
      reconnectToken: store.get(tokenKey(state.room)) || undefined,
    });
  };

  ws.onmessage = (ev) => {
    let msg;
    try { msg = JSON.parse(ev.data); } catch { return; }
    handle(msg.type, msg.payload || {});
  };

  ws.onclose = () => {
    if (state.ws !== ws) return;
    if (!state.joined) {
      // never got in: let them fix the code/name
      if (!$("join-error").textContent) showJoin("Couldn't connect. Check the code and your Wi-Fi.");
      return;
    }
    banner("Connection lost. Reconnecting…");
    state.retryTimer = setTimeout(connect, state.retryDelay);
    state.retryDelay = Math.min(state.retryDelay * 2, 10000);
  };
}

// Close without triggering the reconnect logic in onclose.
function closeSocket() {
  clearTimeout(state.retryTimer);
  const ws = state.ws;
  state.ws = null;
  if (ws) ws.close();
}

function leave() {
  send("leave");
  store.del(tokenKey(state.room));
  closeSocket();
  state.joined = false;
  state.inGame = false;
  banner("");
  showJoin();
}

// ---- incoming messages ----
function sendAction(payload) {
  send("action", payload);
}

function handle(type, p) {
  switch (type) {
    case "join.ok":
      state.joined = true;
      state.playerId = p.playerId;
      state.retryDelay = 1000;
      store.set(tokenKey(state.room), p.reconnectToken);
      store.set("pg.name", state.name);
      banner("");
      showGameView();
      if (!state.inGame) Screens.renderLobby($("game-view"), state.lobby || { players: [] }, state.playerId);
      break;

    case "join.error":
      state.joined = false;
      if (p.reason === "room_not_found") store.del(tokenKey(state.room));
      showJoin(JOIN_ERRORS[p.reason] || "Couldn't join: " + p.reason);
      if (FATAL.has(p.reason)) closeSocket();
      break;

    case "lobby.update":
      state.lobby = p;
      if (state.joined && !state.inGame) Screens.renderLobby($("game-view"), p, state.playerId);
      break;

    case "game.started":
      state.inGame = true;
      break;

    case "game.ended":
      state.inGame = false;
      if (state.joined) Screens.renderLobby($("game-view"), state.lobby || { players: [] }, state.playerId);
      break;

    case "action.error":
      Screens.toast(p.message || "That move isn't allowed.");
      break;

    case "host.disconnected":
      banner("The host lost connection. Waiting for them to come back…");
      break;

    case "host.reconnected":
      banner("");
      break;

    case "room.closed":
      store.del(tokenKey(state.room));
      closeSocket();
      state.joined = false;
      banner("");
      showJoin(p.reason === "kicked" ? "The host removed you from the room."
        : p.reason === "host_left" ? "The host closed the room." : "The room has closed.");
      break;

    default:
      if (type && type.startsWith("screen.")) {
        state.inGame = true;
        showGameView();
        Screens.render($("game-view"), type, p, sendAction);
      }
  }
}

// ---- start up ----
function init() {
  const params = new URLSearchParams(location.search);
  const room = (params.get("room") || "").toUpperCase();
  const name = store.get("pg.name") || "";
  $("room-input").value = room;
  $("name-input").value = name;

  $("join-form").addEventListener("submit", (e) => {
    e.preventDefault();
    state.room = $("room-input").value.trim().toUpperCase();
    state.name = $("name-input").value.trim();
    if (!state.room || !state.name) return;
    $("join-btn").disabled = true;
    $("join-error").textContent = "";
    connect();
  });

  $("leave-btn").addEventListener("click", leave);

  // Came back from a refresh or a locked screen with a saved seat: rejoin straight away.
  if (room && name && store.get(tokenKey(room))) {
    state.room = room;
    state.name = name;
    connect();
  } else if (room) {
    $("name-input").focus();
  }

  // Phones pause pages in the background; reconnect as soon as we're visible again.
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible" && state.joined &&
        (!state.ws || state.ws.readyState > WebSocket.OPEN)) {
      state.retryDelay = 1000;
      connect();
    }
  });
}

init();
