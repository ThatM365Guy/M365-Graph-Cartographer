/* MGC live runner: the engine. Scenario-agnostic: everything it knows about a step comes from that step's `live`
   block in curated.json. It builds the requests, sends each one through the read-only guard and then through a
   `send` function it is given (the real network after sign-in, or the sample responses), follows paging, batches
   GETs (at most 20 per batch), waits and retries when Graph throttles (Retry-After), maps the results to rows,
   columns and counts, and keeps a log of every request in the order it was sent. No DOM, no storage, no network
   of its own: it runs in the page and under Node (tests/test_live.py). */
const MGCRunner = (() => {
  const G = (typeof MGCGuard !== 'undefined') ? MGCGuard : require('./guard.js');
  const GRAPH = 'https://graph.microsoft.com';
  const RETRY_STATUS = [429, 503, 504];
  const MAX_ATTEMPTS = 3;
  const MAX_WAIT_S = 120;

  /* ---------- small pure helpers ---------- */
  // get({a: {b: [{c: 1}, {c: 2}]}}, 'a.b[].c') -> [1, 2]; '[]' flattens arrays.
  function get(obj, path){
    if (path === undefined || path === null || path === '') return obj;
    let cur = [obj], many = false;
    for (const part of String(path).split('.')) {
      const flat = part.endsWith('[]'), key = flat ? part.slice(0, -2) : part;
      const next = [];
      for (const c of cur) {
        if (c === null || c === undefined) continue;
        const v = key === '' ? c : c[key];
        if (flat) { if (Array.isArray(v)) next.push(...v); many = true; }
        else next.push(v);
      }
      cur = next;
    }
    return many ? cur.filter(v => v !== undefined && v !== null) : cur[0];
  }
  function first(obj, from){
    for (const p of [].concat(from)) {
      const v = get(obj, p);
      if (Array.isArray(v) ? v.length : (v !== undefined && v !== null && v !== '')) return v;
    }
    return undefined;
  }
  function text(v){
    if (v === undefined || v === null) return '';
    if (Array.isArray(v)) return v.map(text).filter(Boolean).join(', ');
    if (typeof v === 'object') return JSON.stringify(v);
    return String(v);
  }
  function matches(row, where){
    if (!where) return true;
    const v = Array.isArray(where.field) ? first(row, where.field) : get(row, where.field);   // a list: the first that has a value
    const vals = Array.isArray(v) ? v : [v];
    const has = vals.some(x => x !== undefined && x !== null && x !== '');
    if (where.exists === true) return has;
    if (where.exists === false) return !has;
    if ('is' in where) { const want = [].concat(where.is); return vals.some(x => want.includes(x)); }
    return true;
  }
  // '{site.id}' and '{input}' in a URL: values are percent-encoded (commas kept, as in SharePoint site ids).
  function fillUrl(tpl, ctx){
    return String(tpl).replace(/\{([A-Za-z0-9_.]+)\}/g, (m, p) => {
      const v = get(ctx, p);
      if (v === undefined || v === null || typeof v === 'object') throw new Error(`No value for {${p}} in the request address.`);
      return encodeURIComponent(String(v)).replace(/%2C/gi, ',');
    });
  }
  // The same placeholders inside the string values of a JSON body (no encoding: the body is sent as JSON).
  function fillBody(tpl, ctx){
    if (tpl === undefined || tpl === null) return undefined;
    if (typeof tpl === 'string') return tpl.replace(/\{([A-Za-z0-9_.]+)\}/g, (m, p) => {
      const v = get(ctx, p);
      if (v === undefined || v === null || typeof v === 'object') throw new Error(`No value for {${p}} in the request body.`);
      return String(v).replace(/"/g, '');   // keeps a value from closing a quoted KQL term early
    });
    if (Array.isArray(tpl)) return tpl.map(x => fillBody(x, ctx));
    if (typeof tpl === 'object') { const o = {}; for (const k of Object.keys(tpl)) o[k] = fillBody(tpl[k], ctx); return o; }
    return tpl;
  }
  // RFC 4180-ish CSV parser for the usage reports (handles a BOM, quotes, doubled quotes and CRLF).
  function parseCsv(s){
    s = String(s || '').replace(/^﻿/, '');
    const rows = []; let row = [], cell = '', q = false;
    for (let i = 0; i < s.length; i++) {
      const c = s[i];
      if (q) {
        if (c === '"') { if (s[i + 1] === '"') { cell += '"'; i++; } else q = false; }
        else cell += c;
      } else if (c === '"') q = true;
      else if (c === ',') { row.push(cell); cell = ''; }
      else if (c === '\n' || c === '\r') { if (c === '\r' && s[i + 1] === '\n') i++; row.push(cell); rows.push(row); row = []; cell = ''; }
      else cell += c;
    }
    if (cell !== '' || row.length) { row.push(cell); rows.push(row); }
    const head = rows.shift() || [];
    return rows.filter(r => r.some(x => x !== '')).map(r => Object.fromEntries(head.map((h, i) => [h, r[i] ?? ''])));
  }
  // A cell that starts with = + - @ (or a tab or return) could run as a formula in a spreadsheet: prefix a quote.
  // A plain number such as -5 stays as it is.
  function csvCell(v){
    let s = text(v);
    if (/^[=+\-@\t\r]/.test(s) && !/^[-+]?\d+(\.\d+)?$/.test(s)) s = "'" + s;
    return /[",\r\n]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s;
  }
  function toCsv(columns, rows){
    const lines = [columns.map(c => csvCell(c.label)).join(',')];
    for (const r of rows) lines.push(columns.map(c => csvCell(cell(r, c))).join(','));
    return '﻿' + lines.join('\r\n') + '\r\n';
  }
  function cell(row, col){
    if (row._error && col.error) return row._error;
    const v = first(row, col.from);
    return v === undefined ? (col.empty || '') : text(v);
  }
  function counts(live, rows){
    return (live.counts || []).map(c => {
      const hit = rows.filter(r => !r._error && matches(r, c.where));
      if (c.distinct) return {label: c.label, value: new Set(hit.map(r => text(get(r, c.distinct)))).size};
      return {label: c.label, value: hit.length};
    });
  }
  // The items a step offers to carry forward: unique by key, ticked by default when they match carry.tick.
  function carryItems(live, rows){
    const c = live.carry; if (!c) return [];
    const seen = new Map();
    for (const r of rows) {
      if (r._error) continue;
      const key = text(get(r, c.key)); if (!key) continue;
      const it = seen.get(key) || {key, label: text(first(r, c.label)) || key, value: get(r, c.keep), tick: false};
      if (!c.tick || matches(r, c.tick)) it.tick = true;
      seen.set(key, it);
    }
    const out = [...seen.values()];
    if (c.max) { let n = 0; for (const it of out) if (it.tick && ++n > c.max) it.tick = false; }
    return out;
  }
  function retryAfter(headers){
    const raw = headers && (typeof headers.get === 'function' ? headers.get('retry-after') : (headers['retry-after'] || headers['Retry-After']));
    const n = parseInt(raw, 10);
    return Number.isFinite(n) && n >= 0 ? Math.min(n, MAX_WAIT_S) : 5;
  }
  function graphMessage(body){
    const e = body && typeof body === 'object' ? body.error : null;
    return e ? [e.code, e.message].filter(Boolean).join(': ') : '';
  }
  // Plain words for a failed request, plus what to do next.
  function explain(status, body, notes){
    const own = notes && notes[String(status)];
    const gm = graphMessage(body);
    const base = {
      400: 'Microsoft Graph did not accept the request.',
      401: 'Your sign-in has expired or is not valid. Sign in again, then run the step again.',
      403: 'Microsoft Graph refused: your account does not have access to this.',
      404: 'Microsoft Graph could not find it. It may have been deleted, or you may not be able to see it.',
      423: 'The file is locked, so its labels could not be read.',
      429: 'Microsoft Graph is busy and asked MGC to slow down. Wait a minute, then run the step again.',
      503: 'Microsoft Graph is busy or unavailable. Wait a minute, then run the step again.',
      504: 'Microsoft Graph took too long to answer. Wait a minute, then run the step again.'
    }[status] || `Microsoft Graph answered with status ${status}.`;
    return [own || base, gm ? `Graph said: ${gm}` : ''].filter(Boolean).join(' ');
  }

  /* ---------- the engine ---------- */
  function create(opts){
    const send = opts.send, allow = opts.allow;
    const sleep = opts.sleep || (ms => new Promise(r => setTimeout(r, ms)));
    const now = opts.now || (() => Date.now());
    const onLog = opts.onLog || (() => {}), onStatus = opts.onStatus || (() => {});
    let seq = 0;
    const nextSeq = opts.nextSeq || (() => ++seq);   // the page passes one counter per run, so the log numbers run on across steps
    class Refused extends Error { constructor(reason){ super(reason); this.refused = true; } }

    // One HTTP request: guard first, then send, retrying on 429/503/504 after Retry-After. Returns {status, headers, body}.
    async function request(req, label){
      const verdict = G.check(req, allow);
      if (!verdict.ok) {
        onLog({seq: nextSeq(), at: now(), method: req.method, url: req.url, status: 'blocked', ms: 0, note: `Blocked by the read-only guard: ${verdict.reason} Nothing was sent.`});
        onStatus({hop: 'blocked', text: 'The read-only guard blocked a request. Nothing was sent.'});
        throw new Refused(verdict.reason);
      }
      for (let attempt = 1; ; attempt++) {
        const t0 = now();
        onStatus({hop: 'graph', text: label});
        let res;
        try { res = await send(req); }
        catch (e) {
          onLog({seq: nextSeq(), at: t0, method: req.method, url: req.url, status: 'failed', ms: now() - t0, note: String(e && e.message || e)});
          throw e;
        }
        const entry = {seq: nextSeq(), at: t0, method: req.method, url: req.url, status: res.status, ms: now() - t0, sample: !!res.sample};
        // a batch is one HTTP request; the log also lists the GETs inside it and how each one was answered
        if (req.body && Array.isArray(req.body.requests) && res.body && Array.isArray(res.body.responses) && /\/\$batch$/.test(new URL(req.url).pathname)) {
          const byId = new Map(res.body.responses.map(r => [String(r.id), r.status]));
          entry.inner = req.body.requests.map(r => ({method: r.method, url: r.url, status: byId.has(String(r.id)) ? byId.get(String(r.id)) : '?'}));
        }
        // a POST (other than a batch of GETs) is retried only on 429, which means it wasn't run: after a 503 or 504 it
        // may have run, and running some allowed POSTs twice (an audit search) would start a second one
        const retryable = req.method === 'GET' || /\/\$batch$/.test(new URL(req.url).pathname) ? RETRY_STATUS : [429];
        if (retryable.includes(res.status) && attempt < MAX_ATTEMPTS) {
          const wait = retryAfter(res.headers);
          entry.note = `Microsoft Graph asked MGC to wait ${wait} seconds. Trying again (attempt ${attempt + 1} of ${MAX_ATTEMPTS}).`;
          onLog(entry);
          onStatus({hop: 'wait', text: `Microsoft Graph is busy. Waiting ${wait} seconds before trying again…`});
          await sleep(wait * 1000);
          continue;
        }
        onLog(entry);
        return res;
      }
    }

    // GETs for many contexts, sent as $batch requests of up to 20. Inner 429s are retried in a new batch after the
    // longest Retry-After. Returns one {status, body} per context, in order.
    async function batchGet(urls, scopes, what){
      const out = new Array(urls.length);
      const chunks = [];
      for (let i = 0; i < urls.length; i += G.MAX_BATCH) chunks.push(urls.slice(i, i + G.MAX_BATCH).map((u, j) => ({i: i + j, u})));
      for (let ci = 0; ci < chunks.length; ci++) {
        let pending = chunks[ci];
        for (let attempt = 1; pending.length; attempt++) {
          const version = new URL(pending[0].u).pathname.split('/')[1];
          const body = {requests: pending.map(p => ({id: String(p.i), method: 'GET', url: p.u.slice((GRAPH + '/' + version).length)}))};
          const res = await request({method: 'POST', url: `${GRAPH}/${version}/$batch`, body, scopes},
            `Asking Microsoft Graph for ${what} (batch ${ci + 1} of ${chunks.length})…`);
          if (res.status !== 200) { for (const p of pending) out[p.i] = {status: res.status, body: res.body, headers: res.headers}; break; }
          const again = []; let wait = 0;
          for (const r of (res.body && res.body.responses) || []) {
            const i = +r.id, p = pending.find(x => x.i === i);
            if (!p) continue;
            if (RETRY_STATUS.includes(r.status) && attempt < MAX_ATTEMPTS) { again.push(p); wait = Math.max(wait, retryAfter(r.headers || {})); }
            else out[i] = {status: r.status, body: r.body, headers: r.headers || {}};
          }
          for (const p of pending) if (!out[p.i] && !again.includes(p)) out[p.i] = {status: 0, body: null};
          pending = again;
          if (pending.length) {
            onStatus({hop: 'wait', text: `Microsoft Graph is busy. Waiting ${wait} seconds before trying ${pending.length} request(s) again…`});
            await sleep(wait * 1000);
          }
        }
      }
      return out;
    }

    // Rows from one response body for a call: CSV text, or the JSON at call.rows (the whole body when unset).
    function rowsOf(call, body){
      if (call.format === 'csv') return typeof body === 'string' ? parseCsv(body) : (get(body, 'value') || []);
      const v = call.rows ? get(body, call.rows) : body;
      return Array.isArray(v) ? v : (v === undefined || v === null ? [] : [v]);
    }

    // GET with @odata.nextLink paging (call.pages caps it), or POST /search/query paging by from/size.
    async function fetchAll(call, url, body, scopes, what){
      const rows = []; const raw = [];
      let pageUrl = url, pageBody = body, page = 1;
      const max = call.pages || 1;
      while (true) {
        const res = await request({method: call.method, url: pageUrl, body: pageBody, scopes},
          page === 1 ? `Asking Microsoft Graph for ${what}…` : `Asking Microsoft Graph for page ${page} of ${what}…`);
        raw.push({url: pageUrl, status: res.status, body: res.body});
        if (res.status < 200 || res.status > 299) return {rows, raw, fail: res};
        rows.push(...rowsOf(call, res.body));
        if (page >= max) break;
        if (call.pageBy === 'search') {
          const more = get(res.body, 'value[].hitsContainers[].moreResultsAvailable');
          if (!(Array.isArray(more) ? more.includes(true) : more)) break;
          pageBody = JSON.parse(JSON.stringify(pageBody));
          for (const r of pageBody.requests) r.from = (r.from || 0) + (r.size || 25);
        } else {
          const next = res.body && res.body['@odata.nextLink'];
          if (!next) break;
          pageUrl = next;   // checked by the guard like any other address
        }
        page++;
      }
      return {rows, raw};
    }

    /* Runs one step. live: the step's live block; input: the step's input value (if it has one); carried: the ticked
       items from an earlier step; scopes come from live.scopes. Returns {rows, counts, raw, carry, errors, refused}. */
    async function runStep(live, {input, carried} = {}){
      const scopes = live.scopes, raw = [], errors = [];
      let ctxs = [{input}];
      if (live.from) {
        ctxs = (carried || []).map(it => ({input, [live.from.as]: it.value}));
        if (!ctxs.length) return {rows: [], counts: counts(live, []), raw, carry: [], errors: [], empty: `Nothing was carried over from an earlier step, so this step has nothing to read.`};
      }
      try {
        for (const call of live.calls || []) {
          const what = call.what || 'results';
          const next = [];
          // an item that lacks a value the address needs fails on its own; the rest still run
          const built = ctxs.map(c => {
            if (c._error) return {c, carried: true};
            try { return {c, url: GRAPH + fillUrl(call.url, c), body: fillBody(call.body, c)}; }
            catch (e) { return {c, err: `${e.message} This item was skipped.`}; }
          });
          for (const b of built) {
            if (b.carried) next.push({...b.c, [call.as]: null});   // failed at an earlier call: keep its reason
            else if (b.err) { errors.push(b.err); next.push({...b.c, [call.as]: null, _error: b.err}); }
          }
          const todo = built.filter(b => b.url);
          if (call.batch && call.method === 'GET' && todo.length > 1) {
            const urls = todo.map(b => b.url);
            const res = await batchGet(urls, scopes, what);
            for (let i = 0; i < todo.length; i++) {
              const r = res[i], c = todo[i].c;
              raw.push({url: urls[i], status: r.status, body: r.body});
              if (r.status >= 200 && r.status <= 299) {
                let rows = rowsOf(call, r.body);
                const nl = r.body && r.body['@odata.nextLink'];
                if (nl && (call.pages || 1) > 1) {
                  const more = await fetchAll({...call, pages: (call.pages || 1) - 1}, nl, undefined, scopes, what);
                  raw.push(...more.raw); rows = rows.concat(more.rows);
                }
                if (!rows.length && call.keepEmpty) next.push({...c, [call.as]: null});
                for (const row of rows) next.push({...c, [call.as]: row});
              } else {
                const why = explain(r.status, r.body, live.notes);
                errors.push(why);
                next.push({...c, [call.as]: null, _error: why, _status: r.status});
              }
            }
          } else {
            for (let i = 0; i < todo.length; i++) {
              const {c, url, body} = todo[i];
              const got = await fetchAll(call, url, body, scopes, what);
              raw.push(...got.raw);
              if (got.fail) {
                const why = explain(got.fail.status, got.fail.body, live.notes);
                errors.push(why);
                next.push({...c, [call.as]: null, _error: why, _status: got.fail.status});
                // the same refusal for every item (a 401 or 403 on the first) is not worth repeating
                if ([401, 403].includes(got.fail.status) && !call.perItemErrors) {
                  for (const rest of todo.slice(i + 1)) next.push({...rest.c, [call.as]: null, _error: why, _status: got.fail.status});
                  break;
                }
                continue;
              }
              if (!got.rows.length && call.keepEmpty) next.push({...c, [call.as]: null});
              for (const row of got.rows) next.push({...c, [call.as]: row});
            }
          }
          ctxs = next;
        }
      } catch (e) {
        if (e && e.refused) return {rows: [], counts: counts(live, []), raw, carry: [], errors: [e.message], refused: e.message};
        throw e;
      }
      const rows = ctxs.filter(c => c._error || (live.calls || []).every(call => c[call.as] !== undefined));
      return {rows, counts: counts(live, rows), raw, carry: carryItems(live, rows), errors: [...new Set(errors)]};
    }
    return {runStep, request};
  }

  /* ---------- sample mode ----------
     A `send` that answers from a step's sample file (data/samples/<scenario-id>/step-<n>.json) instead of the network.
     Rules are tried in order; the first whose method, path (decoded, exact) and `has` (a piece of the URL or body)
     match is used, and a rule marked `once` answers only once per run. A $batch is answered rule by rule for each
     GET inside it. Requests still go through the guard first, exactly as in a live run. */
  function headersOf(obj){
    const m = new Map(Object.entries(obj || {}).map(([k, v]) => [k.toLowerCase(), String(v)]));
    return {get: k => m.has(String(k).toLowerCase()) ? m.get(String(k).toLowerCase()) : null, raw: obj || {}};
  }
  function sampleSender(rules){
    const used = new Set();
    const clone = v => v === undefined ? undefined : JSON.parse(JSON.stringify(v));
    const missing = {error: {code: 'NoSample', message: 'There is no sample response for this request.'}};
    function match(method, url, bodyStr){
      const u = new URL(url), path = decodeURIComponent(u.pathname), hay = decodeURIComponent(url) + ' ' + bodyStr;
      for (let i = 0; i < rules.length; i++) {
        const r = rules[i];
        if ((r.once && used.has(i)) || r.method !== method || (r.path && r.path !== path) || (r.has && !hay.includes(r.has))) continue;
        if (r.once) used.add(i);
        return r;
      }
      return null;
    }
    return async function send(req){
      const bodyStr = req.body === undefined ? '' : (typeof req.body === 'string' ? req.body : JSON.stringify(req.body));
      const u = new URL(req.url);
      if (req.method === 'POST' && u.pathname.endsWith('/$batch')) {
        const version = u.pathname.split('/')[1];
        const body = typeof req.body === 'string' ? JSON.parse(req.body) : req.body;
        const responses = body.requests.map(inner => {
          const r = match('GET', `${GRAPH}/${version}${inner.url}`, '');
          return {id: inner.id, status: r ? r.status : 404, headers: (r && r.headers) || {}, body: r ? clone(r.body) : clone(missing)};
        });
        return {status: 200, headers: headersOf({}), body: {responses}, sample: true};
      }
      const r = match(req.method, req.url, bodyStr);
      if (!r) return {status: 404, headers: headersOf({}), body: clone(missing), sample: true};
      return {status: r.status, headers: headersOf(r.headers), body: clone(r.body), sample: true};
    };
  }

  return {create, sampleSender, headersOf, get, first, text, matches, fillUrl, fillBody, parseCsv, toCsv, csvCell, cell, counts, carryItems, retryAfter, explain, GRAPH};
})();
if (typeof module !== 'undefined' && module.exports) module.exports = MGCRunner;
