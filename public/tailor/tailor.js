/* managed by tailor v0.6.0 — core — do not edit, run `tailor sync` */
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

  /* ── theme: skin × palette × mode ─────────────────────────────────────────── */
  const html = document.documentElement;
  const theme = {
    project: "tailor", skins: ["none"], palettes: ["dracula"], modes: { dracula: ["dark", "light"] }, defaults: { skin: "none", palette: "dracula", mode: "dark" },
    key: (k) => `${theme.project}.${k}`,
    store: (k, v) => { try { localStorage.setItem(theme.key(k), v); } catch (_) {} },
    read: (k) => { try { return localStorage.getItem(theme.key(k)); } catch (_) { return null; } },
    get: () => ({ skin: html.dataset.skin || theme.defaults.skin, palette: html.dataset.palette || theme.defaults.palette, mode: html.dataset.mode || theme.defaults.mode, choice: html.dataset.modeChoice || html.dataset.mode || theme.defaults.mode }),
    resolveMode(choice, palette) {
      const modes = theme.modes[palette] || ["dark"];
      let m = choice === "auto" ? (matchMedia("(prefers-color-scheme: light)").matches ? "light" : "dark") : choice;
      return modes.includes(m) ? m : modes[0];
    },
    set({ skin, palette, mode } = {}, { persist = true } = {}) {
      const cur = theme.get();
      if (skin !== undefined && theme.skins.includes(skin)) { html.dataset.skin = skin; if (persist) theme.store("skin", skin); }
      if (palette !== undefined && theme.palettes.includes(palette)) { html.dataset.palette = palette; if (persist) theme.store("palette", palette); }
      if (mode !== undefined && /^(dark|light|auto)$/.test(mode)) { html.dataset.modeChoice = mode; if (persist) theme.store("mode", mode); }
      const next = theme.get();
      html.dataset.mode = theme.resolveMode(next.choice, next.palette);
      const ls = $("#t-skin"); if (ls) { ls.href = next.skin === "none" ? "" : ls.dataset.base + next.skin + "/skin.css"; ls.disabled = next.skin === "none"; }
      const lp = $("#t-palette"); if (lp) lp.href = lp.dataset.base + next.palette + ".css";
      theme.paintPickers();
      if (cur.skin !== next.skin || cur.palette !== next.palette || cur.mode !== html.dataset.mode) emit(html, "theme", theme.get());
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
        b.title = b.getAttribute("aria-label");
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
      const labels = (theme.labels || {})[what === "skin" ? "skins" : "palettes"] || {};
      if (what === "mode") return [["dark", "Dark"], ["light", "Light"]];
      const ids = (what === "skin" ? theme.skins : theme.palettes).filter((id) => id !== "none");
      const rows = ids.map((id) => [id, labels[id] || id]).sort((a, b) => a[1].localeCompare(b[1], undefined, { sensitivity: "base" }));
      if (what === "skin" && theme.skins.includes("none")) rows.push(["none", "No skin"]);
      return rows;
    },
    fillPicker(sel, what) {
      sel.innerHTML = theme.options(what).map(([v, l]) => `<option value="${esc(v)}">${esc(l)}</option>`).join("");
    },
    // <div data-tailor-pickers> → sun/moon toggle + skin + palette selects (selects only when there is a choice).
    // data-tailor-pickers="mode" | "skin palette" | … limits the parts (settings page gets the selects, footer the toggle).
    renderPickers(root = document) {
      $$("[data-tailor-pickers]", root).forEach((box) => {
        if (!mark(box, "Pickers")) return;
        const want = (box.dataset.tailorPickers || "mode skin palette").split(/\s+/);
        const parts = [];
        if (want.includes("mode")) parts.push(`<button type="button" class="t-btn" data-variant="ghost" data-size="sm" data-icon="only" data-tailor-mode-toggle></button>`);
        if (want.includes("skin") && theme.skins.filter((s) => s !== "none").length > 1) parts.push(`<select class="t-select" data-size="sm" data-tailor-picker="skin" aria-label="Skin" title="Skin"></select>`);
        if (want.includes("palette") && theme.palettes.length > 1) parts.push(`<select class="t-select" data-size="sm" data-tailor-picker="palette" aria-label="Palette" title="Palette"></select>`);
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
      theme.set({ skin: pick("skin"), palette: pick("palette"), mode: pick("mode") }, { persist: false });
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
  const ICONS = { success: "✓", warning: "▲", danger: "✕", info: "ⓘ" };
  T.toast = (tone, msg, { timeout = 2500 } = {}) => {
    if (tone === "error") tone = "danger";
    let region = $("#t-toasts");
    if (!region) { region = document.createElement("div"); region.id = "t-toasts"; region.className = "t-toasts"; region.setAttribute("aria-live", "polite"); region.setAttribute("aria-atomic", "false"); document.body.appendChild(region); }
    const el = document.createElement("div");
    el.className = "t-toast"; el.dataset.tone = tone; el.setAttribute("role", "status");
    el.innerHTML = `<span class="t-icon t-toast-icon" aria-hidden="true">${ICONS[tone] || ""}</span><span class="t-toast-body"></span>`;
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
    on(m, "click", (e) => {
      const it = e.target.closest(".t-menu-item"); if (!it) return;
      if (it.getAttribute("role") === "menuitemcheckbox") { it.setAttribute("aria-checked", it.getAttribute("aria-checked") !== "true"); emit(m, "change", { item: it }); }
      else m.removeAttribute("open");
    });
  });
  on(document, "click", (e) => $$("details.t-menu[open]").forEach((m) => { if (!m.contains(e.target)) m.removeAttribute("open"); }));
  on(document, "keydown", (e) => { if (e.key === "Escape") $$("details.t-menu[open]").forEach((m) => m.removeAttribute("open")); });

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
    const icon = $(".t-icon", h); if (icon) icon.textContent = danger ? "▲" : "?";
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
      t.textContent = T.relativeTime(d); if (!t.title) t.title = d.toLocaleString();
    });
    paint(); if (!T.times._timer) T.times._timer = setInterval(paint, 60000);
  };

  /* ── tooltips ─────────────────────────────────────────────────────────────── */
  let tip;
  const showTip = (el) => {
    if (!tip) { tip = document.createElement("div"); tip.className = "t-tooltip"; tip.id = "t-tooltip"; tip.setAttribute("role", "tooltip"); tip.hidden = true; document.body.appendChild(tip); }
    tip.textContent = el.dataset.tip; tip.hidden = false; el.setAttribute("aria-describedby", "t-tooltip");
    const r = el.getBoundingClientRect(), w = tip.offsetWidth, h = tip.offsetHeight, at = el.dataset.tipAt || "top", g = 6;
    let x = r.left + r.width / 2 - w / 2, y = r.top - h - g;
    if (at === "bottom") y = r.bottom + g; if (at === "left") { x = r.left - w - g; y = r.top + r.height / 2 - h / 2; } if (at === "right") { x = r.right + g; y = r.top + r.height / 2 - h / 2; }
    tip.style.left = Math.max(4, Math.min(innerWidth - w - 4, x)) + "px"; tip.style.top = Math.max(4, y) + "px";
  };
  const hideTip = (el) => { if (tip) tip.hidden = true; el?.removeAttribute("aria-describedby"); };
  T.tooltips = (root = document) => $$("[data-tip]", root).forEach((el) => {
    if (!mark(el, "Tip")) return;
    on(el, "mouseenter", () => showTip(el)); on(el, "mouseleave", () => hideTip(el));
    on(el, "focus", () => showTip(el)); on(el, "blur", () => hideTip(el));
  });

  /* ── help popover ─────────────────────────────────────────────────────────── */
  T.help = (root = document) => $$(".t-help", root).forEach((h) => {
    if (!mark(h, "Help")) return;
    const b = $(".t-help-btn", h), box = $(".t-help-box", h); if (!b || !box) return;
    if (!box.id) box.id = "t-help-" + Math.random().toString(36).slice(2, 8); b.setAttribute("aria-controls", box.id);
    let t;
    const open = (pin) => { box.hidden = false; b.setAttribute("aria-expanded", "true"); if (pin) box.dataset.pinned = ""; };
    const close = () => { box.hidden = true; delete box.dataset.pinned; b.setAttribute("aria-expanded", "false"); };
    h._tClose = close;
    on(b, "click", (e) => { e.stopPropagation(); clearTimeout(t); box.dataset.pinned !== undefined ? close() : open(true); });
    on(b, "mouseenter", () => { t = setTimeout(() => { if (box.hidden) open(false); }, 1000); });
    on(b, "mouseleave", () => { clearTimeout(t); setTimeout(() => { if (box.dataset.pinned === undefined && !box.matches(":hover")) close(); }, 200); });
    on(box, "mouseleave", () => { if (box.dataset.pinned === undefined) close(); });
    on(box, "click", (e) => e.stopPropagation());
  });
  on(document, "click", () => $$(".t-help").forEach((h) => h._tClose?.()));
  on(document, "keydown", (e) => { if (e.key === "Escape") $$(".t-help").forEach((h) => h._tClose?.()); });

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
  T.scrollspy = (nav = $(".t-sidebar"), sections) => {
    if (!nav || !("IntersectionObserver" in window)) return;
    const links = new Map($$('a[href^="#"]', nav).map((a) => [a.getAttribute("href").slice(1), a]));
    sections = sections || [...links.keys()].map((id) => document.getElementById(id)).filter(Boolean);
    const io = new IntersectionObserver((entries) => {
      const hit = entries.find((e) => e.isIntersecting); if (!hit) return;
      links.forEach((a, id) => (id === hit.target.id ? a.setAttribute("aria-current", "page") : a.removeAttribute("aria-current")));
    }, { rootMargin: "-80px 0px -60% 0px" });
    sections.forEach((s) => io.observe(s));
  };

  /* ── upgrade: wire everything in root ─────────────────────────────────────── */
  T.upgrade = (root = document) => { ["tabs", "listbox", "menus", "dialogs", "times", "tooltips", "help", "copy", "truncate", "dismiss", "filters", "sortable"].forEach((k) => T[k](root)); return T; };
  T.esc = esc;
  T.version = "0.4.0";
  window.Tailor = T;
  const me = document.currentScript;
  if (!me || me.dataset.tailor !== "manual") on(document, "DOMContentLoaded", () => T.upgrade(document));
})();
