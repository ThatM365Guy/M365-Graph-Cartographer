/* MGC live runner: the read-only guard.
   Every request the runner makes goes through check() before it is sent, sample runs included. It allows:
     - only https://graph.microsoft.com/v1.0/... or /beta/...
     - GET (with no body), plus POST to a path on the read-only allow list (scripts/allowlist.json, shared with the
       scenario scripts), plus POST /$batch when every request inside it is a GET to an allowed Graph path
     - only delegated scopes whose names end in .Read or .Read.All
   Anything else is refused before it is sent, with a reason in plain words. The guard knows nothing about any scenario.
   It runs in the page and under Node (tests/test_live.py). */
const MGCGuard = (() => {
  const HOST = 'graph.microsoft.com';
  const VERSIONS = ['v1.0', 'beta'];
  const MAX_BATCH = 20;   // Learn: JSON batch requests are limited to 20 individual requests
  const SCOPE_RX = /^[A-Za-z][A-Za-z0-9-]*(\.[A-Za-z0-9-]+)*\.Read(\.All)?$/;
  // A name can end .Read and still sound like a write (Mail.ReadWrite.Read is no real permission, but the guard doesn't rely on that).
  const WRITE_WORDS = /Write|Send|Manage|FullControl|Create|Delete|Update/i;
  const OIDC = ['openid', 'profile', 'email', 'offline_access'];
  const BATCH_HEADERS = ['consistencylevel'];
  const BATCH_KEYS = ['id', 'method', 'url', 'headers', 'dependsOn'];   // exact names; anything else is refused
  const SEGMENT = '[A-Za-z0-9!,._~-]+';   // what an {id} in an allow-listed path may be: no %, ;, : or slashes

  // "POST /drives/{id}/items/{id}/extractSensitivityLabels" -> {method, rx}. {x} matches one path segment.
  function compile(call){
    const m = /^\s*([A-Z]+)\s+(\/\S*)\s*$/.exec(String(call || ''));
    if (!m) return null;
    const parts = m[2].split('/').map(seg => /^\{[^}]+\}$/.test(seg) ? SEGMENT :seg.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'));
    return {method: m[1], rx: new RegExp('^' + parts.join('/') + '$')};
  }
  // The allow list file: {"uris": {"<key>": {"call": "POST /path/{id}", ...}}}. Only POST entries count here.
  function postRules(allow){
    const out = [];
    for (const v of Object.values((allow && allow.uris) || {})) {
      const r = compile(v && v.call);
      if (r && r.method === 'POST') out.push(r);
    }
    return out;
  }
  // -> {version, path, search} for a URL on Graph, or a refusal reason.
  function parseGraphUrl(raw){
    let u;
    try { u = new URL(String(raw)); } catch (e) { return {error: 'The address is not a valid URL.'}; }
    if (u.protocol !== 'https:') return {error: 'Only https addresses are allowed.'};
    if (u.username || u.password) return {error: 'Addresses with a user name or password are not allowed.'};
    if (u.hostname !== HOST || u.port) return {error: `Only ${HOST} is allowed, not ${u.host}.`};
    const segs = u.pathname.split('/');   // ['', 'v1.0', ...] after the URL parser has resolved any .. segments
    if (!VERSIONS.includes(segs[1])) return {error: 'Only the v1.0 and beta versions of Microsoft Graph are allowed.'};
    const path = '/' + segs.slice(2).join('/');
    if (path === '/') return {error: 'The address has no Graph path.'};
    return {version: segs[1], path, search: u.search};
  }
  const isReadScope = s => typeof s === 'string' && SCOPE_RX.test(s) && !WRITE_WORDS.test(s);
  function checkScopes(scopes){
    if (!Array.isArray(scopes) || !scopes.length) return 'The step names no permission to ask for.';
    for (const s of scopes) {
      if (!isReadScope(s)) return `The permission "${s}" is not read-only. Only permissions ending .Read or .Read.All are allowed.`;
    }
    return '';
  }
  // The permissions an access token carries (MSAL's result.scopes) cover everything consented for the app, not just
  // what the step asked for. Returns the ones that aren't read-only, apart from the sign-in ones.
  function writeScopesIn(granted){
    return (granted || []).map(x => String(x).replace(/^https:\/\/graph\.microsoft\.com\//i, ''))
      .filter(x => !OIDC.includes(x.toLowerCase()) && !isReadScope(x));
  }
  function checkBatch(body, version){
    const b = body;   // an object: the runner sends JSON.stringify of exactly this
    if (!b || typeof b !== 'object' || Array.isArray(b) || !Array.isArray(b.requests)) return 'A batch needs a list of requests.';
    const keys = Object.keys(b).filter(k => k !== 'requests');
    if (keys.length) return `The batch body has unexpected fields: ${keys.join(', ')}.`;
    if (!b.requests.length) return 'The batch is empty.';
    if (b.requests.length > MAX_BATCH) return `A batch can hold at most ${MAX_BATCH} requests.`;
    const ids = new Set();
    for (const r of b.requests) {
      if (!r || typeof r !== 'object' || Array.isArray(r)) return 'A request inside the batch is not an object.';
      const extra = Object.keys(r).filter(k => !BATCH_KEYS.includes(k));
      if (extra.length) return `A request inside the batch has fields that aren't allowed: ${extra.join(', ')}.`;
      const id = String(r.id ?? '');
      if (!id || ids.has(id)) return 'Every request inside a batch needs its own id.';
      ids.add(id);
      if (r.method !== 'GET') return `The batch contains a "${String(r.method)}" request. Only GET is allowed inside a batch.`;
      if ('body' in r) return 'A GET request inside a batch cannot have a body.';
      for (const h of Object.keys(r.headers || {})) {
        if (!BATCH_HEADERS.includes(h.toLowerCase())) return `The header "${h}" is not allowed inside a batch.`;
      }
      const url = String(r.url || '');
      if (!url.startsWith('/') || url.startsWith('//') || /^\/?[a-z][a-z0-9+.-]*:/i.test(url) || url.includes('\\')) {
        return 'Requests inside a batch must use a relative Graph path, such as /sites.';
      }
      // checked as written, because Graph, not the browser, resolves the address of a request inside a batch
      if (/(^|\/)\.\.?(\/|\?|$)|%2e|%2f|%5c|\s/i.test(url)) return 'A request inside a batch has dots, encoded slashes or spaces in its path, which aren’t allowed.';
      const inner = parseGraphUrl(`https://${HOST}/${version}${url}`);
      if (inner.error) return inner.error;
      if (inner.path.split('/').includes('$batch')) return 'A batch cannot contain another batch.';
    }
    return '';
  }
  /* req: {method, url, body, scopes}; allow: the parsed scripts/allowlist.json. Returns {ok: true} or {ok: false, reason}. */
  function check(req, allow){
    const no = reason => ({ok: false, reason});
    if (!req || typeof req !== 'object') return no('There is no request to check.');
    const method = req.method;   // exact capitals: the runner sends exactly what was checked
    if (typeof method !== 'string' || !/^[A-Z]+$/.test(method)) return no('The request method must be written in capitals, such as GET.');
    const scopeErr = checkScopes(req.scopes);
    if (scopeErr) return no(scopeErr);
    const p = parseGraphUrl(req.url);
    if (p.error) return no(p.error);
    // the body is sent as JSON.stringify(body), so it is either absent or a plain object
    if (req.body !== undefined && (req.body === null || typeof req.body !== 'object' || Array.isArray(req.body))) return no('The request body must be a JSON object.');
    if (method === 'GET') {
      if (req.body !== undefined) return no('A GET request cannot have a body.');
      if (p.path.split('/').includes('$batch')) return no('A batch must be sent with POST.');
      return {ok: true};
    }
    if (method === 'POST') {
      if (p.path === '/$batch') {
        if (p.search) return no('A batch address cannot have a query string.');
        const err = checkBatch(req.body, p.version);
        return err ? no(err) : {ok: true};
      }
      if (postRules(allow).some(r => r.rx.test(p.path))) return {ok: true};
      return no(`POST ${p.path} is not on the read-only allow list. MGC only sends requests that read data.`);
    }
    return no(`A ${method} request can change data. MGC only sends requests that read data.`);
  }
  return {check, checkScopes, isReadScope, writeScopesIn, parseGraphUrl, postRules, MAX_BATCH};
})();
if (typeof module !== 'undefined' && module.exports) module.exports = MGCGuard;
