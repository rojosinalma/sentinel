// standby-status page: polls /api/status every REFRESH_S, repaints, toasts on state changes.
(function () {
  const refreshMs = Math.max(2, Number(window.STANDBY.refreshS || 10)) * 1000;
  let previous = null;
  let failures = 0;

  const $ = (id) => document.getElementById(id);
  const esc = (s) => String(s == null ? '' : s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

  function toast(type, msg) {
    const icons = { success: 'check-circle-fill', warning: 'exclamation-triangle-fill', error: 'x-circle-fill' };
    const el = document.createElement('div');
    el.className = `toast-item toast-${type}`;
    el.innerHTML = `<i class="bi bi-${icons[type] || icons.error}"></i><span></span>`;
    el.querySelector('span').textContent = msg;
    $('toast-container').appendChild(el);
    setTimeout(() => { el.classList.add('leaving'); setTimeout(() => el.remove(), 300); }, 4000);
  }

  const fmtAgo = (iso) => {
    if (!iso) return '';
    const s = Math.max(0, Math.round((Date.now() - new Date(iso).getTime()) / 1000));
    if (s < 90) return `${s}s ago`;
    if (s < 5400) return `${Math.round(s / 60)}m ago`;
    if (s < 172800) return `${(s / 3600).toFixed(1)}h ago`;
    return `${Math.round(s / 86400)}d ago`;
  };
  const fmtDur = (s) => {
    s = Math.max(0, Math.round(s));
    if (s < 60) return `${s}s`;
    if (s < 3600) return `${Math.floor(s / 60)}m ${String(s % 60).padStart(2, '0')}s`;
    return `${Math.floor(s / 3600)}h ${String(Math.floor((s % 3600) / 60)).padStart(2, '0')}m`;
  };
  const upDown = (v) => v === 'up' ? 'val-ok' : v === 'down' ? 'val-bad' : 'val-muted';
  const dotClass = (state) => ({ up: 'running', ok: 'running', degraded: 'degraded', down: 'stopped', unreachable: 'stopped', timeout: 'stopped' }[state] || 'muted');

  function setDot(id, state) {
    const el = $(id); if (!el) return;
    el.className = `bi bi-circle-fill status-dot status-dot--${dotClass(state)} ms-auto`;
  }

  function svcCell(cell, svc, standby) {
    if (!svc) { cell.innerHTML = '<span class="val-muted">—</span>'; return; }
    let label = svc.state, cls = dotClass(svc.state), extra = '';
    if (svc.state === 'unconfigured') { label = 'not configured'; cls = 'muted'; }
    if (svc.state === 'down' && standby) { label = 'stopped (standby)'; cls = 'muted'; }
    if (svc.version) extra = `<span class="ver">${esc(svc.version)}</span>`;
    const title = svc.error ? `${svc.url || ''}\n${svc.error}` : (svc.note ? `${svc.url || ''}\n${svc.note}` : (svc.url || ''));
    cell.innerHTML = `<span class="svc" title="${esc(title)}"><i class="bi bi-circle-fill status-dot status-dot--${cls}"></i>${esc(label)}${extra}</span>`;
  }

  function timer(prefix, sinceIso, afterS, label) {
    const box = $(`timer-${prefix}`), text = $(`t-${prefix}-text`), bar = $(`t-${prefix}-bar`);
    if (!sinceIso) { box.classList.add('idle'); text.textContent = label || '—'; bar.style.width = '0%'; return; }
    box.classList.remove('idle');
    const elapsed = (Date.now() - new Date(sinceIso).getTime()) / 1000;
    const pct = afterS ? Math.min(100, Math.round(elapsed / afterS * 100)) : 0;
    text.textContent = afterS ? `${fmtDur(elapsed)} / ${fmtDur(afterS)}` : fmtDur(elapsed);
    bar.style.width = `${pct}%`;
    bar.style.background = pct >= 100 ? 'var(--drac-red)' : pct >= 60 ? 'var(--drac-orange)' : 'var(--drac-green)';
  }

  function render(d) {
    const sentinel = d.sentinel || {}; const doc = sentinel.doc || {};
    const mode = d.primary && d.primary.host;
    const standbyHost = mode === 'silver' ? 'tiny' : mode === 'tiny' ? 'silver' : null;

    // header
    $('generated').textContent = `${new Date(d.generated_at).toLocaleTimeString()} · ${d.took_ms} ms`;
    const pb = $('primary-badge');
    const known = mode && mode !== 'unknown';
    pb.className = `badge badge-tint badge-lg ${known ? (mode === 'silver' ? 'tint-green' : 'tint-orange') : 'tint-muted'}`;
    pb.querySelector('i').className = `bi bi-circle-fill status-dot status-dot--${known ? (mode === 'silver' ? 'running' : 'degraded') : 'muted'}`;
    $('primary-host').textContent = known ? mode : 'unknown';
    pb.title = `source: ${d.primary.source}`;
    $('primary-since').textContent = d.primary.since ? `since ${new Date(d.primary.since).toLocaleString()} (${fmtAgo(d.primary.since)})` : (sentinel.state === 'ok' ? 'since: n/a' : '');
    $('flag-hold').classList.toggle('d-none', !doc.hold);
    $('flag-promoting').classList.toggle('d-none', !doc.promoting);
    const tr = $('flag-transition');
    tr.classList.toggle('d-none', !doc.transition);
    tr.innerHTML = doc.transition ? `<i class="bi bi-arrow-left-right"></i> ${esc(doc.transition)}` : '';

    // sentinel
    setDot('sentinel-dot', sentinel.state === 'ok' ? 'ok' : 'unreachable');
    const sState = $('s-state');
    if (sentinel.state === 'ok') { sState.innerHTML = `<span class="val-ok">reachable</span> <span class="stat-sub">${esc(sentinel.url)} · ${sentinel.ms} ms · status age ${esc(doc.status_age_s)}s</span>`; }
    else if (sentinel.state === 'unconfigured') { sState.innerHTML = '<span class="val-muted">not configured</span>'; }
    else { sState.innerHTML = `<span class="val-bad">${esc(sentinel.state)}</span> <span class="stat-sub">${esc(sentinel.url || '')} · ${esc(sentinel.error || '')}</span>`; }
    $('s-mode').textContent = doc.mode ? `${doc.mode}${doc.tiny_stack ? ` · tiny stack ${doc.tiny_stack}` : ''}` : '—';
    $('s-silver-opencode').innerHTML = doc.silver_opencode ? `<span class="${upDown(doc.silver_opencode)}">${esc(doc.silver_opencode)}</span>${doc.silver_opencode_version ? ` <span class="stat-sub">${esc(doc.silver_opencode_version)}</span>` : ''}` : '—';
    $('s-silver-host').innerHTML = doc.silver_host ? `<span class="${upDown(doc.silver_host)}">${esc(doc.silver_host)}</span>${doc.silver_host_health ? ` <span class="stat-sub">${esc(doc.silver_host_health)}</span>` : ''}` : '—';
    $('s-quorum').innerHTML = doc.quorum ? `<span class="${upDown(doc.quorum)}">${esc(doc.quorum)}</span>` : '—';
    $('s-auto-promote').textContent = doc.auto_promote || '—';
    $('s-auto-failback').textContent = doc.auto_failback ? `${doc.auto_failback}${doc.hold ? ' (on hold)' : ''}` : '—';
    $('s-flips').textContent = doc.flips_in_window != null ? String(doc.flips_in_window) : '—';
    $('s-checked').textContent = doc.checked_at ? `${fmtAgo(doc.checked_at)}` : '—';
    timer('down', doc.down_since, doc.promote_after_s, doc.mode === 'silver' ? 'silver opencode up' : 'n/a');
    timer('stable', doc.silver_stable_since, doc.failback_after_s, doc.mode === 'tiny' ? 'silver not healthy yet' : 'n/a while silver is primary');
    const cd = [];
    if (doc.promote_cooldown_left_s) cd.push(`promote cooldown ${fmtDur(doc.promote_cooldown_left_s)} left`);
    if (doc.failback_retry_left_s) cd.push(`failback retry in ${fmtDur(doc.failback_retry_left_s)}`);
    $('s-cooldown').textContent = cd.join(' · ');

    // hosts
    ['silver', 'tiny'].forEach((h) => {
      const row = $(`host-${h}`); const data = (d.hosts || {})[h] || {};
      svcCell(row.querySelector('[data-svc=opencode]'), data.opencode, h === standbyHost);
      svcCell(row.querySelector('[data-svc=openchamber]'), data.openchamber, h === standbyHost);
    });

    // dns
    const dns = $('dns-facts'); dns.innerHTML = '';
    Object.entries(d.dns || {}).forEach(([name, r]) => {
      let val;
      if (r.state === 'cname') val = `<span class="${r.points_to ? (r.points_to === mode ? 'val-ok' : 'val-warn') : ''}">${esc(r.points_to || 'unknown tunnel')}</span> <span class="stat-sub">CNAME ${esc(r.target)}</span>`;
      else if (r.state === 'proxied') val = `<span class="${r.points_to ? 'val-ok' : 'val-muted'}">${esc(r.points_to || 'unknown')}</span> <span class="stat-sub">proxied (CF) · inferred from sentinel mode · ${esc((r.ips || []).join(', '))}</span>`;
      else val = `<span class="val-bad">${esc(r.state)}</span> <span class="stat-sub">${esc(r.error || '')}</span>`;
      dns.insertAdjacentHTML('beforeend', `<dt>${esc(name)}</dt><dd>${val}</dd>`);
    });

    // replica (tiny instance only)
    const t = d.tiny_root || {};
    if (t.state === 'ok') {
      const lag = (r) => !r ? '—' : r.state !== 'ok' ? `<span class="val-muted">${esc(r.state)}</span>` : `<span class="${r.lag_s > 900 ? 'val-bad' : r.lag_s > 120 ? 'val-warn' : 'val-ok'}">${fmtDur(r.lag_s)}</span> <span class="stat-sub">newest ${fmtAgo(r.newest_at)}</span>`;
      $('r-opencode').innerHTML = lag(t.replica.opencode);
      $('r-memory').innerHTML = lag(t.replica.memory);
      $('r-mode').innerHTML = `${esc(t.mode.value)} <span class="stat-sub">${t.mode.since ? `since ${fmtAgo(t.mode.since)}` : esc(t.mode.source)}</span>`;
      const worst = Math.max(...['opencode', 'memory'].map((k) => (t.replica[k] && t.replica[k].state === 'ok') ? t.replica[k].lag_s : 1e9));
      setDot('replica-dot', worst > 900 ? 'down' : worst > 120 ? 'degraded' : 'up');
      $('r-note').textContent = `lag = age of the newest file under ${t.root}/replica/*; silver's litestream writes there while silver is primary.`;
    } else {
      ['r-opencode', 'r-memory', 'r-mode'].forEach((id) => { $(id).innerHTML = `<span class="val-muted">${esc(t.note || t.error || t.state || 'n/a')}</span>`; });
      setDot('replica-dot', 'muted');
      $('r-note').textContent = t.state === 'n/a' ? `This instance has no TINY_ROOT; open the tiny instance for replica lag and logs.` : (t.error || '');
    }

    // last event
    const ev = t.last_event;
    if (ev) {
      $('e-meta').textContent = `${ev.kind} · ${ev.file} · ${new Date(ev.at).toLocaleString()} (${fmtAgo(ev.at)})`;
      $('e-tail').textContent = (ev.tail || []).join('\n') || '(empty log)';
    } else {
      $('e-meta').textContent = t.state === 'ok' ? 'no promote/demote log yet' : '';
      $('e-tail').textContent = t.state === 'ok' ? '(no promote-*.log or demote-*.log under logs/)' : (t.note || 'n/a on this instance');
    }
  }

  function diff(prev, cur) {
    if (!prev) return;
    const p = prev.primary.host, c = cur.primary.host;
    if (p !== c) toast(c === 'silver' ? 'success' : 'warning', `primary changed: ${p} → ${c}`);
    const ps = prev.sentinel.state === 'ok', cs = cur.sentinel.state === 'ok';
    if (ps !== cs) toast(cs ? 'success' : 'error', cs ? 'sentinel reachable again' : `sentinel ${cur.sentinel.state}`);
    const pd = (prev.sentinel.doc || {}), cd = (cur.sentinel.doc || {});
    if (!!pd.hold !== !!cd.hold) toast('warning', cd.hold ? 'hold set: failback paused' : 'hold released');
    if (!!pd.promoting !== !!cd.promoting) toast(cd.promoting ? 'warning' : 'success', cd.promoting ? 'promotion started' : 'promotion finished');
    if ((pd.transition || null) !== (cd.transition || null) && cd.transition) toast('warning', `transition: ${cd.transition}`);
    ['silver', 'tiny'].forEach((h) => ['opencode', 'openchamber'].forEach((s) => {
      const a = ((prev.hosts[h] || {})[s] || {}).state, b = ((cur.hosts[h] || {})[s] || {}).state;
      if (a && b && a !== b) toast(b === 'up' ? 'success' : 'warning', `${h} ${s}: ${a} → ${b}`);
    }));
    Object.keys(cur.dns || {}).forEach((n) => {
      const a = (prev.dns[n] || {}).points_to, b = (cur.dns[n] || {}).points_to;
      if (a && b && a !== b) toast('warning', `${n} now points to ${b}`);
    });
  }

  async function tick() {
    try {
      const r = await fetch('/api/status', { cache: 'no-store', headers: { Accept: 'application/json' } });
      if (!r.ok) throw new Error(`HTTP ${r.status}`);
      const d = await r.json();
      if (!d.ok) throw new Error(d.message || 'not ok');
      if (failures > 0) toast('success', 'status refresh recovered');
      failures = 0;
      $('stale').classList.add('d-none');
      diff(previous, d);
      render(d);
      previous = d;
    } catch (e) {
      failures += 1;
      $('stale').classList.remove('d-none');
      if (failures === 1) toast('error', `status refresh failed: ${e.message}`);
    }
  }

  tick();
  setInterval(tick, refreshMs);
  setInterval(() => { if (previous) render(previous); }, 1000); // keep the timers ticking between polls
  document.addEventListener('visibilitychange', () => { if (!document.hidden) tick(); });
  window.appToast = toast;
  window.appEsc = esc;
  window.appFmtAgo = fmtAgo;
  window.appFmtDur = fmtDur;
})();

// sentinel cluster view: polls /api/sentinel + events/transitions on instances that run the
// sentinel (NODE_NAME set); a 503 means this is a plain status instance and the row stays hidden.
(function () {
  const refreshMs = Math.max(2, Number(window.STANDBY.refreshS || 10)) * 1000;
  const $ = (id) => document.getElementById(id);
  const esc = window.appEsc, toast = window.appToast, fmtAgo = window.appFmtAgo;
  let enabled = null; // null = unknown yet
  let holdBusy = false;

  const classTint = { ok: 'val-ok', standby: 'val-muted', degraded: 'val-warn', dead: 'val-bad', isolated: 'val-warn' };
  const kindTint = {
    'decision': 'tint-orange', 'transition.start': 'tint-orange', 'transition.end': 'tint-purple',
    'lease.grant': 'tint-cyan', 'lease.deny': 'tint-red', 'class.change': 'tint-yellow',
    'notify': 'tint-pink', 'hold': 'tint-yellow', 'boot': 'tint-green', 'heartbeat': 'tint-muted'
  };

  async function getJSON(url) {
    const r = await fetch(url, { cache: 'no-store', headers: { Accept: 'application/json' } });
    if (r.status === 503) { enabled = false; return null; }
    if (!r.ok) throw new Error(`HTTP ${r.status}`);
    return r.json();
  }

  async function post(url, data) {
    const body = new URLSearchParams();
    Object.entries(data || {}).forEach(([k, v]) => body.append(k, v));
    const r = await fetch(url, { method: 'POST', body });
    return r.json();
  }

  function renderCluster(d) {
    $('sn-row').classList.remove('d-none');
    $('sn-node').textContent = `${d.node}${d.acting ? ' · acting node' : ''}`;
    $('sn-acting').textContent = d.acting ? '' : `read-only: acting node is ${d.standby}`;
    $('flag-quorum').classList.toggle('d-none', d.quorum === 'up');

    const rows = Object.entries(d.hosts || {}).map(([name, h]) => {
      const cls = (d.classes || {})[name] || '?';
      const probes = ['ssh', 'icmp', 'traefik'].filter((p) => h[p])
        .map((p) => `<span class="${h[p] === 'up' ? 'val-ok' : 'val-bad'}" title="${p}">${p}</span>`).join(' ');
      const st = (h.services || {})[d.service];
      const svc = st ? `<span class="${st.startsWith('up') ? 'val-ok' : 'val-bad'}">${esc(st)}</span>` : '<span class="val-muted">—</span>';
      const peer = name === d.node ? '<span class="val-muted">self</span>'
        : (d.reachable_peers || []).includes(name) ? '<span class="val-ok">reachable</span>' : '<span class="val-bad">unreachable</span>';
      const role = (d.roles || {})[name] === 'witness' ? ' <span class="stat-sub">witness</span>' : '';
      return `<tr><th>${esc(name)}${role}</th><td><span class="${classTint[cls] || 'val-muted'}">${esc(cls)}</span> ${svc}</td><td>${probes}</td><td>${peer}</td></tr>`;
    });
    $('sn-cluster').innerHTML = rows.join('');
    $('sn-quorum').innerHTML = `quorum <span class="${d.quorum === 'up' ? 'val-ok' : 'val-bad'}">${esc(d.quorum)}</span> · agreed class of ${esc(Object.keys(d.hosts || {})[0] || 'primary')}: <span class="${classTint[d.agreed_class] || ''}">${esc(d.agreed_class)}</span>${d.busy ? ' · <span class="val-warn">transition in progress</span>' : ''}`;
    $('sn-lease').textContent = d.lease
      ? `lease: ${d.lease.holder} ${d.lease.action} until ${d.lease.expires_at}`
      : 'lease: none';
    const routes = [];
    if (d.route_primary) routes.push(`routes → ${d.route_primary}`);
    if (d.ha_connectors != null) routes.push(`${d.ha_connectors} tunnel connectors`);
    if (d.tiny_stack) routes.push(`stack ${d.tiny_stack}`);
    $('sn-routes').textContent = routes.join(' · ');

    if (!holdBusy) $('sn-hold-switch').checked = !!d.hold;
    ['sn-promote', 'sn-demote', 'sn-promote-dry', 'sn-demote-dry'].forEach((id) => {
      $(id).disabled = !d.acting || d.busy || !!d.action_running;
    });
  }

  function renderEvents(events) {
    const rows = (events || []).filter((e) => e.kind !== 'heartbeat').slice(0, 15).map((e) =>
      `<tr><td class="text-nowrap stat-sub" title="${esc(e.at)}">${fmtAgo(e.at)}</td>` +
      `<td class="text-nowrap"><span class="badge badge-tint ${kindTint[e.kind] || 'tint-muted'}">${esc(e.kind)}</span></td>` +
      `<td>${esc(e.message)}</td></tr>`);
    $('sn-events').innerHTML = rows.join('');
    $('sn-events-empty').classList.toggle('d-none', rows.length > 0);
    $('sn-events-meta').textContent = rows.length ? `${rows.length} shown · heartbeats hidden` : '';
  }

  function renderTransitions(transitions) {
    const rows = (transitions || []).slice(0, 6).map((t) => {
      const ok = t.result === 'ok';
      const dur = t.data && t.data.duration_s ? ` · ${t.data.duration_s}s` : '';
      return `<dt>${esc(t.action)}</dt><dd><span class="${ok ? 'val-ok' : 'val-bad'}">${esc(t.result || 'running…')}</span>` +
        `<span class="stat-sub"> ${fmtAgo(t.started_at)}${dur} · ${esc(t.node || '')}</span></dd>`;
    });
    $('sn-transitions').innerHTML = rows.join('');
    $('sn-transitions-empty').classList.toggle('d-none', rows.length > 0);
  }

  async function tick() {
    if (enabled === false) return;
    try {
      const d = await getJSON('/api/sentinel');
      if (!d) return;
      enabled = true;
      renderCluster(d);
      const [ev, tr] = await Promise.all([getJSON('/api/events?limit=40'), getJSON('/api/transitions?limit=6')]);
      if (ev) renderEvents(ev.events);
      if (tr) renderTransitions(tr.transitions);
    } catch (e) { /* the stale badge of the main poller covers it */ }
  }

  // ---- actions
  const modal = () => bootstrap.Modal.getOrCreateInstance($('sn-modal'));

  function openConfirm(action) {
    $('sn-modal-title').textContent = `Confirm ${action}`;
    $('sn-modal-text').textContent = action === 'demote'
      ? 'Hands the primary back: stops the standby pair, restores the reverse replica onto the primary and starts it. Type the word to confirm.'
      : 'Makes the standby primary: fences the current primary, restores the replica and starts the standby pair. Type the word to confirm.';
    const input = $('sn-modal-input');
    input.classList.remove('d-none'); input.value = ''; input.placeholder = action;
    $('sn-modal-output').classList.add('d-none');
    const go = $('sn-modal-go');
    go.classList.remove('d-none'); go.disabled = true; go.dataset.action = action;
    input.oninput = () => { go.disabled = input.value.trim() !== action; };
    modal().show();
    setTimeout(() => input.focus(), 300);
  }

  function openOutput(title, text) {
    $('sn-modal-title').textContent = title;
    $('sn-modal-text').textContent = '';
    $('sn-modal-input').classList.add('d-none');
    $('sn-modal-go').classList.add('d-none');
    const out = $('sn-modal-output');
    out.classList.remove('d-none'); out.textContent = text;
    modal().show();
  }

  document.querySelectorAll('#sn-promote, #sn-demote, #sn-promote-dry, #sn-demote-dry').forEach((btn) => {
    btn.addEventListener('click', async () => {
      const action = btn.dataset.action;
      if (btn.dataset.dry) {
        btn.disabled = true;
        try {
          const res = await post(`/api/${action}`, { dry_run: 'true' });
          openOutput(`${action} --dry-run`, res.message || '(no output)');
        } finally { btn.disabled = false; }
      } else {
        openConfirm(action);
      }
    });
  });

  $('sn-modal-go').addEventListener('click', async () => {
    const action = $('sn-modal-go').dataset.action;
    $('sn-modal-go').disabled = true;
    const data = { confirm: action };
    const res = await post(`/api/${action}`, data);
    modal().hide();
    toast(res.ok ? 'warning' : 'error', res.message);
    tick();
  });

  $('sn-hold-switch').addEventListener('change', async (e) => {
    holdBusy = true;
    try {
      const res = await post('/api/hold', { on: e.target.checked ? 'true' : 'false' });
      toast(res.ok ? (e.target.checked ? 'warning' : 'success') : 'error', res.message);
      if (!res.ok) e.target.checked = !e.target.checked;
    } finally { holdBusy = false; }
  });

  tick();
  setInterval(tick, refreshMs);
})();
