// sentinel dashboard: one poller on /api/v1/status (the generic multi-service document) plus
// /api/events and /api/transitions; one card per service, actions per card. Nothing here knows
// a host or service by name — everything comes from the document. Markup emitted at runtime is
// tailor vocabulary only (t-badge, t-dot, t-tone-text, t-stat-*, t-progress-bar); feedback goes
// through Tailor.toast / Tailor.confirm and the native <dialog> elements in index.erb.
(function () {
  const refreshMs = Math.max(2, Number(window.SENTINEL.refreshS || 10)) * 1000;
  const toastMs = 4000;
  const $ = (id) => document.getElementById(id);
  const esc = (s) => String(s == null ? '' : s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

  let previous = null;   // last /api/v1/status document
  let failures = 0;
  let enabled = null;    // null = unknown, false = this instance runs no sentinel (503)
  const holdBusy = new Set();

  // ---------------------------------------------------------------- helpers

  const toast = (tone, msg) => Tailor.toast(tone, msg, { timeout: toastMs });

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

  // tailor markup emitters; icons come from the vendored sprite (public/tailor/icons.svg, subset by `tailor apply --icons`)
  const icon = (name, cls) => `<svg class="t-icon${cls ? ` ${cls}` : ''}" aria-hidden="true"><use href="/tailor/icons.svg#bi-${name}"/></svg>`;
  const tone = (t, html) => t === 'neutral' ? `<span class="t-muted">${html}</span>` : `<span class="t-tone-text" data-tone="${t}">${html}</span>`;
  const sub = (html) => `<span class="t-stat-sub">${html}</span>`;
  const badge = (t, html, title) => `<span class="t-badge" data-variant="tint" data-tone="${t}"${title ? ` title="${esc(title)}"` : ''}>${html}</span>`;
  const dot = (status, title) => `<span class="t-dot" data-status="${status}"${title ? ` title="${esc(title)}"` : ''}></span>`;
  const setBadge = (el, t) => { el.className = 't-badge'; el.dataset.variant = 'tint'; el.dataset.tone = t; };
  const NONE = tone('neutral', '—');

  const upDown = (v) => v === 'up' ? 'success' : v === 'down' ? 'danger' : 'neutral';
  const classTone = { ok: 'success', standby: 'neutral', degraded: 'warning', dead: 'danger', isolated: 'warning' };
  const kindTone = {
    'decision': 'warning', 'transition.start': 'warning', 'transition.end': 'accent',
    'lease.grant': 'info', 'lease.deny': 'danger', 'class.change': 'yellow',
    'notify': 'pink', 'hold': 'yellow', 'boot': 'success', 'heartbeat': 'neutral'
  };

  // Role of a host within one service: primary (green) / standby (yellow) / down (red).
  function hostRole(svc, hostName, hostDoc) {
    const cls = ((hostDoc || {}).classes || {})[svc.name];
    const state = ((hostDoc || {}).services || {})[svc.name];
    const current = svc.mode === hostName;
    if (cls === 'dead' || cls === 'isolated' || (current && state === 'down')) return { label: current ? 'primary · down' : 'down', role: 'down', tone: 'danger', dot: 'stopped' };
    if (current) return { label: 'primary', role: 'primary', tone: 'success', dot: 'running' };
    return { label: 'standby', role: 'standby', tone: 'yellow', dot: 'degraded' };
  }

  function serviceCell(state) {
    if (!state) return NONE;
    const up = String(state).startsWith('up');
    const ver = up ? String(state).slice(3).trim() : '';
    return `<span class="svc">${dot(up ? 'running' : 'stopped')}${up ? 'up' : esc(state)}${ver ? `<span class="ver">${esc(ver)}</span>` : ''}</span>`;
  }

  function timer(card, prefix, sinceIso, afterS, label, idleLabel) {
    const f = (n) => card.querySelector(`[data-f="timer-${prefix}${n}"]`);
    const box = f(''), text = f('-text'), bar = f('-bar'), track = bar.parentElement;
    f('-label').textContent = label;
    const paint = (pct, t) => { bar.style.setProperty('--t-value', `${pct}%`); bar.dataset.tone = t; track.setAttribute('aria-valuenow', pct); };
    if (!sinceIso) { box.dataset.idle = ''; text.textContent = idleLabel || '—'; paint(0, 'success'); return; }
    delete box.dataset.idle;
    const elapsed = (Date.now() - new Date(sinceIso).getTime()) / 1000;
    const pct = afterS ? Math.min(100, Math.round(elapsed / afterS * 100)) : 0;
    text.textContent = afterS ? `${fmtDur(elapsed)} / ${fmtDur(afterS)}` : fmtDur(elapsed);
    paint(pct, pct >= 100 ? 'danger' : pct >= 60 ? 'warning' : 'success');
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
    const mb = f('mode-badge');
    setBadge(mb, known ? (onConfigured ? 'success' : 'warning') : 'neutral');
    mb.querySelector('.t-dot').dataset.status = known ? (onConfigured ? 'running' : 'degraded') : 'muted';
    mb.title = onConfigured ? 'running on its configured primary' : known ? `failed over to ${svc.mode} (configured primary: ${svc.primary})` : 'primary unknown';
    f('mode').textContent = known ? svc.mode : 'unknown';
    const link = f('url');
    link.hidden = !svc.url;
    if (svc.url) { link.href = svc.url; link.title = `Open ${name} (${svc.url})`; }
    f('since').textContent = svc.since ? `primary since ${new Date(svc.since).toLocaleString()} (${fmtAgo(svc.since)})` : (d.note ? d.note : 'since: n/a');

    // hosts of this service, coloured by role
    const rows = [svc.primary, svc.standby].filter(Boolean).map((h) => {
      const hd = hosts[h];
      const role = hostRole(svc, h, hd);
      const cls = ((hd || {}).classes || {})[name];
      const configured = h === svc.primary ? 'configured primary' : 'configured standby';
      const hu = (svc.host_urls || {})[h];
      const hostCell = hu ? `<a href="${esc(hu)}" target="_blank" rel="noopener" title="Open ${esc(name)} on ${esc(h)}">${esc(h)} ${icon('box-arrow-up-right', 't-muted')}</a>` : esc(h);
      return `<tr data-role="${role.role}"><th class="t-nowrap">${dot(role.dot)} ${hostCell}</th>` +
        `<td>${badge(role.tone, esc(role.label), configured)}</td>` +
        `<td>${serviceCell(((hd || {}).services || {})[name])}</td>` +
        `<td>${tone(classTone[cls] || 'neutral', esc(cls || (hd ? '—' : 'no view')))}</td></tr>`;
    });
    f('hosts').innerHTML = rows.join('');

    // facts
    f('agreed').innerHTML = svc.agreed_class
      ? `${tone(classTone[svc.agreed_class] || 'text', esc(svc.agreed_class))}${svc.classification && svc.classification !== svc.agreed_class ? ` ${sub(`local ${esc(svc.classification)}`)}` : ''}${svc.busy ? ` · ${tone('warning', 'transition in progress')}` : ''}`
      : NONE;
    const lease = svc.lease;
    f('lease').innerHTML = lease
      ? `${tone('warning', esc(lease.holder))} ${sub(`${esc(lease.action || '')} · until ${new Date(lease.expires_at).toLocaleTimeString()}`)}`
      : tone('neutral', 'none');
    f('hold').innerHTML = svc.hold
      ? `${tone('warning', 'on')} ${sub('automatic failback paused')}`
      : `${tone('success', 'off')}${d.tunables && d.tunables.auto_failback ? ` ${sub(`auto failback ${esc(d.tunables.auto_failback)}`)}` : ''}`;
    const lt = svc.last_transition;
    f('last-transition').innerHTML = lt
      ? `${esc(lt.action)} ${tone(lt.result === 'ok' ? 'success' : lt.result ? 'danger' : 'warning', esc(lt.result || 'running…'))} ${sub(`${fmtAgo(lt.started_at)}${lt.data && lt.data.duration_s ? ` · ${esc(lt.data.duration_s)}s` : ''}${lt.node ? ` · ${esc(lt.node)}` : ''}`)}`
      : tone('neutral', 'none recorded');
    const rp = svc.route_primary;
    f('routes').innerHTML = rp
      ? `${tone(rp === svc.mode ? 'success' : rp === 'unknown' ? 'neutral' : 'warning', `→ ${esc(rp)}`)}${d.ha_connectors != null ? ` ${sub(`${esc(d.ha_connectors)} tunnel connectors`)}` : ''}`
      : NONE;
    f('acting').innerHTML = `${esc(svc.standby)} ${sub(svc.acting ? '(this node)' : '(actions forwarded there)')}${svc.standby_stack ? ` · ${sub(`stack ${esc(svc.standby_stack)}`)}` : ''}`;

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
    f('replica').hidden = !rep;
    if (rep) {
      f('replica-value').innerHTML = Object.entries(rep).map(([k, r]) => {
        if (!r || typeof r !== 'object') return `${esc(k)} ${tone('neutral', esc(r))}`;
        const t = r.lag_s > 900 ? 'danger' : r.lag_s > 120 ? 'warning' : 'success';
        return `${esc(k)} ${tone(t, r.lag_s != null ? fmtDur(r.lag_s) : esc(r.state || '—'))}`;
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

  function showOutput(title, text) {
    $('output-title').textContent = title;
    $('output-text').textContent = text;
    const dlg = $('output-modal');
    if (!dlg.open) dlg.showModal();
  }

  function wireActions(card, name) {
    card.querySelectorAll('[data-action]').forEach((btn) => {
      btn.addEventListener('click', async () => {
        const action = btn.dataset.action;
        if (btn.dataset.dry) {
          btn.disabled = true;
          try {
            const res = await post(`/api/${action}`, { dry_run: 'true', service: name });
            showOutput(`${name}: ${action} --dry-run`, res.message || '(no output)');
            if (!res.ok) toast('danger', res.message);
          } catch (e) { toast('danger', `${action} --dry-run failed: ${e.message}`); }
          finally { btn.disabled = false; }
          return;
        }
        const svc = ((previous || {}).services || {})[name] || {};
        const body = action === 'demote'
          ? `Hands <b>${esc(name)}</b> back to <b>${esc(svc.primary)}</b>: stops the stack on ${esc(svc.standby)}, restores the reverse replica onto ${esc(svc.primary)} and starts it there.`
          : `Makes <b>${esc(svc.standby)}</b> primary for <b>${esc(name)}</b>: fences ${esc(svc.primary)}, restores the replica and starts the stack on ${esc(svc.standby)}.`;
        const ok = await Tailor.confirm(`${action} ${name}?`, `${body}<div class="t-stat-sub confirm-note">Runs the ${esc(name)}/${esc(action)} hook under a majority lease.</div>`, { label: action });
        if (!ok) return;
        btn.disabled = true;
        try {
          const res = await post(`/api/${action}`, { confirm: action, service: name });
          toast(res.ok ? 'warning' : 'danger', res.message);
        } catch (e) { toast('danger', `${action} failed: ${e.message}`); }
        tick();
      });
    });

    card.querySelector('[data-f="hold-switch"]').addEventListener('change', async (e) => {
      const on = e.target.checked;
      holdBusy.add(name);
      try {
        const res = await post('/api/hold', { on: on ? 'true' : 'false', service: name });
        toast(res.ok ? (on ? 'warning' : 'success') : 'danger', res.message);
        if (!res.ok) e.target.checked = !on;
      } catch (err) { toast('danger', `hold failed: ${err.message}`); e.target.checked = !on; }
      finally { holdBusy.delete(name); }
      tick();
    });
  }

  // ---------------------------------------------------------------- cluster header + hosts

  function renderCluster(d) {
    $('node-name').textContent = d.node;
    document.title = `sentinel · ${d.node}`;
    const q = $('flag-quorum');
    setBadge(q, d.quorum === 'up' ? 'success' : d.quorum ? 'danger' : 'neutral');
    q.dataset.size = 'lg';
    $('quorum-value').textContent = d.quorum || 'no cycle yet';
    const peers = d.reachable_peers || [];
    const hostNames = Object.keys(d.hosts || {});
    const others = hostNames.filter((h) => h !== d.node);
    const pf = $('flag-peers');
    setBadge(pf, others.length && peers.length === others.length ? 'success' : peers.length ? 'yellow' : 'neutral');
    $('peers-value').textContent = others.length ? `${peers.length}/${others.length}${d.majority ? ` · majority ${d.majority}` : ''}` : '—';
    pf.title = peers.length ? `reachable: ${peers.join(', ')}` : 'no peer reachable';
    $('flag-hold').hidden = !d.hold;
    const tr = $('flag-transition');
    tr.hidden = !d.transition;
    tr.innerHTML = d.transition ? `${icon('arrow-repeat')} ${esc(d.transition)}` : '';
    const rf = $('flag-routes');
    const routeList = Object.entries(d.route_primary || {}).filter(([, h]) => h && h !== 'n/a').map(([s, h]) => `${esc(s)} → ${esc(h)}`);
    rf.hidden = !routeList.length;
    rf.innerHTML = routeList.length ? `${icon('signpost-split')} routes ${routeList.join(' · ')}${d.ha_connectors != null ? ` · ${esc(d.ha_connectors)} connectors` : ''}` : '';
    $('cluster-meta').textContent = d.at ? `cycle ${fmtAgo(d.at)}` : (d.note || '');
    $('generated').textContent = `${new Date().toLocaleTimeString()}${d.status_age_s != null ? ` · status age ${d.status_age_s}s` : ''}`;

    const svcNames = Object.keys(d.services || {});
    const body = hostNames.map((h) => {
      const hd = d.hosts[h] || {};
      const probes = Object.entries(hd.probes || {}).filter(([, v]) => v)
        .map(([p, v]) => `<span class="t-tone-text" data-tone="${upDown(v)}" title="${esc(p)} ${esc(v)}">${esc(p)}</span>`).join(' ');
      const peer = h === d.node ? tone('neutral', 'self')
        : peers.includes(h) ? tone('success', 'reachable') : tone('danger', 'unreachable');
      const roles = svcNames.filter((s) => d.services[s].primary === h || d.services[s].standby === h)
        .map((s) => `${s}: ${d.services[s].primary === h ? 'primary' : 'standby'}`);
      const role = hd.role === 'witness' ? badge('accent', 'witness') : sub(esc(roles.join(', ') || hd.role || '—'));
      return `<tr><th class="t-nowrap">${esc(h)}</th><td>${role}</td><td>${probes || NONE}</td><td>${peer}</td></tr>`;
    });
    $('hosts-body').innerHTML = body.join('');
    $('hosts-empty').hidden = body.length > 0;
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
      `<tr><td class="t-stat-sub t-nowrap" title="${esc(e.at)}">${fmtAgo(e.at)}</td>` +
      `<td class="t-nowrap">${badge(kindTone[e.kind] || 'neutral', esc(e.kind))}</td>` +
      `<td>${e.service ? sub(`${esc(e.service)} · `) : ''}${esc(e.message)}</td></tr>`);
    $('events').innerHTML = rows.join('');
    $('events-empty').hidden = rows.length > 0;
    $('events-meta').textContent = rows.length ? `${rows.length} shown · heartbeats hidden` : '';
  }

  function renderTransitions(transitions) {
    const rows = (transitions || []).slice(0, 6).map((t) => {
      const ok = t.result === 'ok';
      const dur = t.data && t.data.duration_s ? ` · ${t.data.duration_s}s` : '';
      return `<dt>${esc(t.service)} ${esc(t.action)}</dt><dd>${tone(ok ? 'success' : t.result ? 'danger' : 'warning', esc(t.result || 'running…'))}` +
        ` ${sub(`${fmtAgo(t.started_at)}${dur} · ${esc(t.node || '')}`)}</dd>`;
    });
    $('transitions').innerHTML = rows.join('');
    $('transitions-empty').hidden = rows.length > 0;
  }

  // ---------------------------------------------------------------- state-change toasts

  function diff(prev, cur) {
    if (!prev) return;
    if ((prev.quorum || null) !== (cur.quorum || null) && cur.quorum) toast(cur.quorum === 'up' ? 'success' : 'danger', `quorum ${cur.quorum}`);
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
      if (!d) { $('disabled-state').hidden = false; return; }
      if (!d.ok) throw new Error(d.message || 'not ok');
      enabled = true;
      if (failures > 0) toast('success', 'status refresh recovered');
      failures = 0;
      $('stale').hidden = true;
      diff(previous, d);
      render(d);
      previous = d;
      const [ev, tr] = await Promise.all([getJSON('/api/events?limit=40'), getJSON('/api/transitions?limit=6')]);
      if (ev) renderEvents(ev.events);
      if (tr) renderTransitions(tr.transitions);
    } catch (e) {
      failures += 1;
      $('stale').hidden = false;
      if (failures === 1) toast('danger', `status refresh failed: ${e.message}`);
    }
  }

  tick();
  setInterval(tick, refreshMs);
  setInterval(() => { if (previous) render(previous); }, 1000); // keep the timers ticking between polls
  document.addEventListener('visibilitychange', () => { if (!document.hidden) tick(); });
})();
