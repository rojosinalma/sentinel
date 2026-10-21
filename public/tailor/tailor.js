/* managed by tailor v0.9.2 — core — do not edit, run `tailor sync` */
/*
 * tailor — core/tailor.js — the behaviour layer. Vanilla, no dependencies, ~350 lines.
 * Exposes window.Tailor; auto-runs Tailor.upgrade(document) on DOMContentLoaded unless the <script>
 * tag carries data-tailor="manual". Toggles only aria/data attributes + hidden (core/conventions.md §4/§5).
 *
 * Pre-paint snippet — in <head>, AFTER the three core <link>s and BEFORE app.css, so the skin and palette links it
 * fills cascade over tokens.css (same specificity, later wins). Keep it in sync with Tailor.theme:
 *
 *   <script>(function(){var P='<project>',q=new URLSearchParams(location.search),g=function(k,d){var v=q.get(k);try{return v||localStorage.getItem(P+'.'+k)||d}catch(e){return v||d}};
 *   var h=document.documentElement,s=g('skin','<default-skin>'),p=g('palette','dracula'),m=g('mode','dark');
 *   if(m==='auto')m=matchMedia('(prefers-color-scheme: light)').matches?'light':'dark';
 *   h.dataset.skin=s;h.dataset.palette=p;h.dataset.mode=m;
 *   var l=document.getElementById('t-skin');if(l&&s!=='none')l.href=l.dataset.base+s+'/skin.css';
 *   var k=document.getElementById('t-palette');if(k)k.href=k.dataset.base+p+'.css';})();</script>
 *   <link id="t-skin" rel="stylesheet" data-base="/css/tailor/skins/" href="">
 *   <link id="t-palette" rel="stylesheet" data-base="/css/tailor/palettes/" href="">
 */
