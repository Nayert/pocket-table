// Draws the generic screens. Knows nothing about any specific game.
// Every string from the host goes in via textContent, never innerHTML,
// so a player called "<script>" can't run code on anyone's phone.
"use strict";

const Screens = (() => {
  let countdownTimer = null;

  function el(tag, cls, text) {
    const e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text !== undefined && text !== null) e.textContent = String(text);
    return e;
  }

  const SUITS = { s: "♠", h: "♥", d: "♦", c: "♣" };

  function cardEl(code) {
    if (!code || code === "??") return el("div", "pcard back");
    const rank = code[0] === "T" ? "10" : code[0];
    const suit = code[1];
    const red = suit === "h" || suit === "d";
    return el("div", "pcard" + (red ? " red" : ""), rank + (SUITS[suit] || suit));
  }

  function cardsEl(cards) {
    const row = el("div", "cards");
    cards.forEach((c) => row.appendChild(cardEl(c)));
    return row;
  }

  function startCountdown(container, seconds) {
    clearInterval(countdownTimer);
    if (typeof seconds !== "number" || seconds <= 0) return;
    const endsAt = Date.now() + seconds * 1000;
    const label = el("div", "countdown");
    container.prepend(label);
    const tick = () => {
      const left = Math.max(0, Math.ceil((endsAt - Date.now()) / 1000));
      label.textContent = left + "s";
      label.classList.toggle("low", left <= 10);
      if (left === 0) clearInterval(countdownTimer);
    };
    tick();
    countdownTimer = setInterval(tick, 250);
  }

  // Title, body text, cards and lines: any screen can have these.
  function common(container, p) {
    if (p.title) container.appendChild(el("h2", null, p.title));
    const text = p.body || p.message;
    if (text) container.appendChild(el("div", "card body-text", text));
    if (Array.isArray(p.cards) && p.cards.length) container.appendChild(cardsEl(p.cards));
    if (Array.isArray(p.lines) && p.lines.length) {
      const box = el("div", "card");
      const ul = el("ul", "lines");
      p.lines.forEach((l) => ul.appendChild(el("li", null, l)));
      box.appendChild(ul);
      container.appendChild(box);
    }
    startCountdown(container, p.secondsLeft);
  }

  function disableAll(container, note) {
    container.querySelectorAll("button, input").forEach((b) => (b.disabled = true));
    if (note) container.appendChild(el("p", "muted", note));
  }

  function numberInput(spec) {
    const input = el("input", "big-input");
    input.type = "number";
    input.inputMode = "numeric";
    if (spec.min !== undefined) input.min = spec.min;
    if (spec.max !== undefined) input.max = spec.max;
    if (spec.step !== undefined) input.step = spec.step;
    input.value = spec.default !== undefined ? spec.default : (spec.min !== undefined ? spec.min : "");
    return input;
  }

  function readNumber(input, spec) {
    const v = Number(input.value);
    if (!Number.isFinite(v)) return null;
    if (spec.min !== undefined && v < spec.min) return null;
    if (spec.max !== undefined && v > spec.max) return null;
    return Math.round(v);
  }

  // ---- individual screens ----

  function waiting(container, p) {
    common(container, p);
    container.appendChild(el("div", "spinner"));
  }

  function info(container, p, send) {
    common(container, p);
    // "private" and "results" screens can still offer a button (e.g. "Ready")
    if (Array.isArray(p.options) && p.options.length) choice(container, p, send, true);
  }

  function choice(container, p, send, skipCommon) {
    if (!skipCommon) common(container, p);
    const min = p.min ?? 1;
    const max = p.max ?? 1;
    const multi = max > 1;
    const selected = new Set();
    const buttons = [];
    let amountBox = null;

    const submit = (ids, value) => {
      const payload = { actionId: p.actionId, choice: ids };
      if (value !== undefined) payload.value = value;
      send(payload);
      disableAll(container, "Sent ✓");
    };

    (p.options || []).forEach((opt) => {
      const b = el("button", "btn");
      b.type = "button";
      b.appendChild(document.createTextNode(opt.label));
      if (opt.sub) b.appendChild(el("span", "sub", opt.sub));
      b.addEventListener("click", () => {
        if (opt.input) return showAmount(opt, b);
        if (!multi) return submit([opt.id]);
        if (selected.has(opt.id)) selected.delete(opt.id);
        else if (selected.size < max) selected.add(opt.id);
        b.classList.toggle("selected", selected.has(opt.id));
        submitBtn.disabled = selected.size < min;
      });
      buttons.push(b);
      container.appendChild(b);
    });

    // Options with an "input" (like Raise) ask for an amount before sending.
    function showAmount(opt, button) {
      if (amountBox) amountBox.remove();
      buttons.forEach((x) => x.classList.toggle("selected", x === button));
      amountBox = el("div", "card");
      amountBox.appendChild(el("label", null,
        `${opt.input.label || "Amount"} (${opt.input.min}–${opt.input.max})`));
      const row = el("div", "amount-row");
      const input = numberInput(opt.input);
      const ok = el("button", "btn primary", "OK");
      ok.type = "button";
      ok.style.width = "auto";
      ok.style.marginTop = "0";
      ok.addEventListener("click", () => {
        const v = readNumber(input, opt.input);
        if (v === null) return toast(`Enter ${opt.input.min}–${opt.input.max}`);
        submit([opt.id], v);
      });
      row.append(input, ok);
      amountBox.appendChild(row);
      button.after(amountBox);
      input.focus();
    }

    let submitBtn = null;
    if (multi) {
      submitBtn = el("button", "btn primary", p.submitLabel || "Confirm");
      submitBtn.type = "button";
      submitBtn.disabled = min > 0;
      submitBtn.addEventListener("click", () => submit([...selected]));
      container.appendChild(submitBtn);
    }
  }

  function input(container, p, send) {
    common(container, p);
    const isNumber = (p.inputKind || "number") === "number";
    const field = isNumber ? numberInput(p) : el("input", "big-input");
    if (!isNumber) {
      field.maxLength = p.max || 60;
      field.placeholder = p.placeholder || "";
    }
    const ok = el("button", "btn primary", p.submitLabel || "Send");
    ok.type = "button";
    ok.addEventListener("click", () => {
      const value = isNumber ? readNumber(field, p) : field.value.trim();
      if (value === null || value === "") return toast("Check your answer");
      send({ actionId: p.actionId, value });
      disableAll(container, "Sent ✓");
    });
    container.append(field, ok);
  }

  const RENDERERS = {
    "screen.waiting": waiting,
    "screen.private": info,
    "screen.results": info,
    "screen.choice": choice,
    "screen.input": input,
  };

  function render(container, type, payload, send) {
    clearInterval(countdownTimer);
    container.replaceChildren();
    const fn = RENDERERS[type];
    if (!fn) {
      container.appendChild(el("p", "error", "This page is out of date. Please refresh."));
      return;
    }
    fn(container, payload || {}, send);
  }

  function renderLobby(container, lobby, myId) {
    clearInterval(countdownTimer);
    container.replaceChildren();
    container.appendChild(el("h2", null, "Lobby"));
    if (lobby.selectedGame) container.appendChild(el("p", "muted", "Game: " + lobby.selectedGame));
    const ul = el("ul", "player-list");
    (lobby.players || []).forEach((pl) => {
      const li = el("li", pl.id === myId ? "me" : "");
      li.appendChild(el("span", null, pl.name + (pl.id === myId ? " (you)" : "")));
      if (!pl.connected) li.appendChild(el("span", "offline", "offline"));
      ul.appendChild(li);
    });
    container.appendChild(ul);
    container.appendChild(el("div", "spinner"));
    container.appendChild(el("p", "muted", "Waiting for the host to start…"));
  }

  let toastTimer = null;
  function toast(text) {
    const t = document.getElementById("toast");
    t.textContent = text;
    t.classList.remove("hidden");
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => t.classList.add("hidden"), 3000);
  }

  return { render, renderLobby, toast };
})();
