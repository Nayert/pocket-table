// Draws the generic screens. Knows nothing about any specific game.
// Every string from the host goes in via textContent, never innerHTML,
// so a player called "<script>" can't run code on anyone's phone.
"use strict";

const Screens = (() => {
  let countdownTimer = null;
  let lastKey = "";          // type + actionId of the screen on show
  let draft = null;          // in-progress choice on that screen (kept across re-renders)
  let revealedKey = null;    // the secret on show, if the player tapped "reveal"
  let redrawSecret = null;   // redraws the secret box on screen, if any

  function el(tag, cls, text) {
    const e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text !== undefined && text !== null) e.textContent = String(text);
    return e;
  }

  function button(label, cls) {
    const b = el("button", cls || "btn", label);
    b.type = "button";
    return b;
  }

  const SUITS = { s: "♠", h: "♥", d: "♦", c: "♣" };
  const SUIT_NAMES = { s: "spades", h: "hearts", d: "diamonds", c: "clubs" };
  const RANK_NAMES = { A: "Ace", K: "King", Q: "Queen", J: "Jack", T: "10" };

  function cardEl(code) {
    if (typeof code !== "string" || code === "??" || code.length < 2) {
      const back = el("div", "pcard back");
      back.setAttribute("role", "img");
      back.setAttribute("aria-label", "face-down card");
      return back;
    }
    const r = code[0];
    const suit = code[1];
    const rank = r === "T" ? "10" : r;
    const red = suit === "h" || suit === "d";
    const c = el("div", "pcard" + (red ? " red" : ""));
    // The suit symbol is always shown, so red/black is never the only cue.
    c.append(el("span", "rank", rank), el("span", "suit", SUITS[suit] || suit));
    c.setAttribute("role", "img");
    c.setAttribute("aria-label", `${RANK_NAMES[r] || rank} of ${SUIT_NAMES[suit] || suit}`);
    return c;
  }

  function cardsEl(cards) {
    const row = el("div", "cards");
    row.setAttribute("role", "group");
    row.setAttribute("aria-label", "Cards");
    cards.forEach((c) => row.appendChild(cardEl(c)));
    return row;
  }

  function startCountdown(container, seconds) {
    clearInterval(countdownTimer);
    if (typeof seconds !== "number" || !(seconds > 0)) return;
    const endsAt = Date.now() + seconds * 1000;
    const label = el("div", "countdown");
    label.setAttribute("aria-hidden", "true"); // ticks every second; too noisy for screen readers
    container.prepend(label);
    const tick = () => {
      const left = Math.max(0, Math.ceil((endsAt - Date.now()) / 1000));
      const low = left <= 10;
      label.textContent = (low ? "⏱ " : "") + (left === 0 ? "Time's up" : left + "s left");
      label.classList.toggle("low", low);
      if (left === 0) clearInterval(countdownTimer);
    };
    tick();
    countdownTimer = setInterval(tick, 250);
  }

  // Body and cards: the parts a `secret` screen hides.
  function content(p) {
    const frag = document.createDocumentFragment();
    if (p.body) frag.appendChild(el("div", "card body-text", p.body));
    if (Array.isArray(p.cards) && p.cards.length) frag.appendChild(cardsEl(p.cards));
    return frag;
  }

  function linesEl(p) {
    const frag = document.createDocumentFragment();
    if (Array.isArray(p.lines) && p.lines.length) {
      const box = el("div", "card");
      const ul = el("ul", "lines");
      p.lines.forEach((l) => ul.appendChild(el("li", null, l)));
      box.appendChild(ul);
      frag.appendChild(box);
    }
    return frag;
  }

  const secretKey = (p) => JSON.stringify([p.body || "", p.cards || []]);

  // A screen marked `secret` (a role, hole cards) starts with its body and
  // cards hidden behind a tap-to-reveal box, so neighbours can't read them
  // over your shoulder. The reveal only lasts while the same secret stays on
  // screen; any different screen hides it again.
  function secretBox(key, p) {
    const box = el("div", "secret");
    const inner = el("div", "secret-content");
    inner.id = "secret-" + Math.random().toString(36).slice(2, 8);
    inner.appendChild(content(p));
    const toggle = button("", "btn secret-btn");
    toggle.setAttribute("aria-controls", inner.id);
    const draw = () => {
      const open = revealedKey === key;
      inner.hidden = !open;
      toggle.textContent = open ? "Hide 🙈" : "Tap to reveal 👁";
      toggle.setAttribute("aria-expanded", String(open));
      box.classList.toggle("open", open);
    };
    toggle.addEventListener("click", () => {
      revealedKey = revealedKey === key ? null : key;
      draw();
    });
    draw();
    redrawSecret = draw;
    box.append(toggle, inner);
    return box;
  }

  // Title, body text, cards and lines: any screen can have these.
  function common(container, p) {
    if (p.title) container.appendChild(el("h2", null, p.title));
    if (p.secret === true) container.appendChild(secretBox(p._secretKey, p));
    else container.appendChild(content(p));
    container.appendChild(linesEl(p));
    startCountdown(container, p.secondsLeft);
  }

  function disableAll(container, note) {
    container.querySelectorAll(".actions button, .actions input").forEach((b) => (b.disabled = true));
    if (note) {
      const n = el("p", "sent", note);
      n.setAttribute("role", "status");
      container.appendChild(n);
    }
  }

  function num(v, fallback) {
    return typeof v === "number" && Number.isFinite(v) ? v : fallback;
  }

  // Snap a value to the legal range and step the host gave us.
  function snap(v, spec) {
    const min = num(spec.min, -Infinity);
    const max = num(spec.max, Infinity);
    const step = num(spec.step, 1) > 0 ? num(spec.step, 1) : 1;
    if (!Number.isFinite(v)) return null;
    let x = Math.round(v);
    if (Number.isFinite(min)) x = min + Math.round((x - min) / step) * step;
    if (x > max) x = Number.isFinite(min) ? min + Math.floor((max - min) / step) * step : max;
    if (x < min) x = min;
    return x;
  }

  function numberInput(spec) {
    const input = el("input", "big-input");
    input.type = "number";
    input.inputMode = "numeric";
    if (spec.min !== undefined) input.min = spec.min;
    if (spec.max !== undefined) input.max = spec.max;
    input.step = spec.step || 1;
    input.value = spec.default !== undefined ? spec.default : (spec.min !== undefined ? spec.min : "");
    return input;
  }

  function readNumber(input, spec) {
    if (input.value.trim() === "") return null;
    const v = Number(input.value);
    if (!Number.isFinite(v)) return null;
    if (spec.min !== undefined && v < spec.min) return null;
    if (spec.max !== undefined && v > spec.max) return null;
    const s = snap(v, spec);
    return s === Math.round(v) ? s : null;
  }

  // Slider + number box + Min/Max buttons, limited to legal amounts.
  function amountPicker(spec, initial, onChange) {
    const wrap = el("div", "amount");
    const min = num(spec.min, 0);
    const max = num(spec.max, min);
    const label = el("label", null, `${spec.label || "Amount"}: ${min}–${max}`);
    const box = numberInput(spec);
    box.id = "amt-" + Math.random().toString(36).slice(2, 8);
    label.htmlFor = box.id;
    const slider = el("input", "slider");
    slider.type = "range";
    slider.min = min;
    slider.max = max;
    slider.step = spec.step || 1;
    slider.setAttribute("aria-label", (spec.label || "Amount") + " slider");

    const set = (v, from) => {
      const s = snap(v, spec);
      if (s === null) return;
      if (from !== box) box.value = s;
      if (from !== slider) slider.value = s;
      onChange(s);
    };
    slider.addEventListener("input", () => set(Number(slider.value), slider));
    box.addEventListener("input", () => {
      const v = readNumber(box, spec);
      box.setAttribute("aria-invalid", v === null ? "true" : "false");
      if (v !== null) { slider.value = v; onChange(v); } else onChange(null);
    });
    box.addEventListener("blur", () => set(Number(box.value) || min, null));

    const quick = el("div", "quick");
    [["Min", min], ["Half", (min + max) / 2], ["Max", max]].forEach(([name, v]) => {
      const q = button(`${name}`, "btn small");
      q.addEventListener("click", () => set(v, null));
      quick.appendChild(q);
    });

    wrap.append(label, slider, box, quick);
    set(initial !== undefined && initial !== null ? initial : num(spec.default, min), null);
    return { wrap, focus: () => box.focus() };
  }

  // ---- individual screens ----

  function waiting(container, p) {
    common(container, p);
    const s = el("div", "spinner");
    s.setAttribute("aria-hidden", "true");
    container.appendChild(s);
  }

  function info(container, p, send) {
    common(container, p);
    // "private" and "results" screens can still offer a button (e.g. "Ready")
    if (Array.isArray(p.options) && p.options.length) choice(container, p, send, true);
  }

  function choice(container, p, send, skipCommon) {
    if (!skipCommon) common(container, p);
    const options = Array.isArray(p.options) ? p.options : [];
    const min = num(p.min, 1);
    const max = num(p.max, 1);
    const multi = max > 1;
    const d = draft || (draft = { selected: [], amountFor: null, amount: null });
    const selected = new Set(d.selected.filter((id) => options.some((o) => o.id === id)));
    const actions = el("div", "actions");
    if (multi) actions.appendChild(el("p", "hint", min === max ? `Pick ${min}.` : `Pick ${min} to ${max}.`));
    const buttons = new Map();
    let amountBox = null;
    let submitBtn = null;
    let sent = false;

    const submit = (ids, value) => {
      if (sent) return;
      const payload = { actionId: p.actionId, choice: ids };
      if (value !== undefined) payload.value = value;
      if (send(payload) === false) return;
      sent = true;
      draft = null;
      disableAll(container, "Sent ✓ Waiting for others…");
    };

    const markSelected = (b, on, label) => {
      b.classList.toggle("selected", on);
      b.setAttribute("aria-pressed", String(on));
      b.firstChild.textContent = (on ? "✓ " : "") + label;
    };

    options.forEach((opt) => {
      const b = button("");
      b.appendChild(document.createTextNode(String(opt.label)));
      if (opt.sub) b.appendChild(el("span", "sub", opt.sub));
      if (multi || opt.input) b.setAttribute("aria-pressed", "false");
      b.addEventListener("click", () => {
        if (opt.input) return showAmount(opt, b, null);
        if (!multi) return submit([opt.id]);
        if (selected.has(opt.id)) selected.delete(opt.id);
        else if (selected.size < max) selected.add(opt.id);
        else return Screens.toast(`You can pick up to ${max}.`);
        markSelected(b, selected.has(opt.id), String(opt.label));
        d.selected = [...selected];
        submitBtn.disabled = selected.size < min;
      });
      buttons.set(opt.id, b);
      actions.appendChild(b);
    });

    // Options with an "input" (like Raise) ask for an amount before sending.
    function showAmount(opt, b, initial) {
      if (amountBox) amountBox.remove();
      buttons.forEach((x, id) => {
        const o = options.find((q) => q.id === id);
        if (o && o.input) markSelected(x, x === b, String(o.label));
      });
      d.amountFor = opt.id;
      amountBox = el("div", "card amount-card");
      let current = null;
      const ok = button("", "btn primary");
      const picker = amountPicker(opt.input, initial, (v) => {
        current = v;
        d.amount = v;
        ok.disabled = v === null;
        ok.textContent = v === null ? "Enter a legal amount" : `${opt.label} ${v}`;
      });
      ok.addEventListener("click", () => {
        if (current === null) return Screens.toast(`Enter ${opt.input.min}–${opt.input.max}`);
        submit([opt.id], current);
      });
      amountBox.append(picker.wrap, ok);
      b.after(amountBox);
      if (initial === null) picker.focus();
    }

    if (multi) {
      submitBtn = button(p.submitLabel || "Confirm", "btn primary");
      submitBtn.disabled = selected.size < min;
      submitBtn.addEventListener("click", () => submit([...selected]));
      actions.appendChild(submitBtn);
      selected.forEach((id) => {
        const o = options.find((q) => q.id === id);
        if (o) markSelected(buttons.get(id), true, String(o.label));
      });
    }
    container.appendChild(actions);

    // Restore a half-finished raise after the screen was refreshed.
    if (d.amountFor && buttons.has(d.amountFor)) {
      const o = options.find((q) => q.id === d.amountFor);
      if (o && o.input) showAmount(o, buttons.get(d.amountFor), d.amount);
    }
  }

  function input(container, p, send) {
    common(container, p);
    const actions = el("div", "actions");
    const isNumber = (p.inputKind || "number") === "number";
    const field = isNumber ? numberInput(p) : el("input", "big-input");
    field.id = "inp-" + Math.random().toString(36).slice(2, 8);
    const lab = el("label", null, isNumber && p.min !== undefined && p.max !== undefined
      ? `Your answer (${p.min}–${p.max})` : "Your answer");
    lab.htmlFor = field.id;
    if (!isNumber) {
      field.maxLength = num(p.max, 60);
      field.enterKeyHint = "send";
    }
    if (draft && draft.text !== undefined) field.value = draft.text;
    field.addEventListener("input", () => { (draft || (draft = {})).text = field.value; });
    const ok = button(p.submitLabel || "Send", "btn primary");
    let sent = false;
    const go = () => {
      if (sent) return;
      const value = isNumber ? readNumber(field, p) : field.value.trim();
      if (value === null || value === "") return Screens.toast("Check your answer");
      if (send({ actionId: p.actionId, choice: [], value }) === false) return;
      sent = true;
      draft = null;
      disableAll(container, "Sent ✓");
    };
    ok.addEventListener("click", go);
    field.addEventListener("keydown", (e) => { if (e.key === "Enter") { e.preventDefault(); go(); } });
    actions.append(lab, field, ok);
    container.appendChild(actions);
  }

  const RENDERERS = {
    "screen.waiting": waiting,
    "screen.private": info,
    "screen.results": info,
    "screen.choice": choice,
    "screen.input": input,
  };

  // Returns true if this is a different screen from the one on show.
  function render(container, type, payload, send) {
    clearInterval(countdownTimer);
    const p = Object.assign({}, payload || {});
    p._secretKey = p.secret === true ? secretKey(p) : null;
    if (p._secretKey !== revealedKey) revealedKey = null;
    const key = type + "|" + (p.actionId || "") + "|" + (p.title || "");
    const changed = key !== lastKey;
    if (changed) draft = null;
    lastKey = key;
    const keepScroll = changed ? 0 : window.scrollY;
    container.replaceChildren();
    redrawSecret = null;
    const fn = RENDERERS[type];
    if (!fn) {
      container.appendChild(el("p", "error", "This page is out of date. Please refresh."));
      return changed;
    }
    fn(container, p, send);
    if (changed) window.scrollTo(0, 0); else window.scrollTo(0, keepScroll);
    return changed;
  }

  function renderLobby(container, lobby, myId, hostAway) {
    clearInterval(countdownTimer);
    lastKey = "lobby";
    revealedKey = null;
    draft = null;
    container.replaceChildren();
    const players = Array.isArray(lobby.players) ? lobby.players : [];
    container.appendChild(el("h2", null, "Lobby"));
    if (lobby.selectedGame) container.appendChild(el("p", "game-name", "Game: " + lobby.selectedGame));
    const max = num(lobby.maxPlayers, 0);
    container.appendChild(el("p", "muted", players.length + (max ? " / " + max : "") + (players.length === 1 ? " player" : " players")));
    const ul = el("ul", "player-list");
    players.forEach((pl) => {
      const me = pl.id === myId;
      const li = el("li", me ? "me" : "");
      li.appendChild(el("span", "pname", String(pl.name) + (me ? " (you)" : "")));
      li.appendChild(el("span", pl.connected ? "online" : "offline", pl.connected ? "online" : "offline"));
      ul.appendChild(li);
    });
    container.appendChild(ul);
    const s = el("div", "spinner");
    s.setAttribute("aria-hidden", "true");
    container.appendChild(s);
    container.appendChild(el("p", "muted center", hostAway
      ? "The host is reconnecting…" : "Waiting for the host to start…"));
  }

  // Cover the secret again (page hidden, connection lost).
  function hideSecret() {
    revealedKey = null;
    if (redrawSecret) redrawSecret();
  }

  // Forget per-game state (reveals, drafts) when a game ends or we leave.
  function reset() {
    clearInterval(countdownTimer);
    revealedKey = null;
    draft = null;
    lastKey = "";
  }

  let toastTimer = null;
  function toast(text) {
    const t = document.getElementById("toast");
    t.textContent = "⚠ " + text;
    t.classList.remove("hidden");
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => t.classList.add("hidden"), 3500);
  }

  return { render, renderLobby, toast, reset, hideSecret };
})();
