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
})();