(function () {
  "use strict";
  const $ = (sel, root = document) => root.querySelector(sel);
  const $$ = (sel, root = document) => [...root.querySelectorAll(sel)];
  const on = (el, ev, fn, opts) => el.addEventListener(ev, fn, opts);
  const emit = (el, name, detail) => el.dispatchEvent(new CustomEvent("t:" + name, { bubbles: true, detail }));
  const mark = (el, key) => { if (el.dataset["t" + key] !== undefined) return false; el.dataset["t" + key] = ""; return true; };
  const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  const T = {};

  /* ── theme: skin × palette × mode (× kit: which rendering of the vocabulary, "tailor" markup by default) ── */
  const html = document.documentElement;
  const theme = {
    project: "tailor", skins: ["none"], palettes: ["dracula"], modes: { dracula: ["dark", "light"] }, kits: ["tailor"], defaults: { skin: "none", palette: "dracula", mode: "dark", kit: "tailor" },
    key: (k) => `${theme.project}.${k}`,
    store: (k, v) => { try { localStorage.setItem(theme.key(k), v); } catch (_) {} },
    read: (k) => { try { return localStorage.getItem(theme.key(k)); } catch (_) { return null; } },
    get: () => ({ skin: html.dataset.skin || theme.defaults.skin, palette: html.dataset.palette || theme.defaults.palette, mode: html.dataset.mode || theme.defaults.mode, choice: html.dataset.modeChoice || html.dataset.mode || theme.defaults.mode, kit: html.dataset.kit || theme.defaults.kit }),
    resolveMode(choice, palette) {
      const modes = theme.modes[palette] || ["dark"];
      let m = choice === "auto" ? (matchMedia("(prefers-color-scheme: light)").matches ? "light" : "dark") : choice;
      return modes.includes(m) ? m : modes[0];
    },
    set({ skin, palette, mode, kit } = {}, { persist = true } = {}) {
      const cur = theme.get();
      if (kit !== undefined && theme.kits.includes(kit)) { html.dataset.kit = kit; if (persist) theme.store("kit", kit); }
      if (skin !== undefined && theme.skins.includes(skin)) { html.dataset.skin = skin; if (persist) theme.store("skin", skin); }
      if (palette !== undefined && theme.palettes.includes(palette)) { html.dataset.palette = palette; if (persist) theme.store("palette", palette); }
      if (mode !== undefined && /^(dark|light|auto)$/.test(mode)) { html.dataset.modeChoice = mode; if (persist) theme.store("mode", mode); }
      const next = theme.get();
      if (!html.dataset.kit) html.dataset.kit = next.kit;
      html.dataset.mode = theme.resolveMode(next.choice, next.palette);
      const ls = $("#t-skin"); if (ls) { ls.href = next.skin === "none" ? "" : ls.dataset.base + next.skin + "/skin.css"; ls.disabled = next.skin === "none"; }
      const lp = $("#t-palette"); if (lp) lp.href = lp.dataset.base + next.palette + ".css";
      theme.paintPickers();
      if (cur.skin !== next.skin || cur.palette !== next.palette || cur.mode !== html.dataset.mode || cur.kit !== next.kit) emit(html, "theme", theme.get());
    },
    paintPickers() {
      const cur = theme.get();
      const modes = theme.modes[cur.palette] || ["dark"];
      $$("[data-tailor-picker]").forEach((el) => {
        const what = el.dataset.tailorPicker;
        if (el.tagName === "SELECT" && !el.options.length) theme.fillPicker(el, what);
        const val = what === "mode" ? cur.mode : cur[what];
        if (el.tagName === "SELECT" || el.tagName === "INPUT") el.value = val;
        else $$("[data-value]", el).forEach((b) => { const onIt = b.dataset.value === val; b.setAttribute(b.hasAttribute("aria-selected") ? "aria-selected" : "aria-pressed", onIt); });
        if (what === "mode") $$("option, [data-value]", el).forEach((o) => { o.disabled = !modes.includes(o.value ?? o.dataset.value); });
      });
      // sun/moon toggle: shows the mode a click switches to; disabled when the palette offers one mode only
      $$("[data-tailor-mode-toggle]").forEach((b) => {
        const to = cur.mode === "light" ? "dark" : "light";
        b.disabled = !modes.includes(to);
        b.setAttribute("aria-label", b.disabled ? `${theme.labelOf(cur.mode)} only` : `Switch to ${to} mode`);
        b.dataset.tip = b.getAttribute("aria-label"); refreshTip(b);
        b.dataset.modeTo = to;
        b.innerHTML = theme.modeIcon(to);
      });
    },
    labelOf: (m) => (m === "light" ? "Light" : "Dark"),
    // Icon for the toggle: the consumer sprite (bi:sun / bi:moon-stars, always bundled by `tailor apply`) or a text glyph.
    modeIcon(to) {
      const name = to === "light" ? "bi-sun" : "bi-moon-stars";
      return theme.icons ? `<svg class="t-icon" aria-hidden="true"><use href="${esc(theme.icons)}#${name}"/></svg>` : `<span class="t-icon" aria-hidden="true">${to === "light" ? "☼" : "☾"}</span>`;
    },
    // Options for a picker: every id the config offers, sorted alphabetically by label; the "none" skin last.
    options(what) {
      const labels = (theme.labels || {})[what === "skin" ? "skins" : what === "kit" ? "kits" : "palettes"] || {};
      if (what === "mode") return [["dark", "Dark"], ["light", "Light"]];
      if (what === "kit") return theme.kits.map((id) => [id, labels[id] || id]);
      const ids = (what === "skin" ? theme.skins : theme.palettes).filter((id) => id !== "none");
      const rows = ids.map((id) => [id, labels[id] || id]).sort((a, b) => a[1].localeCompare(b[1], undefined, { sensitivity: "base" }));
      if (what === "skin" && theme.skins.includes("none")) rows.push(["none", "No skin"]);
      return rows;
    },
    fillPicker(sel, what) {
      sel.innerHTML = theme.options(what).map(([v, l]) => `<option value="${esc(v)}">${esc(l)}</option>`).join("");
    },
    // <div data-tailor-pickers> → skin + palette selects (only when there is a choice), then the sun/moon toggle LAST (rightmost).
    // data-tailor-pickers="mode" | "skin palette" | … limits the parts (settings page gets the selects, footer the toggle).
    // Controls are data-size="xs" inside a .t-footer (the footer is --t-footer-h tall), "sm" elsewhere.
    renderPickers(root = document) {
      $$("[data-tailor-pickers]", root).forEach((box) => {
        if (!mark(box, "Pickers")) return;
        const want = (box.dataset.tailorPickers || "mode skin palette kit").split(/\s+/);
        const size = box.closest(".t-footer") ? "xs" : "sm";
        const parts = [];
        if (want.includes("skin") && theme.skins.filter((s) => s !== "none").length > 1) parts.push(`<select class="t-select" data-size="${size}" data-tailor-picker="skin" aria-label="Skin"></select>`);
        if (want.includes("palette") && theme.palettes.length > 1) parts.push(`<select class="t-select" data-size="${size}" data-tailor-picker="palette" aria-label="Palette"></select>`);
        // kit select (showcase: tailor markup vs a component kit rendering the same demos) — only when there is a choice
        if (want.includes("kit") && theme.kits.length > 1) parts.push(`<select class="t-select" data-size="${size}" data-tailor-picker="kit" aria-label="Kit"></select>`);
        if (want.includes("mode")) parts.push(`<button type="button" class="t-btn" data-variant="ghost" data-size="${size}" data-icon="only" data-tailor-mode-toggle></button>`);
        box.classList.add("t-pickers");
        box.innerHTML = parts.join("");
      });
    },
    init(opts = {}) {
      Object.assign(theme, opts);
      if (opts.defaults) theme.defaults = { ...theme.defaults, ...opts.defaults };
      if (theme.icons === undefined && theme.base) theme.icons = theme.base + "icons.svg";
      theme.renderPickers();
      const q = new URLSearchParams(location.search);
      const pick = (k) => q.get(k) || theme.read(k) || theme.defaults[k];
      theme.set({ skin: pick("skin"), palette: pick("palette"), mode: pick("mode"), kit: pick("kit") }, { persist: false });
      $$("[data-tailor-picker]").forEach((el) => {
        if (el.tagName === "SELECT" || el.tagName === "INPUT") on(el, "change", () => theme.set({ [el.dataset.tailorPicker]: el.value }));
        else on(el, "click", (e) => { const b = e.target.closest("[data-value]"); if (b) theme.set({ [el.dataset.tailorPicker]: b.dataset.value }); });
      });
      $$("[data-tailor-mode-toggle]").forEach((b) => on(b, "click", () => theme.set({ mode: b.dataset.modeTo || (html.dataset.mode === "light" ? "dark" : "light") })));
      matchMedia("(prefers-color-scheme: light)").addEventListener("change", () => { if (theme.get().choice === "auto") theme.set({}); });
    },
  };
  T.theme = theme;

  /* ── toasts ───────────────────────────────────────────────────────────────── */
  // tone icons for toasts/confirm: sprite symbols (always in the consumer sprite) when the theme knows one, else text glyphs
  const ICONS = { success: ["bi-check-circle", "✓"], warning: ["bi-exclamation-triangle", "▲"], danger: ["bi-x-circle", "✕"], info: ["bi-info-circle", "ⓘ"], question: ["bi-question-circle", "?"] };
  const spriteIcon = (name, glyph, cls = "") => theme.icons ? `<svg class="t-icon ${cls}" aria-hidden="true"><use href="${esc(theme.icons)}#${name}"/></svg>` : `<span class="t-icon ${cls}" aria-hidden="true">${glyph}</span>`;
  const toneIcon = (tone, cls = "") => { const [name, glyph] = ICONS[tone] || ["", ""]; return spriteIcon(name, glyph, cls); };
  T.toast = (tone, msg, { timeout = 2500 } = {}) => {
    if (tone === "error") tone = "danger";
    let region = $("#t-toasts");
    if (!region) { region = document.createElement("div"); region.id = "t-toasts"; region.className = "t-toasts"; region.setAttribute("aria-live", "polite"); region.setAttribute("aria-atomic", "false"); document.body.appendChild(region); }
    const el = document.createElement("div");
    el.className = "t-toast"; el.dataset.tone = tone; el.setAttribute("role", "status");
    el.innerHTML = `${toneIcon(tone, "t-toast-icon")}<span class="t-toast-body"></span>`;
    el.lastChild.textContent = msg;
    region.appendChild(el);
    const leave = () => { if (el.dataset.leaving !== undefined) return; el.dataset.leaving = ""; on(el, "animationend", () => el.remove(), { once: true }); setTimeout(() => el.remove(), 600); };
    if (timeout > 0) setTimeout(leave, timeout);
    on(el, "click", leave);
    return el;
  };

  /* ── tabs ─────────────────────────────────────────────────────────────────── */
  T.tabs = (root = document) => $$(".t-tabs", root).forEach((tabs) => {
    if (!mark(tabs, "Tabs")) return;
    const list = $(".t-tabs-list", tabs); if (!list) return;
    const items = () => $$("[role=tab]", list);
    const select = (tab, focus) => {
      items().forEach((t) => { const onIt = t === tab; t.setAttribute("aria-selected", onIt); t.tabIndex = onIt ? 0 : -1; const p = t.getAttribute("aria-controls") && document.getElementById(t.getAttribute("aria-controls")); if (p) p.hidden = !onIt; });
      if (focus) tab.focus(); emit(tabs, "change", { tab, id: tab.id });
    };
    on(list, "click", (e) => { const t = e.target.closest("[role=tab]"); if (t && !t.disabled) select(t, false); });
    on(list, "keydown", (e) => {
      const ts = items().filter((t) => !t.disabled), i = ts.indexOf(document.activeElement); if (i < 0) return;
      const n = { ArrowRight: i + 1, ArrowLeft: i - 1, Home: 0, End: ts.length - 1 }[e.key]; if (n === undefined) return;
      e.preventDefault(); select(ts[(n + ts.length) % ts.length], true);
    });
  });

  /* ── listbox ──────────────────────────────────────────────────────────────── */
  T.listbox = (root = document) => $$(".t-list[role=listbox]", root).forEach((list) => {
    if (!mark(list, "List")) return;
    const multi = list.getAttribute("aria-multiselectable") === "true";
    const opts = () => $$("[role=option]:not(:disabled)", list);
    const toggle = (o) => {
      if (multi) o.setAttribute("aria-selected", o.getAttribute("aria-selected") !== "true");
      else opts().forEach((x) => x.setAttribute("aria-selected", x === o));
      emit(list, "change", { selected: opts().filter((x) => x.getAttribute("aria-selected") === "true") });
    };
    on(list, "click", (e) => { const o = e.target.closest("[role=option]"); if (o && !o.disabled) toggle(o); });
    on(list, "keydown", (e) => {
      const os = opts(), i = os.indexOf(document.activeElement); if (i < 0) return;
      if (e.key === "ArrowDown" || e.key === "ArrowUp") { e.preventDefault(); os[(i + (e.key === "ArrowDown" ? 1 : -1) + os.length) % os.length].focus(); }
      if (e.key === " " || e.key === "Enter") { e.preventDefault(); toggle(os[i]); }
    });
  });

  /* ── menus (details) ──────────────────────────────────────────────────────── */
  T.menus = (root = document) => $$("details.t-menu", root).forEach((m) => {
    if (!mark(m, "Menu")) return;
    const list = $(".t-menu-list", m), summary = $("summary", m);
    // the open menu is the current T.popup: opening another popup, Escape or an outside pointerdown closes it
    if (list && summary) on(m, "toggle", () => {
      if (m.open) T.popup.open(list, summary, () => { m.open = false; });
      else { delete list.dataset.at; delete list.dataset.align; if (T.popup.current()?.panel === list) T.popup.close(); }
    });
    on(m, "click", (e) => {
      const it = e.target.closest(".t-menu-item"); if (!it) return;
      if (it.getAttribute("role") === "menuitemcheckbox") { it.setAttribute("aria-checked", it.getAttribute("aria-checked") !== "true"); emit(m, "change", { item: it }); }
      else m.removeAttribute("open");
    });
  });

  /* ── dialogs / drawers ────────────────────────────────────────────────────── */
  T.dialogs = (root = document) => {
    $$("[data-dialog-open]", root).forEach((b) => { if (!mark(b, "DlgOpen")) return; on(b, "click", () => { const d = document.getElementById(b.dataset.dialogOpen); if (d) { d._tOpener = b; d.showModal(); } }); });
    $$("dialog.t-dialog, dialog.t-drawer, dialog.t-palette", root).forEach((d) => {
      if (!mark(d, "Dlg")) return;
      on(d, "click", (e) => { if (e.target === d) d.close(""); const c = e.target.closest("[data-dialog-close]"); if (c) d.close(c.dataset.dialogClose || ""); });
      on(d, "close", () => { emit(d, "close", { value: d.returnValue }); if (d._tOpener?.isConnected) d._tOpener.focus(); });
    });
  };

  /* ── confirm ──────────────────────────────────────────────────────────────── */
  T.confirm = (title, bodyHtml, { label = "Confirm", danger = true } = {}) => {
    const d = $("#t-confirm"); if (!d) return Promise.reject(new Error("#t-confirm dialog missing"));
    const h = $("#t-confirm-title", d), ok = $("#t-confirm-ok", d);
    d.dataset.tone = danger ? "danger" : "neutral";
    const icon = $(".t-icon", h); if (icon) icon.outerHTML = toneIcon(danger ? "warning" : "question");
    (h.querySelector("span:not(.t-icon)") || h).textContent = title;
    $("#t-confirm-body", d).innerHTML = bodyHtml;
    ok.textContent = label; ok.dataset.variant = danger ? "danger" : "primary";
    return new Promise((resolve) => {
      let confirmed = false;
      ok.onclick = () => { confirmed = true; d.close("confirm"); };
      on(d, "close", () => { ok.onclick = null; resolve(confirmed); }, { once: true });
      d.showModal();
    });
  };

  /* ── relative time ────────────────────────────────────────────────────────── */
  T.relativeTime = (date, now = Date.now()) => {
    const d = date instanceof Date ? date : new Date(date); if (isNaN(d)) return "";
    const diff = (d.getTime() - now) / 1000, abs = Math.abs(diff), past = diff < 0;
    const fmt = (n, u) => (past ? `${n} ${u} ago` : `in ${n} ${u}`);
    if (abs < 45) return "just now";
    if (abs < 3600) return fmt(Math.round(abs / 60), "min");
    if (abs < 86400) return fmt(Math.round(abs / 3600), "h");
    const days = Math.round(abs / 86400);
    if (days === 1) return past ? "yesterday" : "tomorrow";
    if (days < 7) return fmt(days, "d");
    const sameYear = d.getFullYear() === new Date(now).getFullYear();
    return d.toLocaleDateString(undefined, sameYear ? { day: "numeric", month: "short" } : { day: "numeric", month: "short", year: "numeric" });
  };
  T.times = (root = document) => {
    const paint = () => $$("time.t-time[data-relative]", root).forEach((t) => {
      if (t.dataset.ago !== undefined && !t.getAttribute("datetime")) t.setAttribute("datetime", new Date(Date.now() - Number(t.dataset.ago) * 1000).toISOString());
      const d = new Date(t.getAttribute("datetime")); if (isNaN(d)) return;
      t.textContent = T.relativeTime(d); if (!t.dataset.tip) t.dataset.tip = d.toLocaleString();
    });
    paint(); if (!T.times._timer) T.times._timer = setInterval(paint, 60000);
  };

  /* ── tooltips ─────────────────────────────────────────────────────────────── */
  // The only tooltip: data-tip (title= is never used — browser-native). Delegated at the document level, so elements
  // added or re-labelled later (theme toggle, relative times, injected markup) need no re-run; T.tooltips(root) stays
  // for API compatibility and only installs the delegation once.
  let tip, tipFor = null;
  const describedBy = (el, add) => { const ids = (el.getAttribute("aria-describedby") || "").split(/\s+/).filter((x) => x && x !== "t-tooltip"); if (add) ids.push("t-tooltip"); ids.length ? el.setAttribute("aria-describedby", ids.join(" ")) : el.removeAttribute("aria-describedby"); };
  const showTip = (el) => {
    if (!el.dataset.tip) return hideTip();
    if (!tip) { tip = document.createElement("div"); tip.className = "t-tooltip"; tip.id = "t-tooltip"; tip.setAttribute("role", "tooltip"); tip.hidden = true; document.body.appendChild(tip); }
    if (tipFor && tipFor !== el) describedBy(tipFor, false);
    tipFor = el; tip.textContent = el.dataset.tip; tip.hidden = false; describedBy(el, true);
    const r = el.getBoundingClientRect(), w = tip.offsetWidth, h = tip.offsetHeight, at = el.dataset.tipAt || "top", g = 6;
    let x = r.left + r.width / 2 - w / 2, y = r.top - h - g;
    if (at === "bottom") y = r.bottom + g; if (at === "left") { x = r.left - w - g; y = r.top + r.height / 2 - h / 2; } if (at === "right") { x = r.right + g; y = r.top + r.height / 2 - h / 2; }
    tip.style.left = Math.max(4, Math.min(innerWidth - w - 4, x)) + "px"; tip.style.top = Math.max(4, y) + "px";
  };
  const hideTip = () => { if (tip) tip.hidden = true; if (tipFor) describedBy(tipFor, false); tipFor = null; };
  const refreshTip = (el) => { if (tipFor === el && tip && !tip.hidden) showTip(el); };
  const tipTarget = (e) => (e.target instanceof Element ? e.target.closest("[data-tip]") : null);
  let tipsWired = false;
  T.tooltips = () => {
    if (tipsWired) return; tipsWired = true;
    on(document, "mouseover", (e) => { const el = tipTarget(e); if (el && el !== tipFor) showTip(el); });
    on(document, "mouseout", (e) => { const el = tipTarget(e); if (el && el === tipFor && !(e.relatedTarget instanceof Element && el.contains(e.relatedTarget))) hideTip(); });
    on(document, "focusin", (e) => { const el = tipTarget(e); if (el) showTip(el); });
    on(document, "focusout", (e) => { const el = tipTarget(e); if (el && el === tipFor) hideTip(); });
    on(document, "keydown", (e) => { if (e.key === "Escape") hideTip(); });
    // capture-phase scroll on document fires for every scroller (the .t-shell-main container as well as the window)
    on(document, "scroll", () => { if (tipFor && !tipFor.matches(":hover, :focus-within")) hideTip(); }, { passive: true, capture: true });
  };

  /* ── help popover ─────────────────────────────────────────────────────────── */
  T.help = (root = document) => $$(".t-help", root).forEach((h) => {
    if (!mark(h, "Help")) return;
    const b = $(".t-help-btn", h), box = $(".t-help-box", h); if (!b || !box) return;
    if (!box.id) box.id = "t-help-" + Math.random().toString(36).slice(2, 8); b.setAttribute("aria-controls", box.id);
    let t;
    // hover shows the box unregistered (closes on mouseleave); a click pins it and registers it with T.popup, so it
    // behaves like any other popup: one open at a time, Escape / outside pointerdown close it
    const show = () => { box.hidden = false; b.setAttribute("aria-expanded", "true"); };
    const close = () => { box.hidden = true; delete box.dataset.pinned; delete box.dataset.at; delete box.dataset.align; b.setAttribute("aria-expanded", "false"); };
    const pin = () => { box.dataset.pinned = ""; T.popup.open(box, b, close); b.setAttribute("aria-expanded", "true"); };
    const unpin = () => (T.popup.current()?.panel === box ? T.popup.close() : close());
    h._tClose = () => { if (box.dataset.pinned === undefined) close(); };
    on(b, "click", (e) => { e.stopPropagation(); clearTimeout(t); box.dataset.pinned !== undefined ? unpin() : pin(); });
    on(b, "mouseenter", () => { t = setTimeout(() => { if (box.hidden) show(); }, 1000); });
    on(b, "mouseleave", () => { clearTimeout(t); setTimeout(() => { if (box.dataset.pinned === undefined && !box.matches(":hover")) close(); }, 200); });
    on(box, "mouseleave", () => { if (box.dataset.pinned === undefined) close(); });
    on(box, "click", (e) => e.stopPropagation());
  });
  on(document, "keydown", (e) => { if (e.key === "Escape") $$(".t-help").forEach((h) => h._tClose?.()); }); // hover-shown boxes; pinned ones close via T.popup

  /* ── code: copy + tabs ────────────────────────────────────────────────────── */
  T.copy = (root = document) => {
    $$(".t-code-copy", root).forEach((b) => { if (!mark(b, "Copy")) return; on(b, "click", () => {
      const pre = b.closest(".t-code-pre"); const clone = pre.cloneNode(true); $$(".t-code-copy, .t-tok-prompt", clone).forEach((x) => x.remove());
      const txt = clone.innerText.replace(/^\s*/, "").replace(/\\\n\s*/g, "");
      (navigator.clipboard ? navigator.clipboard.writeText(txt) : Promise.reject()).then(() => { b.dataset.copied = ""; setTimeout(() => delete b.dataset.copied, 1200); }, () => T.toast("warning", "clipboard unavailable"));
    }); });
    $$(".t-code-tabs", root).forEach((tabs) => { if (!mark(tabs, "CodeTabs")) return; on(tabs, "click", (e) => { const b = e.target.closest("[role=tab]"); if (!b) return; $$("[role=tab]", tabs).forEach((x) => x.setAttribute("aria-selected", x === b)); emit(tabs, "change", { tab: b }); }); });
  };

  /* ── small ones ───────────────────────────────────────────────────────────── */
  T.truncate = (root = document) => $$(".t-truncate[data-expand]", root).forEach((el) => { if (!mark(el, "Trunc")) return; const flip = () => el.setAttribute("aria-expanded", el.getAttribute("aria-expanded") !== "true"); on(el, "click", flip); on(el, "keydown", (e) => { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); flip(); } }); });
  T.dismiss = (root = document) => $$("[data-dismiss]", root).forEach((b) => { if (!mark(b, "Dismiss")) return; on(b, "click", () => b.closest(".t-alert, .t-toast")?.remove()); });
  T.filters = (root = document) => $$(".t-btn-group[data-role=filter]", root).forEach((g) => { if (!mark(g, "Filter")) return; on(g, "click", (e) => { const b = e.target.closest(".t-btn"); if (!b) return; $$(".t-btn", g).forEach((x) => x.setAttribute("aria-pressed", x === b)); emit(g, "change", { button: b }); }); });

  /* ── settings auto-save + duration ────────────────────────────────────────── */
  T.duration = {
    set(group, seconds) { const n = Number(seconds) || 0, sel = $("select", group); const unit = [...sel.options].map((o) => Number(o.value)).sort((a, b) => b - a).find((u) => n % u === 0) || 1; sel.value = unit; $("input", group).value = n / unit; },
    get(group) { return Math.round((Number($("input", group).value) || 0) * Number($("select", group).value)); },
  };
  const settingValue = (el) => (el.classList.contains("t-duration") ? T.duration.get(el) : el.type === "checkbox" ? el.checked : el.value);
  const settingRevert = (el) => { const last = el.dataset.last; if (el.classList.contains("t-duration")) T.duration.set(el, last); else if (el.type === "checkbox") el.checked = last === "true"; else el.value = last; };
  T.settingsAutoSave = (root, save) => {
    if (!mark(root, "Settings")) return;
    $$(".t-duration[data-setting]", root).forEach((g) => T.duration.set(g, g.dataset.value));
    $$("[data-setting]", root).forEach((el) => { el.dataset.last = settingValue(el); });
    on(root, "change", async (e) => {
      const el = e.target.closest("[data-setting]"); if (!el) return;
      const row = el.closest(".t-setting"), value = settingValue(el);
      if (row) row.dataset.state = "saving";
      const res = await Promise.resolve().then(() => save(el.dataset.setting, value)).catch((err) => ({ ok: false, message: err.message }));
      if (row) row.dataset.state = res.ok ? "saved" : "failed";
      T.toast(res.ok ? "success" : "danger", res.message || (res.ok ? "Saved" : "Save failed"));
      if (res.ok) el.dataset.last = value; else settingRevert(el);
    });
  };

  /* ── sortable table ───────────────────────────────────────────────────────── */
  T.sortable = (root = document) => $$(".t-table", root).forEach((table) => {
    if (!mark(table, "Sort")) return;
    const ths = $$("thead th[data-sort]", table); if (!ths.length) return;
    on(table.tHead, "click", (e) => {
      const th = e.target.closest("th[data-sort]"); if (!th) return;
      const key = th.dataset.sort, dir = th.getAttribute("aria-sort") === "ascending" ? "descending" : "ascending";
      ths.forEach((x) => x.setAttribute("aria-sort", x === th ? dir : "none"));
      const idx = [...th.parentNode.children].indexOf(th), body = table.tBodies[0];
      const groups = []; let cur = null;
      [...body.rows].forEach((r) => { if (r.classList.contains("t-table-group")) { cur = { head: r, rows: [] }; groups.push(cur); } else { if (!cur) { cur = { head: null, rows: [] }; groups.push(cur); } cur.rows.push(r); } });
      const val = (r) => r.dataset[key] ?? r.cells[idx]?.dataset.sortValue ?? r.cells[idx]?.textContent.trim() ?? "";
      const cmp = (a, b) => { const x = val(a), y = val(b), nx = parseFloat(x), ny = parseFloat(y); const c = !isNaN(nx) && !isNaN(ny) ? nx - ny : x.localeCompare(y, undefined, { numeric: true }); return dir === "ascending" ? c : -c; };
      groups.forEach((g) => { g.rows.sort(cmp); if (g.head) body.appendChild(g.head); g.rows.forEach((r) => body.appendChild(r)); });
      emit(table, "sort", { key, dir });
    });
  });

  /* ── scrollspy ────────────────────────────────────────────────────────────── */
  // Scroll root = the .t-shell-main that holds the sections (the window when there is no shell). Active = the last
  // section whose top has passed the activation line (top of the scroller + a small offset); when the scroller sits at
  // its end the last section wins, so the final item of a group is reachable even when it shares the viewport with
  // the one before it. Passive scroll listener, one update per frame; the active link is kept in view in its sidebar.
  T.scrollspy = (nav = $(".t-sidebar"), sections) => {
    if (!nav) return;
    const links = new Map($$('a[href^="#"]', nav).map((a) => [a.getAttribute("href").slice(1), a]));
    sections = (sections || [...links.keys()].map((id) => document.getElementById(id))).filter(Boolean);
    if (!sections.length) return;
    const root = sections[0].closest(".t-shell-main"), scroller = root || window;
    const pad = root ? parseFloat(getComputedStyle(root).scrollPaddingTop) || 0 : 0;
    const line = () => (root ? root.getBoundingClientRect().top : 0) + pad + 8;
    const atEnd = () => root ? root.scrollTop + root.clientHeight >= root.scrollHeight - 2 : scrollY + innerHeight >= document.documentElement.scrollHeight - 2;
    const reveal = (a) => {
      const box = a.closest(".t-shell-side") || nav, r = a.getBoundingClientRect(), b = box.getBoundingClientRect();
      if (r.top < b.top || r.bottom > b.bottom) a.scrollIntoView({ block: "nearest" });
    };
    let cur = null, queued = false;
    const update = () => {
      queued = false;
      const shown = sections.filter((s) => s.offsetParent !== null); if (!shown.length) return;
      let active = shown[0];
      if (atEnd()) active = shown[shown.length - 1];
      else { const y = line(); shown.forEach((s) => { if (s.getBoundingClientRect().top <= y) active = s; }); }
      if (active === cur) return; cur = active;
      links.forEach((a, id) => { if (id === active.id) { a.setAttribute("aria-current", "page"); reveal(a); } else a.removeAttribute("aria-current"); });
    };
    const schedule = () => { if (!queued) { queued = true; requestAnimationFrame(update); } };
    on(scroller, "scroll", schedule, { passive: true });
    on(window, "resize", schedule, { passive: true });
    update();
  };

  /* ── popups shared by the drawn controls (select, pickers, menu, pinned help): one open at a time ── */
  let openPopup = null;
  T.popup = {
    // open(panel, trigger, close): positions `panel` under (or above) `trigger`, closes the previous one
    open(panel, trigger, close) {
      if (openPopup && openPopup.panel !== panel) openPopup.close();
      openPopup = { panel, trigger, close };
      panel.hidden = false;
      delete panel.dataset.align;
      const r = trigger.getBoundingClientRect(), h = panel.offsetHeight, w = panel.offsetWidth;
      panel.dataset.at = r.bottom + h + 8 > innerHeight && r.top - h - 8 > 0 ? "top" : "bottom";
      if (r.left + w > innerWidth - 8) panel.dataset.align = "end"; // long panel near the right edge: hang it off the trigger's right side
    },
    close() { if (openPopup) { const o = openPopup; openPopup = null; o.close(); } },
    current: () => openPopup,
  };
  on(document, "pointerdown", (e) => { if (openPopup && !openPopup.panel.contains(e.target) && !openPopup.trigger.contains(e.target)) T.popup.close(); });
  on(document, "keydown", (e) => { if (e.key === "Escape" && openPopup) { const t = openPopup.trigger; T.popup.close(); t.focus(); } });

  // Programmatic value changes on an upgraded control: Tailor.sync(el) refreshes what tailor draws for it.
  T.sync = (el) => emit(el, "sync");

  /* ── select: the native <select> stays for forms/value, tailor draws the button + list ── */
  T.selects = (root = document) => $$("select.t-select:not([multiple]):not([data-native])", root).forEach((sel) => {
    if (!mark(sel, "Select")) return;
    const wrap = document.createElement("span"); wrap.className = "t-select-wrap";
    if (sel.dataset.width) wrap.dataset.width = sel.dataset.width;
    const btn = document.createElement("button"); btn.type = "button"; btn.className = "t-select t-select-btn"; btn.setAttribute("aria-haspopup", "listbox"); btn.setAttribute("aria-expanded", "false");
    for (const a of ["data-size", "data-tip", "data-tip-at", "aria-label", "aria-describedby", "aria-invalid"]) if (sel.hasAttribute(a)) btn.setAttribute(a, sel.getAttribute(a));
    const list = document.createElement("ul"); list.className = "t-menu-list t-select-list"; list.setAttribute("role", "listbox"); list.hidden = true; list.tabIndex = -1;
    const id = sel.id || `t-sel-${Math.random().toString(36).slice(2, 8)}`; list.id = id + "-list"; btn.setAttribute("aria-controls", list.id);
    const lbl = sel.id && document.querySelector(`label[for="${sel.id}"]`); if (lbl) btn.setAttribute("aria-labelledby", lbl.id || (lbl.id = id + "-label"));
    sel.tabIndex = -1; sel.setAttribute("aria-hidden", "true"); sel.dataset.tSelectNative = "";
    sel.replaceWith(wrap); wrap.append(sel, btn, list);
    const options = () => $$("option", sel);
    const render = () => {
      const cur = sel.selectedOptions[0];
      btn.textContent = cur ? cur.textContent : (sel.dataset.placeholder || "\u00a0");
      btn.classList.toggle("t-select-placeholder", !cur || cur.value === "" && !!sel.dataset.placeholder);
      btn.disabled = sel.disabled;
      let html = "", group = null;
      options().forEach((o, i) => {
        if (o.parentElement.tagName === "OPTGROUP" && o.parentElement !== group) { group = o.parentElement; html += `<li class="t-menu-header">${esc(group.label)}</li>`; }
        html += `<li><button type="button" class="t-menu-item" role="option" id="${list.id}-${i}" data-index="${i}" aria-selected="${o.selected}"${o.disabled ? " disabled" : ""}>${esc(o.textContent)}</button></li>`;
      });
      list.innerHTML = html;
    };
    const items = () => $$("[role=option]:not(:disabled)", list);
    const close = () => { list.hidden = true; btn.setAttribute("aria-expanded", "false"); btn.removeAttribute("aria-activedescendant"); };
    const open = () => {
      if (sel.disabled) return;
      render(); T.popup.open(list, btn, close); btn.setAttribute("aria-expanded", "true");
      (items().find((b) => b.getAttribute("aria-selected") === "true") || items()[0])?.focus();
    };
    const pick = (i) => {
      if (sel.selectedIndex !== i) { sel.selectedIndex = i; sel.dispatchEvent(new Event("input", { bubbles: true })); sel.dispatchEvent(new Event("change", { bubbles: true })); }
      T.popup.close(); btn.focus(); render();
    };
    const step = (d) => { const os = options().filter((o) => !o.disabled), i = os.indexOf(sel.selectedOptions[0]); const n = os[Math.min(Math.max(i + d, 0), os.length - 1)]; if (n) pick(options().indexOf(n)); };
    let typed = "", typedAt = 0;
    const typeAhead = (key, from) => {
      const now = Date.now(); typed = now - typedAt < 600 ? typed + key : key; typedAt = now;
      const os = options(), start = typed.length > 1 ? from : from + 1;
      for (let k = 0; k < os.length; k++) { const o = os[(start + k) % os.length]; if (!o.disabled && o.textContent.trim().toLowerCase().startsWith(typed.toLowerCase())) return os.indexOf(o); }
      return -1;
    };
    on(btn, "click", () => (list.hidden ? open() : T.popup.close()));
    on(btn, "keydown", (e) => {
      if (e.key === "ArrowDown" || e.key === "ArrowUp") { e.preventDefault(); e.altKey ? open() : step(e.key === "ArrowDown" ? 1 : -1); }
      else if (e.key === " " || e.key === "Enter") { e.preventDefault(); open(); }
      else if (e.key.length === 1 && !e.ctrlKey && !e.metaKey) { const i = typeAhead(e.key, sel.selectedIndex); if (i >= 0) pick(i); }
    });
    on(list, "click", (e) => { const b = e.target.closest("[role=option]"); if (b && !b.disabled) pick(+b.dataset.index); });
    on(list, "keydown", (e) => {
      const its = items(), i = its.indexOf(document.activeElement);
      const go = (j) => { its[j].focus(); btn.setAttribute("aria-activedescendant", its[j].id); };
      if (e.key === "ArrowDown" || e.key === "ArrowUp") { e.preventDefault(); go((i + (e.key === "ArrowDown" ? 1 : -1) + its.length) % its.length); }
      else if (e.key === "Home" || e.key === "End") { e.preventDefault(); go(e.key === "Home" ? 0 : its.length - 1); }
      else if (e.key === "Enter" || e.key === " ") { e.preventDefault(); if (i >= 0) pick(+its[i].dataset.index); }
      else if (e.key === "Tab") { T.popup.close(); }
      else if (e.key.length === 1 && !e.ctrlKey && !e.metaKey) { const k = typeAhead(e.key, i >= 0 ? +its[i].dataset.index : -1); const b = k >= 0 && $(`[data-index="${k}"]`, list); if (b) go(its.indexOf(b)); }
    });
    on(sel, "change", render); on(sel, "t:sync", render);
    new MutationObserver(render).observe(sel, { childList: true, subtree: true, attributes: true, attributeFilter: ["disabled", "selected", "label"] });
    render();
  });

  /* ── number: native spinners hidden by base.css; tailor adds − / + steppers in a .t-input-group ── */
  T.numbers = (root = document) => $$('.t-input[type="number"]:not([data-steppers="none"])', root).forEach((input) => {
    if (!mark(input, "Number")) return;
    // reuse an enclosing .t-input-group (e.g. .t-duration) so the steppers fuse with the unit select; else wrap
    let group = input.parentElement?.classList.contains("t-input-group") ? input.parentElement : null;
    if (!group) { group = document.createElement("div"); group.className = "t-input-group"; if (input.dataset.size) group.dataset.size = input.dataset.size; input.replaceWith(group); group.appendChild(input); }
    group.classList.add("t-number");
    const mk = (dir) => { const b = document.createElement("button"); b.type = "button"; b.className = "t-btn t-number-step"; b.dataset.variant = "ghost"; b.dataset.icon = "only"; b.dataset.step = dir; b.tabIndex = -1; b.setAttribute("aria-label", dir > 0 ? "Increase" : "Decrease"); b.innerHTML = dir > 0 ? spriteIcon("bi-plus-lg", "+") : spriteIcon("bi-dash-lg", "−"); return b; };
    const minus = mk(-1), plus = mk(1);
    input.before(minus); input.after(plus);
    const num = (s, d) => { const n = parseFloat(s); return isNaN(n) ? d : n; };
    const bounds = () => ({ min: num(input.min, -Infinity), max: num(input.max, Infinity), step: input.step === "any" ? 1 : num(input.step, 1) || 1 });
    const paint = () => {
      const { min, max } = bounds(), v = num(input.value, NaN), off = input.disabled || input.readOnly;
      minus.disabled = off || (!isNaN(v) && v <= min); plus.disabled = off || (!isNaN(v) && v >= max);
    };
    const step = (dir) => {
      const { min, max, step } = bounds(); let v = num(input.value, NaN);
      if (isNaN(v)) v = Math.min(Math.max(0, min), max); else v += dir * step;
      v = Math.min(Math.max(v, min), max);
      const dec = Math.max((String(step).split(".")[1] || "").length, (input.value.split(".")[1] || "").length);
      const next = v.toFixed(dec); if (next === input.value) return paint();
      input.value = next; input.dispatchEvent(new Event("input", { bubbles: true })); input.dispatchEvent(new Event("change", { bubbles: true })); paint();
    };
    let hold, repeat;
    const stop = () => { clearTimeout(hold); clearInterval(repeat); hold = repeat = null; };
    [minus, plus].forEach((b) => {
      on(b, "pointerdown", (e) => { if (e.button !== 0 || b.disabled) return; e.preventDefault(); const d = +b.dataset.step; step(d); hold = setTimeout(() => { repeat = setInterval(() => (b.disabled ? stop() : step(d)), 60); }, 400); });
      ["pointerup", "pointerleave", "pointercancel"].forEach((ev) => on(b, ev, stop));
    });
    on(input, "input", paint); on(input, "change", paint); on(input, "t:sync", paint);
    new MutationObserver(paint).observe(input, { attributes: true, attributeFilter: ["min", "max", "step", "disabled", "readonly", "value"] });
    paint();
  });

  /* ── file: the native input stays (hidden) inside a .t-file label; tailor draws button + name or a drop zone ── */
  T.files = (root = document) => $$('.t-input[type="file"]', root).forEach((input) => {
    if (!mark(input, "File")) return;
    const label = document.createElement("label"); label.className = "t-file";
    const drop = input.dataset.variant === "drop"; if (drop) label.dataset.variant = "drop";
    if (input.dataset.size) label.dataset.size = input.dataset.size;
    const btn = document.createElement("span"); btn.className = "t-btn t-file-btn"; if (input.dataset.size) btn.dataset.size = input.dataset.size;
    btn.textContent = input.dataset.label || (input.multiple ? "Choose files…" : "Choose file…");
    const name = document.createElement("span"); name.className = "t-file-name";
    input.replaceWith(label); label.appendChild(input);
    if (drop) { const zone = document.createElement("span"); zone.className = "t-file-drop"; zone.append(btn, name); label.appendChild(zone); } else label.append(btn, name);
    const placeholder = () => input.dataset.placeholder || (drop ? "or drop it here" : "No file chosen");
    const render = () => {
      const fs = input.files ? [...input.files] : [];
      name.textContent = fs.length === 0 ? placeholder() : fs.length === 1 ? fs[0].name : `${fs.length} files`;
      if (fs.length) label.dataset.filled = ""; else delete label.dataset.filled;
    };
    const accepts = (f) => { const acc = (input.accept || "").split(",").map((s) => s.trim().toLowerCase()).filter(Boolean); if (!acc.length) return true; const ext = "." + f.name.split(".").pop().toLowerCase(), type = (f.type || "").toLowerCase(); return acc.some((a) => a === ext || a === type || (a.endsWith("/*") && type.startsWith(a.slice(0, -1)))); };
    on(label, "dragenter", (e) => { e.preventDefault(); if (!input.disabled) label.dataset.dragover = ""; });
    on(label, "dragover", (e) => { e.preventDefault(); if (!input.disabled) { e.dataTransfer.dropEffect = "copy"; label.dataset.dragover = ""; } });
    on(label, "dragleave", (e) => { if (!label.contains(e.relatedTarget)) delete label.dataset.dragover; });
    on(label, "drop", (e) => {
      e.preventDefault(); delete label.dataset.dragover; if (input.disabled) return;
      const picked = [...e.dataTransfer.files].filter(accepts); if (!picked.length) return;
      const dt = new DataTransfer(); (input.multiple ? picked : picked.slice(0, 1)).forEach((f) => dt.items.add(f));
      input.files = dt.files; input.dispatchEvent(new Event("input", { bubbles: true })); input.dispatchEvent(new Event("change", { bubbles: true }));
    });
    on(input, "change", render); on(input, "t:sync", render);
    render();
  });

  /* ── forms: drawn validation, no native bubbles ───────────────────────────── */
  // Every <form> without data-native-validation gets novalidate; on submit tailor runs checkValidity() per control,
  // sets aria-invalid, writes validationMessage into the control's .t-feedback[data-tone=danger] (created after the
  // control inside its .t-field when absent, linked with aria-describedby), focuses the first invalid control and
  // stops the submit. Clears on input/change; data-validate="live" on the form also validates on blur.
  const formControls = (form) => $$("input, select, textarea", form).filter((c) => c.willValidate && c.type !== "hidden");
  const feedbackFor = (c, create) => {
    const field = c.closest(".t-field");
    let fb = c._tFeedback?.isConnected ? c._tFeedback : field ? $(".t-feedback[data-tone=danger]", field) : null;
    if (!fb && create) {
      fb = document.createElement("p"); fb.className = "t-feedback"; fb.dataset.tone = "danger"; fb.hidden = true;
      const anchor = (field && [...field.children].find((ch) => ch.contains(c))) || c.closest(".t-check, .t-input-group, .t-duration") || c;
      anchor.after(fb);
    }
    if (fb) { if (!fb.id) fb.id = "t-fb-" + Math.random().toString(36).slice(2, 8); c._tFeedback = fb; }
    return fb;
  };
  const linkFeedback = (c, fb, link) => { const ids = (c.getAttribute("aria-describedby") || "").split(/\s+/).filter((x) => x && x !== fb.id); if (link) ids.push(fb.id); ids.length ? c.setAttribute("aria-describedby", ids.join(" ")) : c.removeAttribute("aria-describedby"); };
  const paintControl = (c, ok) => {
    if (ok) { c.removeAttribute("aria-invalid"); const fb = feedbackFor(c, false); if (fb) { fb.hidden = true; linkFeedback(c, fb, false); } return; }
    c.setAttribute("aria-invalid", "true");
    const fb = feedbackFor(c, true); fb.textContent = c.validationMessage; fb.hidden = false; linkFeedback(c, fb, true);
  };
  const validateControl = (c) => { const ok = c.checkValidity(); paintControl(c, ok); return ok; };
  // Tailor.validate(form) → boolean: paints every control, focuses the first invalid one, emits t:invalid {controls}.
  T.validate = (form) => {
    const bad = formControls(form).filter((c) => !validateControl(c));
    if (bad.length) { bad[0].focus(); emit(form, "invalid", { controls: bad }); }
    return !bad.length;
  };
  T.forms = (root = document) => $$("form", root).forEach((form) => {
    if (form.hasAttribute("data-native-validation") || !mark(form, "Form")) return;
    form.noValidate = true;
    on(form, "submit", (e) => { if (!T.validate(form)) { e.preventDefault(); e.stopImmediatePropagation(); } }, true);
    const clear = (e) => { const c = e.target; if (c.getAttribute?.("aria-invalid") === "true" && c.checkValidity()) paintControl(c, true); };
    on(form, "input", clear); on(form, "change", clear);
    if (form.dataset.validate === "live") on(form, "focusout", (e) => { const c = e.target; if (c.willValidate && c.form === form && (c.value !== "" || c.getAttribute("aria-invalid") === "true")) validateControl(c); });
  });

  /* ── pickers: date / time / colour (tier-2 date, time, color) ─────────────── */
  // Progressive enhancement over the native input: the input stays in the DOM (.t-picker-native, 1px, opacity 0) so
  // forms submit and .value works; a .t-input-styled button opens a .t-picker popup drawn from tokens (T.popup: one
  // open at a time, click outside / Escape close, flips above via data-at="top"). Picking sets input.value and fires
  // native input + change. Tailor.sync(input) repaints after a programmatic set.
  const pad2 = (n) => String(n).padStart(2, "0");
  const fire = (input, v) => { input.value = v; input.dispatchEvent(new Event("input", { bubbles: true })); input.dispatchEvent(new Event("change", { bubbles: true })); };
  const pickerWrap = (input, key, glyph) => {
    if (!mark(input, key)) return null;
    const wrap = document.createElement("span"); wrap.className = "t-picker-wrap"; if (input.dataset.width) wrap.dataset.width = input.dataset.width;
    const btn = document.createElement("button"); btn.type = "button"; btn.className = "t-input t-picker-btn";
    btn.setAttribute("aria-haspopup", "dialog"); btn.setAttribute("aria-expanded", "false"); btn.disabled = input.disabled;
    for (const a of ["data-size", "aria-label", "aria-describedby", "aria-invalid"]) if (input.hasAttribute(a)) btn.setAttribute(a, input.getAttribute(a));
    const id = input.id || `t-pick-${Math.random().toString(36).slice(2, 8)}`;
    const lbl = input.id && $(`label[for="${input.id}"]`); if (lbl) btn.setAttribute("aria-labelledby", lbl.id || (lbl.id = id + "-label"));
    btn.innerHTML = `<span class="t-picker-value"></span>${spriteIcon(...glyph)}`;
    const pop = document.createElement("div"); pop.className = "t-picker"; pop.id = id + "-picker"; pop.hidden = true; pop.setAttribute("role", "dialog"); pop.tabIndex = -1;
    if (lbl) pop.setAttribute("aria-labelledby", lbl.id); btn.setAttribute("aria-controls", pop.id);
    input.tabIndex = -1; input.setAttribute("aria-hidden", "true"); input.classList.add("t-picker-native");
    input.replaceWith(wrap); wrap.append(input, btn, pop);
    on(input, "focus", () => btn.focus());
    const hooks = {};
    const close = () => { pop.hidden = true; btn.setAttribute("aria-expanded", "false"); };
    const open = () => { if (input.disabled) return; hooks.render?.(); T.popup.open(pop, btn, close); btn.setAttribute("aria-expanded", "true"); hooks.focus?.(); emit(input, "open"); };
    const done = () => { T.popup.close(); btn.focus(); };
    on(btn, "click", () => (pop.hidden ? open() : T.popup.close()));
    on(btn, "keydown", (e) => { if (e.key === "ArrowDown" || e.key === "ArrowUp" || e.key === " ") { e.preventDefault(); open(); } });
    on(pop, "keydown", (e) => { // Tab past the last (or Shift+Tab before the first) focusable control leaves the popup
      if (e.key !== "Tab") return; const f = $$("button, input", pop).filter((el) => !el.disabled && el.tabIndex >= 0);
      if ((e.shiftKey && e.target === f[0]) || (!e.shiftKey && e.target === f[f.length - 1])) T.popup.close();
    });
    const paint = (text, empty) => { $(".t-picker-value", btn).textContent = text; empty ? (btn.dataset.empty = "") : delete btn.dataset.empty; };
    return { wrap, btn, pop, hooks, open, done, paint, isOpen: () => !pop.hidden };
  };

  const isoOf = (d) => `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}`;
  const parseISO = (s) => { const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(s || ""); return m ? new Date(+m[1], +m[2] - 1, +m[3]) : null; };
  const WEEKDAYS = [1, 2, 3, 4, 5, 6, 7].map((d) => new Date(2024, 0, d).toLocaleDateString(undefined, { weekday: "short" }).slice(0, 2)); // 2024-01-01 is a Monday
  T.dates = (root = document) => $$('.t-input[type="date"]', root).forEach((input) => {
    const p = pickerWrap(input, "Date", ["bi-chevron-down", "▾"]); if (!p) return;
    const { pop } = p; let view = null, focusIso = null;
    const paintBtn = () => p.paint(input.value || input.placeholder || "YYYY-MM-DD", !input.value);
    const inRange = (iso) => (!input.min || iso >= input.min) && (!input.max || iso <= input.max);
    const dayAt = (iso) => $(`.t-cal-day[data-date="${iso}"]`, pop);
    const render = () => {
      const sel = input.value, today = isoOf(new Date());
      if (!view) { const d = parseISO(sel) || new Date(); view = new Date(d.getFullYear(), d.getMonth(), 1); }
      const y = view.getFullYear(), m = view.getMonth(), ym = `${y}-${pad2(m + 1)}`, start = new Date(y, m, 1 - ((view.getDay() + 6) % 7));
      const title = view.toLocaleDateString(undefined, { month: "long", year: "numeric" });
      const focus = [focusIso, sel, today].find((x) => x && x.slice(0, 7) === ym) || ym + "-01";
      let cells = "";
      for (let i = 0; i < 42; i++) {
        const d = new Date(start.getFullYear(), start.getMonth(), start.getDate() + i), iso = isoOf(d);
        cells += `<button type="button" class="t-cal-day" role="gridcell" data-date="${iso}" aria-selected="${iso === sel}" tabindex="${iso === focus ? 0 : -1}"${d.getMonth() !== m ? " data-outside" : ""}${iso === today ? " data-today" : ""}${inRange(iso) ? "" : " disabled"}>${d.getDate()}</button>`;
      }
      pop.innerHTML = `<div class="t-cal-head"><button type="button" class="t-btn" data-variant="ghost" data-size="sm" data-icon="only" data-nav="-1" aria-label="Previous month">‹</button><span class="t-cal-title" aria-live="polite">${esc(title)}</span><button type="button" class="t-btn" data-variant="ghost" data-size="sm" data-icon="only" data-nav="1" aria-label="Next month">›</button></div>`
        + `<div class="t-cal-grid" role="grid" aria-label="${esc(title)}">${WEEKDAYS.map((w) => `<span class="t-cal-wd" aria-hidden="true">${esc(w)}</span>`).join("")}${cells}</div>`
        + `<div class="t-cal-foot"><button type="button" class="t-btn" data-variant="ghost" data-size="sm" data-act="today">Today</button><button type="button" class="t-btn" data-variant="ghost" data-size="sm" data-act="clear">Clear</button></div>`;
      return focus;
    };
    const show = (iso) => { const d = parseISO(iso); view = new Date(d.getFullYear(), d.getMonth(), 1); focusIso = iso; render(); dayAt(iso)?.focus(); };
    const pick = (iso) => { if (input.value !== iso) { fire(input, iso); paintBtn(); } p.done(); };
    const shift = (iso, days, months = 0) => { const d = parseISO(iso); if (months) { const day = d.getDate(); d.setDate(1); d.setMonth(d.getMonth() + months); d.setDate(Math.min(day, new Date(d.getFullYear(), d.getMonth() + 1, 0).getDate())); } d.setDate(d.getDate() + days); return isoOf(d); };
    p.hooks.render = () => { view = null; focusIso = null; render(); };
    p.hooks.focus = () => dayAt($(".t-cal-day[tabindex='0']", pop)?.dataset.date)?.focus();
    on(pop, "click", (e) => {
      const nav = e.target.closest("[data-nav]"), act = e.target.closest("[data-act]"), day = e.target.closest(".t-cal-day");
      if (nav) { view.setMonth(view.getMonth() + Number(nav.dataset.nav)); focusIso = null; render(); }
      else if (act) pick(act.dataset.act === "today" ? isoOf(new Date()) : "");
      else if (day && !day.disabled) pick(day.dataset.date);
    });
    on(pop, "keydown", (e) => {
      const day = e.target.closest(".t-cal-day"); if (!day) return;
      const iso = day.dataset.date, dow = (parseISO(iso).getDay() + 6) % 7;
      const next = { ArrowLeft: shift(iso, -1), ArrowRight: shift(iso, 1), ArrowUp: shift(iso, -7), ArrowDown: shift(iso, 7), PageUp: shift(iso, 0, -1), PageDown: shift(iso, 0, 1), Home: shift(iso, -dow), End: shift(iso, 6 - dow) }[e.key];
      if (next) { e.preventDefault(); show(next); }
      else if (e.key === "Enter" || e.key === " ") { e.preventDefault(); if (!day.disabled) pick(iso); }
    });
    on(input, "t:sync", () => { paintBtn(); if (p.isOpen()) p.hooks.render(); });
    paintBtn();
  });

  T.clocks = (root = document) => $$('.t-input[type="time"]', root).forEach((input) => {
    const p = pickerWrap(input, "Time", ["bi-clock", "◷"]); if (!p) return;
    const { pop } = p, step = Math.max(1, Number(input.step) || 300), secs = step < 60;
    const minStep = !secs && 60 % (step / 60) === 0 ? step / 60 : 1, secStep = secs && 60 % step === 0 ? step : 1;
    const range = (n, s) => Array.from({ length: Math.ceil(n / s) }, (_, i) => i * s);
    const cols = [["Hours", range(24, 1)], ["Minutes", range(60, minStep)], ...(secs ? [["Seconds", range(60, secStep)]] : [])];
    const parts = () => { const m = /^(\d{2}):(\d{2})(?::(\d{2}))?$/.exec(input.value); return m ? [+m[1], +m[2], +(m[3] || 0)] : null; };
    const paintBtn = () => p.paint(input.value || input.placeholder || (secs ? "HH:MM:SS" : "HH:MM"), !input.value);
    let pending = [0, 0, 0];
    const render = () => {
      pending = parts() || [0, 0, 0];
      pop.innerHTML = `<div class="t-clock">${cols.map(([name, vals], ci) => `<div class="t-clock-col" role="listbox" aria-label="${name}" data-col="${ci}">${vals.map((v) => `<button type="button" class="t-menu-item" role="option" data-value="${v}" aria-selected="${v === pending[ci]}" tabindex="${v === pending[ci] ? 0 : -1}">${pad2(v)}</button>`).join("")}</div>`).join("")}</div>`;
      $$(".t-clock-col", pop).forEach((col) => { const sel = $('[aria-selected="true"]', col); if (sel) col.scrollTop = sel.offsetTop - col.clientHeight / 2 + sel.offsetHeight / 2; });
    };
    const select = (col, opt) => { $$("[role=option]", col).forEach((o) => { const onIt = o === opt; o.setAttribute("aria-selected", onIt); o.tabIndex = onIt ? 0 : -1; }); pending[Number(col.dataset.col)] = Number(opt.dataset.value); opt.focus(); };
    const value = () => pending.slice(0, cols.length).map(pad2).join(":");
    const commit = (close) => { if (input.value !== value()) { fire(input, value()); paintBtn(); } if (close) p.done(); };
    p.hooks.render = render;
    p.hooks.focus = () => $('.t-clock-col [aria-selected="true"]', pop)?.focus();
    on(pop, "click", (e) => { const o = e.target.closest("[role=option]"); if (o) { select(o.parentNode, o); commit(false); } });
    on(pop, "keydown", (e) => {
      const o = e.target.closest("[role=option]"); if (!o) return;
      const col = o.parentNode, os = $$("[role=option]", col), i = os.indexOf(o);
      const n = { ArrowDown: i + 1, ArrowUp: i - 1, Home: 0, End: os.length - 1, PageDown: i + 5, PageUp: i - 5 }[e.key];
      if (n !== undefined) { e.preventDefault(); select(col, os[Math.max(0, Math.min(os.length - 1, n))]); }
      else if (e.key === "Enter") { e.preventDefault(); commit(true); }
      else if (e.key === " ") { e.preventDefault(); commit(false); }
      else if (e.key === "ArrowRight" || e.key === "ArrowLeft") { e.preventDefault(); $(`.t-clock-col[data-col="${Number(col.dataset.col) + (e.key === "ArrowRight" ? 1 : -1)}"] [aria-selected="true"]`, pop)?.focus(); }
    });
    on(input, "t:sync", () => { paintBtn(); if (p.isOpen()) render(); });
    paintBtn();
  });

  // palette swatches: the semantic tokens + every --t-hue-* on :root, resolved to #rrggbb through a probe element
  const HUES = ["red", "orange", "yellow", "green", "cyan", "purple", "pink", "blue", "teal", "magenta"];
  let probe;
  const toHex = (css) => {
    if (/^#[0-9a-f]{6}$/i.test(css)) return css.toLowerCase();
    if (!probe) { probe = document.createElement("span"); probe.className = "t-picker-native"; probe.setAttribute("aria-hidden", "true"); document.body.appendChild(probe); }
    probe.style.color = ""; probe.style.color = css;
    const n = (getComputedStyle(probe).color.match(/[\d.]+/g) || []).slice(0, 3).map((x) => pad2(Math.round(Number(x)).toString(16)));
    return n.length === 3 ? "#" + n.join("") : null;
  };
  const paletteTokens = () => {
    const names = ["accent", "success", "warning", "danger", "info"].map((n) => "--t-" + n), hues = new Set(HUES.map((h) => "--t-hue-" + h));
    try { for (const sh of document.styleSheets) for (const r of sh.cssRules || []) if (r.style && /(^|,)\s*(:root|html)\b/.test(r.selectorText || "")) for (const prop of r.style) if (prop.startsWith("--t-hue-")) hues.add(prop); } catch (_) {}
    const cs = getComputedStyle(html), out = [];
    for (const n of [...names, ...hues]) { // same value under two tokens (dracula accent = purple) → one dot, both names
      const v = cs.getPropertyValue(n).trim(); if (!v) continue; const hex = toHex(v); if (!hex) continue;
      const dup = out.find((t) => t.hex === hex); if (dup) dup.name += " · " + n.replace(/^--t-(hue-)?/, ""); else out.push({ name: n.replace(/^--t-(hue-)?/, ""), token: n, hex });
    }
    return out;
  };
  T.colors = (root = document) => $$('.t-input[type="color"]', root).forEach((input) => {
    const p = pickerWrap(input, "Color", ["bi-chevron-down", "▾"]); if (!p) return;
    const { pop, btn } = p, name = "t-color-" + Math.random().toString(36).slice(2, 8), withHex = input.dataset.hex !== "none";
    const sw = document.createElement("span"); sw.className = "t-swatch"; sw.setAttribute("aria-hidden", "true"); btn.prepend(sw);
    const current = () => (input.value || "#000000").toLowerCase();
    const paintBtn = () => { sw.style.setProperty("--t-tone", current()); p.paint(current(), false); };
    const render = () => {
      const tokens = paletteTokens(), cur = current(), hit = tokens.find((t) => t.hex === cur);
      pop.innerHTML = `<fieldset class="t-swatches"><legend class="t-visually-hidden">Palette</legend>${tokens.map((t) => `<label class="t-swatch" data-tip="${esc(t.name)}" style="--t-tone: var(${t.token})"><input type="radio" name="${name}" value="${t.hex}" aria-label="${esc(t.name)}"${t.hex === cur ? " checked" : ""}></label>`).join("")}</fieldset>`
        + `<div class="t-picker-name">${esc(hit ? hit.name : "custom")} <span class="t-mono">${esc(cur)}</span></div>`
        + (withHex ? `<div class="t-input-group t-picker-hex" data-size="sm"><span class="t-input-addon">#</span><input class="t-input" type="text" autocomplete="off" spellcheck="false" maxlength="6" pattern="[0-9a-fA-F]{6}" aria-label="Hex value" value="${esc(cur.slice(1))}"></div>` : "");
      T.tooltips(pop);
    };
    const pick = (hex, close) => { if (hex !== current()) { fire(input, hex); paintBtn(); } close ? p.done() : render(); };
    const applyHex = (field, close) => { const v = field.value.trim().replace(/^#/, ""); if (/^[0-9a-f]{6}$/i.test(v)) pick("#" + v.toLowerCase(), close); else field.setAttribute("aria-invalid", "true"); };
    p.hooks.render = render;
    p.hooks.focus = () => ($(".t-swatches input:checked", pop) || $(".t-swatches input", pop))?.focus();
    on(pop, "change", (e) => { const r = e.target.closest(".t-swatch input"); if (r) { pick(r.value, false); $(".t-swatches input:checked", pop)?.focus(); } const f = e.target.closest(".t-picker-hex .t-input"); if (f) applyHex(f, false); });
    on(pop, "click", (e) => { const l = e.target.closest(".t-swatch"); if (l && e.detail > 0) pick($("input", l).value, true); }); // detail 0 = the click a radio synthesises on arrow keys
    on(pop, "keydown", (e) => {
      if (e.target.closest(".t-swatch input") && (e.key === "Enter" || e.key === " ")) { e.preventDefault(); pick(e.target.value, true); }
      else if (e.target.closest(".t-picker-hex .t-input") && e.key === "Enter") { e.preventDefault(); applyHex(e.target, true); }
    });
    on(input, "t:sync", () => { paintBtn(); if (p.isOpen()) render(); });
    paintBtn();
  });

  /* ── upgrade: wire everything in root ─────────────────────────────────────── */
  T.upgrade = (root = document) => { ["tabs", "listbox", "menus", "dialogs", "times", "tooltips", "help", "copy", "truncate", "dismiss", "filters", "sortable", "selects", "numbers", "files", "forms", "dates", "clocks", "colors"].forEach((k) => T[k](root)); return T; };
  T.esc = esc;
  T.version = "0.7.1";
  window.Tailor = T;
  const me = document.currentScript;
  if (!me || me.dataset.tailor !== "manual") on(document, "DOMContentLoaded", () => T.upgrade(document));
})();
