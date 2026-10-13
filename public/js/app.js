// sentinel dashboard: one poller on /api/v1/status (the generic multi-service document) plus
// /api/events and /api/transitions; one card per service, actions per card. Nothing here knows
// a host or service by name — everything comes from the document.
(function () {
  const refreshMs = Math.max(2, Number(window.STANDBY.refreshS || 10)) * 1000;
  const $ = (id) => document.getElementById(id);
  const esc = (s) => String(s == null ? '' : s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

  let previous = null;   // last /api/v1/status document
  let failures = 0;
  let enabled = null;    // null = unknown, false = this instance runs no sentinel (503)
  const holdBusy = new Set();

  // ---------------------------------------------------------------- helpers

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
  const classTint = { ok: 'val-ok', standby: 'val-muted', degraded: 'val-warn', dead: 'val-bad', isolated: 'val-warn' };
  const kindTint = {
    'decision': 'tint-orange', 'transition.start': 'tint-orange', 'transition.end': 'tint-purple',
    'lease.grant': 'tint-cyan', 'lease.deny': 'tint-red', 'class.change': 'tint-yellow',
    'notify': 'tint-pink', 'hold': 'tint-yellow', 'boot': 'tint-green', 'heartbeat': 'tint-muted'
  };

  // Role of a host within one service: primary (green) / standby (yellow) / down (red).
  function hostRole(svc, hostName, hostDoc) {
    const cls = ((hostDoc || {}).classes || {})[svc.name];
    const state = ((hostDoc || {}).services || {})[svc.name];
    const current = svc.mode === hostName;
    if (cls === 'dead' || cls === 'isolated' || (current && state === 'down')) return { label: current ? 'primary · down' : 'down', tint: 'red', dot: 'stopped' };
    if (current) return { label: 'primary', tint: 'green', dot: 'running' };
    return { label: 'standby', tint: 'yellow', dot: 'degraded' };
  }

  // Route primary of one service: per-service field, else the document-level Hash or String.
  function routeFor(d, name) {
    const svc = (d.services || {})[name] || {};
    if (svc.route_primary) return svc.route_primary;
    const rp = d.route_primary;
    return rp && typeof rp === 'object' ? rp[name] : rp;
  }
  const routesSummary = (d) => Object.keys(d.services || {}).map((n) => [n, routeFor(d, n)]).filter(([, r]) => r && r !== 'n/a');

  function serviceCell(state) {
    if (!state) return '<span class="val-muted">—</span>';
    const up = String(state).startsWith('up');
    const ver = up ? String(state).slice(3).trim() : '';
    return `<span class="svc"><i class="bi bi-circle-fill status-dot status-dot--${up ? 'running' : 'stopped'}"></i>${up ? 'up' : esc(state)}${ver ? `<span class="ver">${esc(ver)}</span>` : ''}</span>`;
  }

  function timer(card, prefix, sinceIso, afterS, label, idleLabel) {
    const f = (n) => card.querySelector(`[data-f="timer-${prefix}${n}"]`);
    const box = f(''), text = f('-text'), bar = f('-bar');
    f('-label').textContent = label;
    if (!sinceIso) { box.classList.add('idle'); text.textContent = idleLabel || '—'; bar.style.width = '0%'; bar.className = 'progress-bar'; return; }
    box.classList.remove('idle');
    const elapsed = (Date.now() - new Date(sinceIso).getTime()) / 1000;
    const pct = afterS ? Math.min(100, Math.round(elapsed / afterS * 100)) : 0;
    text.textContent = afterS ? `${fmtDur(elapsed)} / ${fmtDur(afterS)}` : fmtDur(elapsed);
    bar.style.width = `${pct}%`;
    bar.className = `progress-bar ${pct >= 100 ? 'bar-red' : pct >= 60 ? 'bar-orange' : 'bar-green'}`;
  }

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

  // ---------------------------------------------------------------- cards

  function cardFor(name) {
    const id = `svc-${name}`;
    let col = $(id);
    if (col) return col.querySelector('.service-card');
    col = $('service-card-tpl').content.firstElementChild.cloneNode(true);
    col.id = id;
    const card = col.querySelector('.service-card');
    card.dataset.service = name;
    card.querySelector('[data-f="name"]').textContent = name;
    wireActions(card, name);
    $('services-row').appendChild(col);
    return card;
  }

  function renderService(d, name, svc) {
    svc = { ...svc, name };
    const card = cardFor(name);
    const f = (key) => card.querySelector(`[data-f="${key}"]`);
    const hosts = d.hosts || {};
    const known = svc.mode && svc.mode !== 'unknown';
    const onConfigured = known && svc.mode === svc.primary;

    // header badge: who is primary; green on the configured primary, orange when failed over
    const badge = f('mode-badge');
    badge.className = `badge badge-tint ms-auto ${known ? (onConfigured ? 'tint-green' : 'tint-orange') : 'tint-muted'}`;
    badge.querySelector('i').className = `bi bi-circle-fill status-dot status-dot--${known ? (onConfigured ? 'running' : 'degraded') : 'muted'}`;
    badge.title = onConfigured ? 'running on its configured primary' : known ? `failed over to ${svc.mode} (configured primary: ${svc.primary})` : 'primary unknown';
    f('mode').textContent = known ? svc.mode : 'unknown';
    f('since').textContent = svc.since ? `primary since ${new Date(svc.since).toLocaleString()} (${fmtAgo(svc.since)})` : (d.note ? d.note : 'since: n/a');

    // hosts of this service, coloured by role
    const rows = [svc.primary, svc.standby].filter(Boolean).map((h) => {
      const hd = hosts[h];
      const role = hostRole(svc, h, hd);
      const cls = ((hd || {}).classes || {})[name];
      const configured = h === svc.primary ? 'configured primary' : 'configured standby';
      return `<tr class="host-${role.tint}"><th><i class="bi bi-circle-fill status-dot status-dot--${role.dot}"></i> ${esc(h)}</th>` +
        `<td><span class="badge badge-tint tint-${role.tint}" title="${esc(configured)}">${esc(role.label)}</span></td>` +
        `<td>${serviceCell(((hd || {}).services || {})[name])}</td>` +
        `<td><span class="${classTint[cls] || 'val-muted'}">${esc(cls || (hd ? '—' : 'no view'))}</span></td></tr>`;
    });
    f('hosts').innerHTML = rows.join('');

    // facts
    f('agreed').innerHTML = svc.agreed_class
      ? `<span class="${classTint[svc.agreed_class] || ''}">${esc(svc.agreed_class)}</span>${svc.classification && svc.classification !== svc.agreed_class ? ` <span class="stat-sub">local ${esc(svc.classification)}</span>` : ''}${svc.busy ? ' · <span class="val-warn">transition in progress</span>' : ''}`
      : '<span class="val-muted">—</span>';
    const lease = svc.lease;
    f('lease').innerHTML = lease
      ? `<span class="val-warn">${esc(lease.holder)}</span> <span class="stat-sub">${esc(lease.action || '')} · until ${new Date(lease.expires_at).toLocaleTimeString()}</span>`
      : '<span class="val-muted">none</span>';
    f('hold').innerHTML = svc.hold
      ? '<span class="val-warn">on</span> <span class="stat-sub">automatic failback paused</span>'
      : `<span class="val-ok">off</span>${d.tunables && d.tunables.auto_failback ? ` <span class="stat-sub">auto failback ${esc(d.tunables.auto_failback)}</span>` : ''}`;
    const lt = svc.last_transition;
    f('last-transition').innerHTML = lt
      ? `${esc(lt.action)} <span class="${lt.result === 'ok' ? 'val-ok' : lt.result ? 'val-bad' : 'val-warn'}">${esc(lt.result || 'running…')}</span> <span class="stat-sub">${fmtAgo(lt.started_at)}${lt.data && lt.data.duration_s ? ` · ${esc(lt.data.duration_s)}s` : ''}${lt.node ? ` · ${esc(lt.node)}` : ''}</span>`
      : '<span class="val-muted">none recorded</span>';
    const rp = svc.route_primary;
    f('routes').innerHTML = rp
      ? `<span class="${rp === svc.mode ? 'val-ok' : rp === 'unknown' ? 'val-muted' : 'val-warn'}">→ ${esc(rp)}</span>${d.ha_connectors != null ? ` <span class="stat-sub">${esc(d.ha_connectors)} tunnel connectors</span>` : ''}`
      : '<span class="val-muted">—</span>';
    f('acting').innerHTML = `${esc(svc.standby)}${svc.acting ? ' <span class="stat-sub">(this node)</span>' : ' <span class="stat-sub">(actions forwarded there)</span>'}${svc.standby_stack ? ` · <span class="stat-sub">stack ${esc(svc.standby_stack)}</span>` : ''}`;

    // decider timers
    const g = svc.gates || {}, t = d.tunables || {};
    timer(card, 'down', g.down_since, t.promote_after_s, `${svc.primary} down`, onConfigured ? `${svc.primary} ${name} up` : 'n/a');
    timer(card, 'stable', g.stable_since, g.failback_after_s || t.failback_after_s, `${svc.primary} stable`, onConfigured ? `n/a while ${svc.primary} is primary` : `${svc.primary} not healthy yet`);
    const cd = [];
    if (g.promote_cooldown_left_s) cd.push(`promote cooldown ${fmtDur(g.promote_cooldown_left_s)} left`);
    if (g.promote_retry_left_s) cd.push(`promote retry in ${fmtDur(g.promote_retry_left_s)}`);
    if (g.failback_retry_left_s) cd.push(`failback retry in ${fmtDur(g.failback_retry_left_s)}`);
    if (g.flips_in_window) cd.push(`${g.flips_in_window} flips in window`);
    if (g.dead_polls) cd.push(`${g.dead_polls} dead polls`);
    f('cooldown').textContent = cd.join(' · ');

    // replica block only when the document carries replica info for the service
    const rep = svc.replica;
    f('replica').classList.toggle('d-none', !rep);
    if (rep) {
      f('replica-value').innerHTML = Object.entries(rep).map(([k, r]) => {
        if (!r || typeof r !== 'object') return `${esc(k)} <span class="val-muted">${esc(r)}</span>`;
        const cls = r.lag_s > 900 ? 'val-bad' : r.lag_s > 120 ? 'val-warn' : 'val-ok';
        return `${esc(k)} <span class="${cls}">${r.lag_s != null ? fmtDur(r.lag_s) : esc(r.state || '—')}</span>`;
      }).join(' · ');
    }

    // actions: any node's page may act; a non-acting node forwards to the acting one
    const sw = f('hold-switch');
    if (!holdBusy.has(name)) sw.checked = !!svc.hold;
    sw.disabled = false;
    const locked = svc.busy || !!svc.action_running;
    card.querySelectorAll('[data-action]').forEach((b) => { b.disabled = locked; });
    f('actions-note').textContent = svc.action_running ? `${svc.action_running} running via the api…`
      : svc.busy ? `transition in progress${svc.transition ? ` (${svc.transition})` : ''}`
        : svc.acting ? 'Transitions run the service hooks under a majority lease; follow them in the events.'
          : `Transitions are forwarded to the acting node (${svc.standby}) and run its hooks under a majority lease.`;
  }

  function wireActions(card, name) {
    card.querySelectorAll('[data-action]').forEach((btn) => {
      btn.addEventListener('click', async () => {
        const action = btn.dataset.action;
        if (btn.dataset.dry) {
          btn.disabled = true;
          try {
            const res = await post(`/api/${action}`, { dry_run: 'true', service: name });
            $('output-title').textContent = `${name}: ${action} --dry-run`;
            $('output-text').textContent = res.message || '(no output)';
            bootstrap.Modal.getOrCreateInstance($('output-modal')).show();
            if (!res.ok) toast('error', res.message);
          } catch (e) { toast('error', `${action} --dry-run failed: ${e.message}`); }
          finally { btn.disabled = false; }
          return;
        }
        const svc = ((previous || {}).services || {})[name] || {};
        const body = action === 'demote'
          ? `Hands <b>${esc(name)}</b> back to <b>${esc(svc.primary)}</b>: stops the stack on ${esc(svc.standby)}, restores the reverse replica onto ${esc(svc.primary)} and starts it there.`
          : `Makes <b>${esc(svc.standby)}</b> primary for <b>${esc(name)}</b>: fences ${esc(svc.primary)}, restores the replica and starts the stack on ${esc(svc.standby)}.`;
        const ok = await confirmThen(`${action} ${name}?`, `${body}<div class="stat-sub mt-2">Runs the ${esc(name)}/${esc(action)} hook under a majority lease.</div>`, null, { label: action });
        if (!ok) return;
        btn.disabled = true;
        try {
          const res = await post(`/api/${action}`, { confirm: action, service: name });
          toast(res.ok ? 'warning' : 'error', res.message);
        } catch (e) { toast('error', `${action} failed: ${e.message}`); }
        tick();
      });
    });

    card.querySelector('[data-f="hold-switch"]').addEventListener('change', async (e) => {
      const on = e.target.checked;
      holdBusy.add(name);
      try {
        const res = await post('/api/hold', { on: on ? 'true' : 'false', service: name });
        toast(res.ok ? (on ? 'warning' : 'success') : 'error', res.message);
        if (!res.ok) e.target.checked = !on;
      } catch (err) { toast('error', `hold failed: ${err.message}`); e.target.checked = !on; }
      finally { holdBusy.delete(name); }
      tick();
    });
  }

  // ---------------------------------------------------------------- cluster header + hosts

  function renderCluster(d) {
    $('node-name').textContent = d.node;
    document.title = `sentinel · ${d.node}`;
    const q = $('flag-quorum');
    q.className = `badge badge-tint badge-lg ${d.quorum === 'up' ? 'tint-green' : d.quorum ? 'tint-red' : 'tint-muted'}`;
    $('quorum-value').textContent = d.quorum || 'no cycle yet';
    const peers = d.reachable_peers || [];
    const hostNames = Object.keys(d.hosts || {});
    const others = hostNames.filter((h) => h !== d.node);
    const pf = $('flag-peers');
    pf.className = `badge badge-tint ${others.length && peers.length === others.length ? 'tint-green' : peers.length ? 'tint-yellow' : 'tint-muted'}`;
    $('peers-value').textContent = others.length ? `${peers.length}/${others.length}${d.majority ? ` · majority ${d.majority}` : ''}` : '—';
    pf.title = peers.length ? `reachable: ${peers.join(', ')}` : 'no peer reachable';
    $('flag-hold').classList.toggle('d-none', !d.hold);
    const tr = $('flag-transition');
    tr.classList.toggle('d-none', !d.transition);
    tr.innerHTML = d.transition ? `<i class="bi bi-arrow-repeat"></i> ${esc(d.transition)}` : '';
    const rf = $('flag-routes');
    const routeList = Object.entries(d.route_primary || {}).filter(([, h]) => h && h !== 'n/a').map(([s, h]) => `${esc(s)} → ${esc(h)}`);
    rf.classList.toggle('d-none', !routeList.length);
    rf.innerHTML = routeList.length ? `<i class="bi bi-signpost-split"></i> routes ${routeList.join(' · ')}${d.ha_connectors != null ? ` · ${esc(d.ha_connectors)} connectors` : ''}` : '';
    $('cluster-meta').textContent = d.at ? `cycle ${fmtAgo(d.at)}` : (d.note || '');
    $('generated').textContent = `${new Date().toLocaleTimeString()}${d.status_age_s != null ? ` · status age ${d.status_age_s}s` : ''}`;

    const svcNames = Object.keys(d.services || {});
    const body = hostNames.map((h) => {
      const hd = d.hosts[h] || {};
      const probes = Object.entries(hd.probes || {}).filter(([, v]) => v)
        .map(([p, v]) => `<span class="${upDown(v)}" title="${esc(p)} ${esc(v)}">${esc(p)}</span>`).join(' ');
      const peer = h === d.node ? '<span class="val-muted">self</span>'
        : peers.includes(h) ? '<span class="val-ok">reachable</span>' : '<span class="val-bad">unreachable</span>';
      const roles = svcNames.filter((s) => d.services[s].primary === h || d.services[s].standby === h)
        .map((s) => `${s}: ${d.services[s].primary === h ? 'primary' : 'standby'}`);
      const role = hd.role === 'witness' ? '<span class="badge badge-tint tint-purple">witness</span>' : `<span class="stat-sub">${esc(roles.join(', ') || hd.role || '—')}</span>`;
      return `<tr><th>${esc(h)}</th><td>${role}</td><td>${probes || '<span class="val-muted">—</span>'}</td><td>${peer}</td></tr>`;
    });
    $('hosts-body').innerHTML = body.join('');
    $('hosts-empty').classList.toggle('d-none', body.length > 0);
    $('hosts-meta').textContent = hostNames.length ? `${hostNames.length} hosts · ${svcNames.length} service${svcNames.length === 1 ? '' : 's'}` : '';
  }

  function render(d) {
    renderCluster(d);
    const names = Object.keys(d.services || {});
    names.forEach((n) => renderService(d, n, d.services[n]));
    // drop cards of services that left the document
    document.querySelectorAll('#services-row > [id^="svc-"]').forEach((col) => {
      if (!names.includes(col.id.slice(4))) col.remove();
    });
  }

  function renderEvents(events) {
    const rows = (events || []).filter((e) => e.kind !== 'heartbeat').slice(0, 15).map((e) =>
      `<tr><td class="text-nowrap stat-sub" title="${esc(e.at)}">${fmtAgo(e.at)}</td>` +
      `<td class="text-nowrap"><span class="badge badge-tint ${kindTint[e.kind] || 'tint-muted'}">${esc(e.kind)}</span></td>` +
      `<td>${e.service ? `<span class="stat-sub">${esc(e.service)} · </span>` : ''}${esc(e.message)}</td></tr>`);
    $('events').innerHTML = rows.join('');
    $('events-empty').classList.toggle('d-none', rows.length > 0);
    $('events-meta').textContent = rows.length ? `${rows.length} shown · heartbeats hidden` : '';
  }

  function renderTransitions(transitions) {
    const rows = (transitions || []).slice(0, 6).map((t) => {
      const ok = t.result === 'ok';
      const dur = t.data && t.data.duration_s ? ` · ${t.data.duration_s}s` : '';
      return `<dt>${esc(t.service)} ${esc(t.action)}</dt><dd><span class="${ok ? 'val-ok' : t.result ? 'val-bad' : 'val-warn'}">${esc(t.result || 'running…')}</span>` +
        `<span class="stat-sub"> ${fmtAgo(t.started_at)}${dur} · ${esc(t.node || '')}</span></dd>`;
    });
    $('transitions').innerHTML = rows.join('');
    $('transitions-empty').classList.toggle('d-none', rows.length > 0);
  }

  // ---------------------------------------------------------------- state-change toasts

  function diff(prev, cur) {
    if (!prev) return;
    if ((prev.quorum || null) !== (cur.quorum || null) && cur.quorum) toast(cur.quorum === 'up' ? 'success' : 'error', `quorum ${cur.quorum}`);
    if (!!prev.hold !== !!cur.hold) toast('warning', cur.hold ? 'hold set: failback paused' : 'hold released');
    if ((prev.transition || null) !== (cur.transition || null) && cur.transition) toast('warning', `transition: ${cur.transition}`);
    Object.entries(cur.route_primary || {}).forEach(([name, host]) => {
      const was = (prev.route_primary || {})[name] || null;
      if (was !== host && host && host !== 'n/a') toast('warning', `${name}: routes now point to ${host}`);
    });
    Object.entries(cur.services || {}).forEach(([name, s]) => {
      const p = (prev.services || {})[name]; if (!p) return;
      if (p.mode !== s.mode) toast(s.mode === s.primary ? 'success' : 'warning', `${name}: primary ${p.mode} → ${s.mode}`);
      if (!!p.busy !== !!s.busy) toast(s.busy ? 'warning' : 'success', s.busy ? `${name}: transition started` : `${name}: transition finished`);
      if ((p.agreed_class || null) !== (s.agreed_class || null) && s.agreed_class) toast(s.agreed_class === 'ok' ? 'success' : 'warning', `${name}: ${s.primary} is ${s.agreed_class}`);
      [s.primary, s.standby].forEach((h) => {
        const a = (((prev.hosts || {})[h] || {}).services || {})[name], b = (((cur.hosts || {})[h] || {}).services || {})[name];
        if (a && b && a !== b) toast(String(b).startsWith('up') ? 'success' : 'warning', `${h} ${name}: ${a} → ${b}`);
      });
    });
  }

  // ---------------------------------------------------------------- poller

  async function tick() {
    if (enabled === false) return;
    try {
      const d = await getJSON('/api/v1/status');
      if (!d) { $('disabled-state').classList.remove('d-none'); return; }
      if (!d.ok) throw new Error(d.message || 'not ok');
      enabled = true;
      if (failures > 0) toast('success', 'status refresh recovered');
      failures = 0;
      $('stale').classList.add('d-none');
      diff(previous, d);
      render(d);
      previous = d;
      const [ev, tr] = await Promise.all([getJSON('/api/events?limit=40'), getJSON('/api/transitions?limit=6')]);
      if (ev) renderEvents(ev.events);
      if (tr) renderTransitions(tr.transitions);
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
})();

// The house confirm modal (web-ui-design skill, assets/reference/confirm.js).
function confirmThen(title, bodyHtml, onOk, { label = 'Confirm', danger = true } = {}) {
  const el = document.getElementById('confirm-modal');
  const ok = el.querySelector('#confirm-ok');
  const h = el.querySelector('#confirm-title');
  h.className = 'modal-title' + (danger ? ' text-danger' : '');
  h.innerHTML = `<i class="bi ${danger ? 'bi-exclamation-triangle' : 'bi-question-circle'} me-2"></i><span></span>`;
  h.lastChild.textContent = title;
  el.querySelector('#confirm-body').innerHTML = bodyHtml;
  ok.textContent = label;
  ok.className = 'btn ' + (danger ? 'btn-danger' : 'btn-primary');
  const modal = bootstrap.Modal.getOrCreateInstance(el);
  return new Promise((resolve) => {
    let confirmed = false;
    ok.onclick = () => { confirmed = true; modal.hide(); };
    el.addEventListener('hidden.bs.modal', () => { ok.onclick = null; if (confirmed && onOk) onOk(); resolve(confirmed); }, { once: true });
    modal.show();
  });
}
