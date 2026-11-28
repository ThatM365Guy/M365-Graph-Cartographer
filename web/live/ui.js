/* MGC live runner: the Run page (Preview). Scenario-agnostic: it shows whatever the scenario's `live` blocks declare.
   Safety rules this file keeps:
   - Graph data is only ever shown as text (textContent / text nodes). This file never builds HTML from strings.
   - Every request goes through MGCRunner, which checks it with MGCGuard before calling send(). liveSend() below is
     the only code in the page that calls fetch(), and only for requests the guard has allowed.
   - The access token stays in MSAL's memory cache. The browser only keeps the tenant and the app (client) ID
     (localStorage) and the "I understand" tick for this session (sessionStorage). Results live in this tab only.
   - Nothing is sent anywhere except Microsoft Entra sign-in and Microsoft Graph. No analytics, no telemetry. */
const MGCLive = (() => {
  const SVGNS = 'http://www.w3.org/2000/svg';
  const KEY_TENANT = 'mgc-live-tenant', KEY_CLIENT = 'mgc-live-client', KEY_OK = 'mgc-live-understood';
  const GUID_RX = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
  const DOMAIN_RX = /^(?=.{3,253}$)[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$/i;
  const ROWS_SHOWN = 200;

  // h('p', {class: 'x', onclick: fn}, 'text', child) -> element. Strings become text nodes, never HTML.
  function h(tag, attrs, ...kids){
    const el = document.createElement(tag);
    for (const [k, v] of Object.entries(attrs || {})) {
      if (v === undefined || v === null || v === false) continue;
      if (k.startsWith('on')) el.addEventListener(k.slice(2), v);
      else if (k === 'text') el.textContent = v;
      else el.setAttribute(k, v === true ? '' : String(v));
    }
    for (const k of kids.flat(Infinity)) if (k !== null && k !== undefined && k !== false) el.append(k instanceof Node ? k : String(k));
    return el;
  }
  const store = (area, k, v) => { try { if (v === undefined) return area.getItem(k); if (v === null) area.removeItem(k); else area.setItem(k, v); } catch (e) { return null; } return null; };
  const msgOf = e => String((e && (e.errorMessage || e.message)) || e || 'Unknown error');
  const time = t => { try { return new Date(t).toLocaleTimeString('en-GB', {hour: '2-digit', minute: '2-digit', second: '2-digit'}); } catch (e) { return ''; } };

  function mount(ctx){
    const {D, SC, N} = ctx;
    const L = D.live || {};
    const LIVE_SET = new Set(D.liveScenarios || []);
    const here = location.href.split('#')[0].split('?')[0];
    const base = (L.origins || []).find(o => here.startsWith(o));
    const hasMsal = typeof msal !== 'undefined' && typeof msal.createStandardPublicClientApplication === 'function';
    const canLive = !!base && window.isSecureContext && hasMsal && !!(window.crypto && crypto.subtle) && window.top === window;
    const whyNot = canLive ? '' :
      location.protocol === 'file:' ? 'This copy of MGC was opened as a file, so Microsoft sign-in can’t return to it. You can try the sample data here, or open the live site to run against your tenant.'
      : window.top !== window ? 'This copy of MGC is shown inside another page, so it can’t sign you in. You can try the sample data here, or open the live site to run against your tenant.'
      : !base ? `This copy of MGC is hosted at ${location.origin}, which isn’t a registered sign-in address. You can try the sample data here, or open the live site to run against your tenant.`
      : 'This browser is missing something sign-in needs, so only the sample data is available here.';
    const REDIRECT = base ? base + (L.authPage || 'auth.html') : '';

    /* ---------------- state (memory only) ---------------- */
    const AUTH = {tenant: store(localStorage, KEY_TENANT) || '', client: store(localStorage, KEY_CLIENT) || '', key: '', pca: null, account: null,
                  granted: new Set(), preparing: false, error: ''};
    let understood = store(sessionStorage, KEY_OK) === '1';
    const RUNS = new Map();   // `${scenario}|${mode}` -> run
    const MODE = new Map();   // scenario -> 'sample' | 'live'
    const modeOf = sid => MODE.get(sid) || 'sample';
    function runOf(sid, mode = modeOf(sid)){
      const k = sid + '|' + mode;
      if (!RUNS.has(k)) RUNS.set(k, {sid, mode, steps: [], log: [], summary: null, busy: false, hop: 'page', status: ''});
      return RUNS.get(k);
    }
    function stepOf(R, i){
      if (!R.steps[i]) {
        const lv = (SC[R.sid].steps[i] || {}).live || {};
        R.steps[i] = {state: 'idle', result: null, ticks: new Map(), input: lv.input ? lv.input.default || '' : undefined, error: '', consentError: ''};
      }
      return R.steps[i];
    }
    const enabled = sid => LIVE_SET.has(sid) && !!SC[sid];
    let current = null;   // the scenario on screen

    /* ---------------- sign-in (MSAL, popup, memory cache) ---------------- */
    function authText(e){
      const code = e && e.errorCode, m = msgOf(e);
      if (code === 'user_cancelled') return 'You closed the Microsoft window before it finished. Nothing was changed.';
      if (code === 'popup_window_error' || code === 'empty_window_error') return 'Your browser blocked the Microsoft sign-in window. Allow pop-ups for this site, then try again.';
      if (/AADSTS(65001|90094|90095)/.test(m)) return 'Your organisation needs an admin to approve this permission for the app before you can use it. Ask an admin to grant admin consent on the app registration (see the how-to), then try again.';
      if (/AADSTS50011/.test(m)) return `The app registration doesn’t list this page’s sign-in address. Add ${REDIRECT} as a single-page application redirect URI, then try again.`;
      if (/AADSTS700016|AADSTS90002/.test(m)) return 'Microsoft doesn’t recognise that tenant or app (client) ID. Check both values, then try again.';
      if (e && e.name === 'InteractionRequiredAuthError') return 'Your sign-in has expired or Microsoft needs you to sign in again. Sign out, sign in again, then run the step.';
      return `Sign-in didn’t work. Microsoft said: ${m}`;
    }
    async function prepare(){
      const t = AUTH.tenant.trim(), c = AUTH.client.trim();
      if (!canLive || !(GUID_RX.test(c) && (GUID_RX.test(t) || DOMAIN_RX.test(t)))) return;
      const key = t.toLowerCase() + '|' + c.toLowerCase();
      if (AUTH.key === key && (AUTH.pca || AUTH.preparing)) return;
      AUTH.key = key; AUTH.pca = null; AUTH.account = null; AUTH.granted = new Set(); AUTH.preparing = true; AUTH.error = '';
      refresh();
      try {
        const pca = await msal.createStandardPublicClientApplication({
          auth: {clientId: c, authority: `https://login.microsoftonline.com/${encodeURIComponent(t)}`, redirectUri: REDIRECT},
          cache: {cacheLocation: 'memoryStorage'},
          system: {allowPlatformBroker: false, serverTelemetryEnabled: false, loggerOptions: {piiLoggingEnabled: false, loggerCallback(){}}}
        });
        if (AUTH.key === key) AUTH.pca = pca;
      } catch (e) { if (AUTH.key === key) AUTH.error = 'MGC couldn’t prepare sign-in: ' + msgOf(e); }
      if (AUTH.key === key) AUTH.preparing = false;
      refresh();
    }
    // Called straight from the click, so the browser lets the pop-up open.
    function signIn(){
      if (!AUTH.pca) return;
      const R = runOf(current.id, 'live');
      setHop(R, 'entra', 'Waiting for you to sign in to Microsoft in the pop-up window…');
      AUTH.pca.loginPopup({scopes: [], redirectUri: REDIRECT, prompt: 'select_account'})
        .then(r => { AUTH.account = r.account; AUTH.pca.setActiveAccount(r.account); AUTH.error = ''; setHop(R, 'page', `Signed in as ${r.account.username}. No permission to read data has been asked for yet.`); })
        .catch(e => { AUTH.error = authText(e); setHop(R, 'page', 'Not signed in.'); })
        .finally(refresh);
    }
    async function signOut(){
      const pca = AUTH.pca;
      AUTH.account = null; AUTH.granted = new Set();
      try { if (pca) await pca.clearCache(); } catch (e) {}
      for (const [k, R] of RUNS) if (R.mode === 'live') RUNS.delete(k);
      const R = current ? runOf(current.id, 'live') : null;
      if (R) setHop(R, 'page', 'Signed out. MGC has forgotten your access token and your results. You may still be signed in to Microsoft in this browser.');
      refresh();
    }
    // Every live request: the runner has already checked it with the guard. This is the only fetch() in the page.
    async function liveSend(req){
      let result;
      try { result = await AUTH.pca.acquireTokenSilent({scopes: req.scopes, account: AUTH.account}); }
      catch (e) { for (const s of req.scopes) AUTH.granted.delete(s); throw new Error(authText(e)); }
      // A token carries every permission consented for the app, not only the one this step asked for. If any of them
      // could change data, MGC stops: being read-only must not depend on the guard alone.
      const writes = MGCGuard.writeScopesIn(result.scopes);
      if (writes.length) throw new Error(`This app registration also has permissions that can change data (${writes.join(', ')}), so MGC stopped and sent nothing. MGC only runs with an app whose Microsoft Graph permissions are all read-only. Ask an admin to remove those permissions, or to register a separate app for MGC.`);
      const init = {method: req.method, headers: {Authorization: 'Bearer ' + result.accessToken}, credentials: 'omit', cache: 'no-store',
                    redirect: 'manual', referrerPolicy: 'no-referrer', mode: 'cors'};
      if (req.body !== undefined) { init.headers['Content-Type'] = 'application/json'; init.body = JSON.stringify(req.body); }
      let res;
      try { res = await fetch(req.url, init); }
      catch (e) { throw new Error('MGC couldn’t reach Microsoft Graph. Check your connection. A browser extension or network filter may also be blocking it.'); }
      // never followed: an answer that points somewhere else would leave Microsoft Graph
      if (res.type === 'opaqueredirect') throw new Error('Microsoft Graph answered with a redirect to another address. MGC doesn’t follow redirects, so nothing more was requested.');
      const ct = res.headers.get('content-type') || '';
      const body = ct.includes('json') ? await res.json().catch(() => null) : await res.text();
      return {status: res.status, headers: res.headers, body};
    }

    /* ---------------- running steps ---------------- */
    function setHop(R, hop, text){ R.hop = hop; if (text !== undefined) R.status = text; paintStatus(); }
    function sourceOf(s, i, carry){
      for (let j = i - 1; j >= 0; j--) { const lv = s.steps[j].live; if (lv && lv.carry && lv.carry.name === carry) return j; }
      return -1;
    }
    function engine(R, i){
      const send = R.mode === 'sample' ? MGCRunner.sampleSender(((L.samples || {})[R.sid] || {})[String(i)] || []) : liveSend;
      return MGCRunner.create({send, allow: L.allow, nextSeq: () => (R.seq = (R.seq || 0) + 1), onLog: e => { R.log.push(e); paintLog(); }, onStatus: x => setHop(R, x.hop, x.text)});
    }
    // Runs one step. Resolves to the step's state; 'stopped' means the person didn't give a permission or isn't signed in.
    // R is the run (sample or live) the step belongs to; Run all passes its own, so switching mode mid-run can't mix them.
    async function runOne(s, i, inner = false, R = runOf(s.id)){
      const ss = stepOf(R, i), lv = s.steps[i].live;
      if (!inner) { if (R.lock) return 'busy'; R.lock = true; }
      try { return await runOneInner(s, i, R, ss, lv); }
      finally { if (!inner) { R.lock = false; refresh(); } }
    }
    async function runOneInner(s, i, R, ss, lv){
      if (!lv || !(lv.calls || []).length) { ss.state = 'skipped'; refresh(); return 'skipped'; }
      ss.error = ''; ss.consentError = '';
      if (R.mode === 'live') {
        if (!AUTH.account) { ss.error = 'Sign in first, under Where to run it on the left.'; refresh(); return 'stopped'; }
        if (!lv.scopes.every(x => AUTH.granted.has(x))) {
          const ok = await new Promise(res => { ss.state = 'consent'; ss.consentResolve = res; refresh(); });
          ss.consentResolve = null;
          if (!ok) { ss.state = 'idle'; ss.error = 'Stopped: the permission wasn’t given, so nothing was sent.'; refresh(); return 'stopped'; }
        }
      }
      let carried;
      if (lv.from) {
        const j = sourceOf(s, i, lv.from.carry), src = j >= 0 ? stepOf(R, j) : null;
        if (!src || !src.result) { ss.state = 'failed'; ss.error = `Run step ${j + 1} first: this step uses what you tick there.`; refresh(); return 'failed'; }
        carried = src.result.carry.filter(c => src.ticks.get(c.key));
        if (!carried.length) { ss.state = 'failed'; ss.error = `Nothing is ticked in step ${j + 1}, so this step has nothing to read. Tick at least one item there.`; refresh(); return 'failed'; }
      }
      ss.state = 'running'; R.busy = true; refresh();
      try {
        const res = await engine(R, i).runStep(lv, {input: ss.input, carried});
        ss.result = res;
        ss.ticks = new Map(res.carry.map(c => [c.key, c.tick]));
        const ok = res.rows.filter(r => !r._error).length;
        ss.state = res.refused ? 'blocked' : (res.errors.length && !ok) ? 'failed' : 'done';
        if (res.refused) ss.error = `Blocked by the read-only guard: ${res.refused} Nothing was sent.`;
        else if (ss.state === 'failed') ss.error = res.errors.join(' ');
        setHop(R, 'page', ss.state === 'done' ? `Step ${i + 1} finished: ${ok} ${ok === 1 ? 'row' : 'rows'}${res.errors.length ? `, ${res.errors.length} problem(s)` : ''}.` : `Step ${i + 1} didn’t finish.`);
      } catch (e) {
        ss.state = 'failed'; ss.error = msgOf(e);
        setHop(R, 'page', `Step ${i + 1} failed.`);
      }
      R.busy = false; refresh();
      return ss.state;
    }
    async function runAll(s){
      const R = runOf(s.id);
      if (R.lock) return;
      R.lock = true; R.summary = [];
      try { await runAllInner(s, R); } finally { R.lock = false; refresh(); }
    }
    async function runAllInner(s, R){
      for (let i = 0; i < s.steps.length; i++) {
        const lv = s.steps[i].live, label = N[s.steps[i].node] ? N[s.steps[i].node].label : `Step ${i + 1}`;
        if (!lv) { R.summary.push({i, label, state: 'skipped', why: 'This step has no read-only call in the runner.'}); continue; }
        if ((lv.calls || []).length) {
          SEL.set(s.id, i); refresh();   // show each step on the right as it runs
          const st = await runOne(s, i, true, R), ss = stepOf(R, i);
          const rows = ss.result ? ss.result.rows.filter(r => !r._error).length : 0;
          R.summary.push({i, label, state: st, why: st === 'done' ? `${rows} ${rows === 1 ? 'row' : 'rows'}${ss.result.errors.length ? `; ${ss.result.errors.length} problem(s), see the step` : ''}` : ss.error});
          if (st === 'stopped') { paintSummary(); break; }
        }
        for (const k of lv.skip || []) R.summary.push({i, label, state: 'skipped', why: `${k.what}: ${k.why}`});
        paintSummary();
      }
    }
    // Shows the guard refusing a request that would change data. Nothing is sent, in either mode.
    async function tryBlocked(s){
      const R = runOf(s.id);
      const eng = MGCRunner.create({send: async () => { throw new Error('not sent'); }, allow: L.allow, nextSeq: () => (R.seq = (R.seq || 0) + 1), onLog: e => { R.log.push(e); paintLog(); }, onStatus: x => setHop(R, x.hop, x.text)});
      try { await eng.request({method: 'DELETE', url: MGCRunner.GRAPH + '/v1.0/me/drive/root', scopes: ['Files.Read.All']}); }
      catch (e) { setHop(R, 'blocked', `The read-only guard blocked DELETE /v1.0/me/drive/root: ${e.message} Nothing was sent.`); }
      refresh();
    }
    function exportCsv(s, i){
      const R = runOf(s.id), ss = stepOf(R, i), lv = s.steps[i].live;
      if (!ss.result) return;
      const csv = MGCRunner.toCsv(lv.columns, ss.result.rows);
      const url = URL.createObjectURL(new Blob([csv], {type: 'text/csv;charset=utf-8'}));
      const a = h('a', {href: url, download: `mgc-${s.id}-step${i + 1}-${R.mode === 'sample' ? 'sample-' : ''}${new Date().toISOString().slice(0, 10)}.csv`});
      document.body.appendChild(a); a.click(); a.remove();
      setTimeout(() => URL.revokeObjectURL(url), 1000);
      setHop(R, 'export', `Saved step ${i + 1} as a CSV file on your computer. Nothing was sent anywhere.`);
    }

    /* ---------------- the explainer (modal, like About) ---------------- */
    const back = document.getElementById('lxBack'), box = document.getElementById('lx');
    const tick = document.getElementById('lxOk'), go = document.getElementById('lxGo');
    let opener = null, afterOk = null;
    function openExplainer(from, then){
      if (!back) return;
      opener = from || document.activeElement; afterOk = then || null;
      tick.checked = understood; tick.disabled = understood;
      go.textContent = understood ? 'Close' : 'Continue'; go.disabled = !understood;
      document.getElementById('lxDone').hidden = !understood;
      back.hidden = false; document.querySelector('.app').inert = true; box.focus();
    }
    function closeExplainer(refocus = true){
      if (!back || back.hidden) return;
      back.hidden = true; document.querySelector('.app').inert = false;
      if (refocus && opener && opener.isConnected) opener.focus();
      const f = afterOk; afterOk = null;
      if (f && understood) f();
    }
    if (back) {
      tick.addEventListener('change', () => { go.disabled = !tick.checked; });
      go.addEventListener('click', () => {
        if (tick.checked && !understood) { understood = true; store(sessionStorage, KEY_OK, '1'); }
        closeExplainer(); refresh();
      });
      document.getElementById('lxClose').addEventListener('click', () => { afterOk = null; closeExplainer(); });
      back.addEventListener('click', e => { if (e.target === back) { afterOk = null; closeExplainer(); } });
      back.addEventListener('keydown', e => {
        if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); afterOk = null; closeExplainer(); return; }
        if (e.key !== 'Tab') return;
        const f = [...box.querySelectorAll('a[href],button:not([disabled]),input:not([disabled]),summary')], first = f[0], last = f[f.length - 1], at = document.activeElement;
        if (e.shiftKey && (at === first || at === box)) { e.preventDefault(); last.focus(); }
        else if (!e.shiftKey && at === last) { e.preventDefault(); first.focus(); }
      });
      box.addEventListener('focusout', e => { if (!back.hidden && e.relatedTarget && !box.contains(e.relatedTarget)) box.focus(); });
    }

    /* ---------------- drawing ---------------- */
    // A small version of the boundary diagram ("What crosses where") that lights up the current hop.
    const HOPS = {page: ['page'], entra: ['page', 'entra', 'e-entra'], guard: ['guard'], graph: ['guard', 'graph', 'e-graph', 'e-results'],
                  wait: ['graph'], blocked: ['guard', 'blocked', 'e-blocked'], export: ['page', 'pc', 'e-pc']};
    function svgEl(tag, attrs, text){
      const el = document.createElementNS(SVGNS, tag);
      for (const [k, v] of Object.entries(attrs)) el.setAttribute(k, v);
      if (text !== undefined) el.textContent = text;
      return el;
    }
    function hopDiagram(R){
      const on = new Set(HOPS[R.hop] || HOPS.page), sample = R.mode === 'sample';
      const svg = svgEl('svg', {class: 'df hop', viewBox: '0 0 340 136', 'aria-hidden': 'true', focusable: 'false'});
      const box = (hop, x, y, w, label, cls = 'bx') => {
        const r = svgEl('rect', {class: cls + (on.has(hop) ? ' on' : ''), x, y, width: w, height: 26, rx: 5});
        svg.append(r, svgEl('text', {class: cls === 'no' ? 'x' : 'b', x: x + w / 2, y: y + 17, 'text-anchor': 'middle'}, label));
      };
      const arrow = (hop, d, cls = 'ar') => svg.append(svgEl('path', {class: cls + (on.has(hop) ? ' on' : ''), d}));
      svg.append(svgEl('rect', {class: 'zone', x: 12, y: 4, width: 142, height: 90, rx: 8}), svgEl('text', {class: 's', x: 20, y: 16}, 'Your browser tab'));
      box('page', 20, 22, 126, 'MGC page');
      box('guard', 20, 60, 126, 'Read-only guard');
      box('pc', 20, 106, 126, 'Your computer');
      box('entra', 196, 4, 140, 'Microsoft Entra ID');
      box('graph', 196, 38, 140, sample ? 'Sample data (not sent)' : 'Microsoft Graph');
      box('blocked', 196, 72, 140, 'Not sent', 'no');
      arrow('e-entra', 'M146 32L192 20', 'ar two');
      arrow('e-results', 'M196 46L150 38', 'ar ret');
      arrow('e-graph', 'M146 70L192 56');
      arrow('e-blocked', 'M146 78L192 84', 'ar blk');
      arrow('e-pc', 'M20 36H6V119H16');
      return svg;
    }
    function paintStatus(){
      if (!current) return;
      const R = runOf(current.id), el = document.getElementById('liveStatus'), dg = document.getElementById('liveHop');
      if (el) el.textContent = R.status || (R.mode === 'sample' ? 'Ready. Sample data: nothing is sent and no permission is asked for.' : 'Ready.');
      if (dg) { const d = hopDiagram(R); dg.replaceChildren(...(d ? [d] : [])); }
    }
    function paintLog(){
      if (!current) return;
      const R = runOf(current.id), el = document.getElementById('liveLog');
      if (!el) return;
      const sum = document.getElementById('liveLogN'); if (sum) sum.textContent = String(R.log.length);
      if (!R.log.length) { el.replaceChildren(h('p', {class: 'none'}, 'No requests yet. Every request appears here in the order it was sent.')); return; }
      const rows = [];
      for (const e of R.log) {
        rows.push(h('tr', {class: e.status === 'blocked' ? 'blk' : ''}, h('td', {}, String(e.seq)), h('td', {}, time(e.at)), h('td', {}, e.method),
          h('td', {class: 'u'}, e.url), h('td', {class: 'st'}, String(e.status) + (e.sample ? ' · sample' : '')), h('td', {}, e.ms ? `${e.ms} ms` : '')));
        if (e.note) rows.push(h('tr', {class: 'nt'}, h('td', {}), h('td', {colspan: 5}, e.note)));
        for (const x of e.inner || []) rows.push(h('tr', {class: 'in'}, h('td', {}), h('td', {}, 'in batch'), h('td', {}, x.method), h('td', {class: 'u'}, x.url), h('td', {class: 'st'}, String(x.status)), h('td', {})));
      }
      el.replaceChildren(h('table', {class: 'llog'}, h('thead', {}, h('tr', {}, ['#', 'Time', 'Method', 'Address', 'Status', 'Took'].map(x => h('th', {scope: 'col'}, x)))), h('tbody', {}, rows)));
    }
    const STATE_TEXT = {done: 'done', failed: 'failed', skipped: 'skipped', stopped: 'stopped', blocked: 'blocked', running: 'running', consent: 'waiting for permission', idle: 'not run'};
    function paintSummary(){
      if (!current) return;
      const R = runOf(current.id), el = document.getElementById('liveSummary');
      if (!el) return;
      el.className = R.summary ? 'rp-card' : '';
      if (!R.summary) { el.replaceChildren(); return; }
      el.replaceChildren(h('h5', {}, 'Run all: what happened'), h('ol', {class: 'lsum'}, R.summary.map(x =>
        h('li', {}, h('span', {class: `chip st-${x.state}`}, STATE_TEXT[x.state] || x.state), h('b', {}, `${x.i + 1}. ${x.label}`), x.why ? h('span', {class: 'why'}, x.why) : null))));
    }

    /* The Run page (#run/<scenario-id>): a page of its own, reached from "Run this scenario" on the scenario panel.
       Left: where to run it, sign-in, the hop diagram, the run buttons and the steps. Right: the chosen step and its
       results, then the run log. */
    const SEL = new Map();   // scenario -> the step shown on the right
    const selOf = sid => SEL.get(sid) || 0;
    function renderPage(el, s){
      current = s;
      if (!el) return;
      const top = h('div', {class: 'rp-top'},
        h('button', {class: 'back', type: 'button', 'data-fk': 'back', onclick: () => ctx.onBack(s.id)}, '← Back to the scenario'),
        h('h1', {id: 'rpTitle'}, 'Run: ', s.label), h('span', {class: 'pv'}, 'Preview'),
        h('button', {class: 'linkbtn', type: 'button', 'data-fk': 'how', onclick: e => openExplainer(e.currentTarget)}, 'How this works'));
      const side = h('aside', {class: 'rp-side', 'aria-label': 'Set up and run'}, setupCard(s), stepsNav(s), h('div', {id: 'liveSummary'}));
      const main = h('section', {class: 'rp-main', 'aria-labelledby': 'rpStepTitle'}, stepPanel(s, selOf(s.id)), logCard(s));
      el.replaceChildren(top, h('div', {class: 'rp-grid'}, side, main));
      paintStatus(); paintLog(); paintSummary();
    }
    function logCard(s){
      const R = runOf(s.id);
      return h('details', {class: 'sm llogwrap rp-card', open: R.log.length > 0},
        h('summary', {}, 'Run log (', h('span', {id: 'liveLogN'}, String(R.log.length)), ' requests)'),
        h('p', {class: 'lnote'}, 'Every request in the order it was sent: method, address, status and time. Access tokens are never shown or saved.'),
        h('div', {id: 'liveLog'}));
    }
    function stepsNav(s){
      const R = runOf(s.id), sel = selOf(s.id);
      return h('nav', {class: 'rp-card', 'aria-label': 'Steps'}, h('h5', {}, 'Steps'),
        h('ol', {class: 'rp-steps'}, s.steps.map((st, i) => {
          const lv = st.live, ss = stepOf(R, i);
          const state = !lv || !(lv.calls || []).length ? 'skipped' : ss.state;
          return h('li', {}, h('button', {type: 'button', 'data-fk': `nav-${i}`, 'aria-current': i === sel ? 'step' : null,
            onclick: () => { SEL.set(s.id, i); refresh(); const m = document.querySelector('.rp-main'); if (m) m.scrollTop = 0; }},
            h('span', {class: 'num'}, String(i + 1)),
            h('span', {class: 'nm'}, N[st.node] ? N[st.node].label : `Step ${i + 1}`, lv && lv.skip ? h('small', {}, 'Changing data is never sent') : null),
            h('span', {class: `chip st-${state}`}, STATE_TEXT[state] || state)));
        })));
    }
    function stepPanel(s, i){
      const st = s.steps[i], n = N[st.node] || {};
      const wrap = h('div', {class: 'rp-card rp-step'},
        h('p', {class: 'lnote'}, `Step ${i + 1} of ${s.steps.length}`, ctx.where && N[st.node] ? ` · ${ctx.where(n)}` : ''),
        h('h2', {id: 'rpStepTitle'}, n.label || `Step ${i + 1}`),
        st.do ? h('p', {class: 'lnote'}, 'In the scenario: ', st.do) : null);
      const body = h('div', {class: 'lstep'});
      renderStep(body, s, i);
      wrap.append(body, h('div', {class: 'lbtns rp-nav'},
        h('button', {class: 'pbtn', type: 'button', 'data-fk': 'prev', disabled: i === 0, onclick: () => { SEL.set(s.id, i - 1); refresh(); }}, '← Previous step'),
        h('button', {class: 'pbtn', type: 'button', 'data-fk': 'next', disabled: i === s.steps.length - 1, onclick: () => { SEL.set(s.id, i + 1); refresh(); }}, 'Next step →')));
      return wrap;
    }
    function setupCard(s){
      const mode = modeOf(s.id), R = runOf(s.id);
      const parts = [h('h5', {}, 'Where to run it')];
      parts.push(h('p', {class: 'lnote'}, 'Runs the read-only steps and shows the results on this page. Results stay in this tab only, and MGC never saves them.'));
      const running = !!(runOf(s.id, 'sample').lock || runOf(s.id, 'live').lock);   // no switching mid-run
      const seg = h('div', {class: 'seg2 lmode', role: 'group', 'aria-label': 'Run with'},
        h('button', {type: 'button', 'data-fk': 'mode-sample', 'aria-pressed': String(mode === 'sample'), disabled: running, onclick: () => { MODE.set(s.id, 'sample'); refresh(); }}, 'Sample data'),
        h('button', {type: 'button', 'data-fk': 'mode-live', 'aria-pressed': String(mode === 'live'), disabled: !canLive || running, onclick: e => {
          const btn = e.currentTarget;
          const sw = () => { MODE.set(s.id, 'live'); refresh(); };
          if (!understood) openExplainer(btn, sw); else sw();
        }}, 'My tenant'));
      parts.push(seg);
      if (!canLive) parts.push(h('p', {class: 'lnote'}, whyNot));
      if (mode === 'sample') {
        parts.push(h('p', {class: 'lnote'}, 'Sample data uses made-up responses for a fictional organisation (Hollowbrook Trading). Nothing is sent, and no permission is asked for. The read-only guard still checks every request.'));
      } else {
        parts.push(signInBlock());
      }
      parts.push(h('h5', {}, 'Run'));
      parts.push(h('div', {class: 'lhopwrap'}, h('div', {id: 'liveHop', class: 'lhop'}), h('p', {id: 'liveStatus', class: 'lstatus', role: 'status'})));
      const busy = !!R.lock;
      parts.push(h('div', {class: 'lbtns'},
        h('button', {class: 'pbtn solid', type: 'button', 'data-fk': 'runall', disabled: busy || (mode === 'live' && !AUTH.account), onclick: () => runAll(s)}, 'Run all read-only steps'),
        h('button', {class: 'pbtn', type: 'button', 'data-fk': 'blocked', disabled: busy, onclick: () => tryBlocked(s)}, 'Try a blocked request'),
        h('button', {class: 'pbtn', type: 'button', 'data-fk': 'clear', disabled: busy, onclick: () => { RUNS.delete(s.id + '|' + mode); refresh(); }}, 'Clear results')));
      return h('div', {class: 'rp-card'}, ...parts);
    }
    function signInBlock(){
      if (!understood) return h('div', {class: 'lsign'}, h('p', {}, 'Before you sign in, read how this works and what happens to the data.'),
        h('button', {class: 'pbtn solid', type: 'button', onclick: e => openExplainer(e.currentTarget)}, 'Read how this works'));
      if (AUTH.account) return h('div', {class: 'lsign'},
        h('p', {}, 'Signed in as ', h('b', {}, AUTH.account.username || AUTH.account.name || 'you'), '.'),
        h('p', {class: 'lnote'}, AUTH.granted.size ? `Permissions given in this session: ${[...AUTH.granted].join(', ')}.` : 'No permission to read data has been asked for yet. Each step asks for its own when you run it.'),
        h('button', {class: 'pbtn', type: 'button', onclick: signOut}, 'Sign out'));
      const t = h('input', {id: 'liveTenant', type: 'text', autocomplete: 'off', spellcheck: 'false', placeholder: 'contoso.onmicrosoft.com or tenant ID'});
      const c = h('input', {id: 'liveClient', type: 'text', autocomplete: 'off', spellcheck: 'false', placeholder: '00000000-0000-0000-0000-000000000000'});
      t.value = AUTH.tenant; c.value = AUTH.client;
      const hint = h('p', {class: 'lnote', id: 'liveHint'});
      const btn = h('button', {class: 'pbtn solid', type: 'button', onclick: signIn}, 'Sign in with Microsoft');
      const sync = () => {
        AUTH.tenant = t.value.trim(); AUTH.client = c.value.trim();
        store(localStorage, KEY_TENANT, AUTH.tenant || null); store(localStorage, KEY_CLIENT, AUTH.client || null);
        const okT = GUID_RX.test(AUTH.tenant) || DOMAIN_RX.test(AUTH.tenant), okC = GUID_RX.test(AUTH.client);
        hint.textContent = !AUTH.tenant || !AUTH.client ? 'Enter your tenant and the app (client) ID of the app registration your organisation created for MGC.'
          : !okT ? 'The tenant should be a domain such as contoso.onmicrosoft.com, or a tenant ID.'
          : !okC ? 'The app (client) ID is a GUID, such as 00000000-0000-0000-0000-000000000000.'
          : AUTH.preparing ? 'Getting sign-in ready…' : AUTH.error || (AUTH.pca ? 'Ready. Microsoft will open a pop-up window.' : '');
        btn.disabled = !(okT && okC && AUTH.pca && !AUTH.preparing);
        if (okT && okC) prepare();
      };
      t.addEventListener('change', sync); c.addEventListener('change', sync);
      t.addEventListener('input', () => { btn.disabled = true; }); c.addEventListener('input', () => { btn.disabled = true; });
      sync();
      return h('div', {class: 'lsign'},
        h('div', {class: 'lform'}, h('label', {for: 'liveTenant'}, 'Tenant'), t, h('label', {for: 'liveClient'}, 'App (client) ID'), c),
        hint, btn,
        h('details', {class: 'sm'}, h('summary', {}, 'How to register the app (an admin does this once)'),
          h('ol', {class: 'lhow'},
            h('li', {}, 'In the Microsoft Entra admin center, go to App registrations and choose New registration. Choose "Accounts in this organizational directory only".'),
            h('li', {}, 'Under Redirect URI, choose Single-page application (SPA) and enter ', h('code', {}, REDIRECT || 'https://thatm365guy.github.io/M365-Graph-Cartographer/auth.html'), '.'),
            h('li', {}, 'Add no client secret and no certificate. The app only signs people in and asks for delegated, read-only permissions.'),
            h('li', {}, 'Under API permissions, add the Microsoft Graph delegated permissions the steps use (Sites.Read.All, Files.Read.All, Reports.Read.All) and grant admin consent. Reports.Read.All always needs it.'),
            h('li', {}, 'Copy the Directory (tenant) ID and the Application (client) ID into the boxes above.')),
          h('p', {class: 'lnote'}, 'MGC remembers these two values in this browser so you don’t have to type them again. It never stores your access token.')));
    }

    function renderStep(el, s, i){
      if (!el) return;
      const lv = s.steps[i].live, R = runOf(s.id), ss = stepOf(R, i);
      if (!lv) { el.replaceChildren(h('p', {class: 'none'}, 'This step has no read-only call in the runner.')); return; }
      const parts = [h('p', {class: 'says'}, lv.says)];
      if (lv.caveat) parts.push(h('p', {class: 'lcav'}, h('b', {}, 'What it can’t see: '), lv.caveat));
      if ((lv.calls || []).length) {
        parts.push(h('p', {class: 'lscope'}, h('b', {}, 'Permission: '), lv.scopes.map(x => h('code', {}, x)), ' (delegated, read-only). ', lv.whyScope || ''));
        for (const c of lv.calls) parts.push(h('p', {class: 'lcall'}, h('code', {}, `${c.method} ${c.url}`), c.batch ? ' (sent in batches of up to 20)' : ''));
      }
      for (const k of lv.skip || []) parts.push(h('p', {class: 'lskip'}, h('span', {class: 'chip st-skipped'}, 'not sent'), h('b', {}, k.what), ' ', k.why));
      if (lv.input) {
        const inp = h('input', {type: 'text', id: `liveIn${i}`, autocomplete: 'off', spellcheck: 'false'});
        inp.value = ss.input || '';
        inp.addEventListener('input', () => { ss.input = inp.value; });
        parts.push(h('div', {class: 'lform one'}, h('label', {for: `liveIn${i}`}, lv.input.label), inp), lv.input.help ? h('p', {class: 'lnote'}, lv.input.help) : null);
      }
      if (lv.from) {
        const j = sourceOf(s, i, lv.from.carry), src = j >= 0 ? stepOf(R, j) : null;
        const n = src && src.result ? src.result.carry.filter(c => src.ticks.get(c.key)).length : 0;
        parts.push(h('p', {class: 'lnote'}, src && src.result ? `Uses the ${n} ${lv.from.carry} ticked in step ${j + 1}.` : `Uses the ${lv.from.carry} you tick in step ${j + 1}. Run step ${j + 1} first.`));
      }
      if (ss.state === 'consent') parts.push(consentCard(s, i, lv, ss));
      if ((lv.calls || []).length && ss.state !== 'consent') {
        const busy = !!R.lock;
        parts.push(h('div', {class: 'lbtns'}, h('button', {class: 'pbtn solid', type: 'button', 'data-fk': `run-${i}`, disabled: busy || (R.mode === 'live' && !AUTH.account),
          onclick: () => runOne(s, i)}, ss.result ? 'Run this step again' : 'Run this step'),
          R.mode === 'live' && !AUTH.account ? h('span', {class: 'lnote'}, 'Sign in first, under Where to run it on the left.') : null,
          ss.state === 'running' ? h('span', {class: 'lnote'}, 'Running…') : null));
      }
      if (ss.error) parts.push(h('p', {class: 'lerr', role: 'alert'}, ss.error));
      if (ss.result) parts.push(...resultView(s, i, lv, ss));
      el.replaceChildren(...parts);
    }
    function consentCard(s, i, lv, ss){
      const cont = h('button', {class: 'pbtn solid', type: 'button', onclick: () => {
        const R = runOf(s.id);
        setHop(R, 'entra', 'Waiting for you in the Microsoft window…');
        AUTH.pca.acquireTokenPopup({scopes: lv.scopes, account: AUTH.account, redirectUri: REDIRECT})
          .then(() => { lv.scopes.forEach(x => AUTH.granted.add(x)); setHop(R, 'page', `Permission given: ${lv.scopes.join(', ')}.`); const f = ss.consentResolve; if (f) f(true); })
          .catch(e => { ss.consentError = authText(e); setHop(R, 'page', 'The permission wasn’t given.'); refresh(); });
      }}, 'Continue to Microsoft');
      return h('div', {class: 'consent', role: 'group', 'aria-label': 'Permission needed'},
        h('h5', {}, 'Next, Microsoft will ask you to allow a permission'),
        h('p', {}, h('b', {}, lv.scopes.join(', ')), ' (delegated, read-only)'),
        h('p', {}, h('b', {}, 'Why this step needs it: '), lv.whyScope || ''),
        h('p', {}, 'It is read-only and delegated: MGC can only see what your account can already see, and it can’t change anything. Microsoft shows the request in its own window. If your organisation needs an admin to approve it, Microsoft will say so there.'),
        ss.consentError ? h('p', {class: 'lerr', role: 'alert'}, ss.consentError) : null,
        h('div', {class: 'lbtns'}, cont, h('button', {class: 'pbtn', type: 'button', onclick: () => { const f = ss.consentResolve; if (f) f(false); }}, 'Cancel')));
    }
    function resultView(s, i, lv, ss){
      const res = ss.result, out = [];
      out.push(h('div', {class: 'lcounts'}, res.counts.map(c => h('div', {class: 'tile'}, h('b', {}, String(c.value)), h('span', {}, c.label)))));
      if (res.empty) out.push(h('p', {class: 'lnote'}, res.empty));
      if (res.errors.length && ss.state === 'done') out.push(h('p', {class: 'lerr'}, `${res.errors.length} problem(s) on some items: `, res.errors.join(' ')));
      const rows = res.rows;
      if (rows.length) {
        const cols = lv.columns;
        out.push(h('div', {class: 'ltable'}, h('table', {class: 'rt'},
          h('thead', {}, h('tr', {}, cols.map(c => h('th', {scope: 'col'}, c.label)))),
          h('tbody', {}, rows.slice(0, ROWS_SHOWN).map(r => h('tr', {class: r._error ? 'err' : ''}, cols.map(c => h('td', {}, MGCRunner.cell(r, c)))))))));
        if (rows.length > ROWS_SHOWN) out.push(h('p', {class: 'lnote'}, `Showing ${ROWS_SHOWN} of ${rows.length} rows. Export CSV has them all.`));
      } else if (!res.empty) out.push(h('p', {class: 'lnote'}, 'No results.'));
      if (lv.carry && res.carry.length) {
        const list = h('ul', {class: 'lcarry'});
        const count = h('span', {class: 'lnote'});
        const recount = () => { count.textContent = `${[...ss.ticks.values()].filter(Boolean).length} of ${res.carry.length} ticked.`; };
        for (const it of res.carry) {
          const id = `lc${i}-${res.carry.indexOf(it)}`;
          const cb = h('input', {type: 'checkbox', id});
          cb.checked = !!ss.ticks.get(it.key);
          cb.addEventListener('change', () => { ss.ticks.set(it.key, cb.checked); recount(); });
          list.append(h('li', {}, cb, h('label', {for: id}, it.label)));
        }
        recount();
        const all = v => { for (const it of res.carry) ss.ticks.set(it.key, v); list.querySelectorAll('input').forEach(x => { x.checked = v; }); recount(); };
        out.push(h('details', {class: 'sm', open: true}, h('summary', {}, `Carry forward: ${lv.carry.name}`),
          lv.carry.help ? h('p', {class: 'lnote'}, lv.carry.help) : null,
          h('div', {class: 'lbtns'}, h('button', {class: 'pbtn', type: 'button', onclick: () => all(true)}, 'Tick all'), h('button', {class: 'pbtn', type: 'button', onclick: () => all(false)}, 'Tick none'), count),
          list));
      }
      out.push(h('div', {class: 'lbtns'}, h('button', {class: 'pbtn', type: 'button', onclick: () => exportCsv(s, i)}, 'Export CSV'),
        h('span', {class: 'lnote'}, 'Saves a file on your computer only.')));
      const raw = JSON.stringify(res.raw, null, 2);
      out.push(h('details', {class: 'sm'}, h('summary', {}, `Raw JSON (${res.raw.length} ${res.raw.length === 1 ? 'response' : 'responses'})`),
        h('pre', {class: 'raw'}, raw.length > 200000 ? raw.slice(0, 200000) + '\n… (cut short here; the table and Export CSV have every row)' : raw)));
      return out;
    }

    // Re-draws the Run parts that are on screen, keeping the panel's scroll position.
    // Re-draws the Run page when it is on screen, keeping both columns' scroll positions and the focused control.
    function refresh(){
      const page = document.getElementById('runpage');
      if (!current || !page || page.hidden) return;
      const keep = ['.rp-side', '.rp-main'].map(q => { const x = page.querySelector(q); return x ? x.scrollTop : 0; });
      const fk = document.activeElement && document.activeElement.dataset ? document.activeElement.dataset.fk : null;
      renderPage(page, current);
      ['.rp-side', '.rp-main'].forEach((q, k) => { const x = page.querySelector(q); if (x) x.scrollTop = keep[k]; });
      if (fk) { const again = page.querySelector(`[data-fk="${fk}"]`); if (again && !again.disabled) again.focus({preventScroll: true}); }
    }
    function reset(){ afterOk = null; closeExplainer(false); }

    return {enabled, renderPage, openExplainer, reset};
  }
  return {mount};
})();
