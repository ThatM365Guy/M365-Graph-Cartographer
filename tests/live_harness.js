/* Test harness for the live runner (tests/test_live.py): runs the page's own web/live/guard.js and runner.js under
   Node. Reads {allow, tasks: [...]} as JSON on stdin and writes one result per task as JSON on stdout. */
const fs = require('fs'), path = require('path');
const root = path.join(__dirname, '..');
const G = require(path.join(root, 'web', 'live', 'guard.js'));
const R = require(path.join(root, 'web', 'live', 'runner.js'));
const GRAPH = 'https://graph.microsoft.com';
const input = JSON.parse(fs.readFileSync(0, 'utf8'));
const allow = input.allow;

const fill = s => String(s).replace(/\{[A-Za-z0-9_.]+\}/g, 'x');
const reply = (status, body, headers) => ({status, body, headers: R.headersOf(headers || {})});

async function task(t){
  switch (t.kind) {
    case 'guard': return G.check(t.req, t.allow || allow);
    case 'liveBlocks': {   // every call of every live block, with placeholders filled, must pass the guard
      const out = [];
      for (const s of t.scenarios) s.steps.forEach((st, i) => {
        const lv = st.live; if (!lv) return;
        for (const c of lv.calls || []) {
          const body = c.body === undefined ? undefined : JSON.parse(fill(JSON.stringify(c.body)));
          const req = {method: c.method, url: GRAPH + fill(c.url), body, scopes: lv.scopes};
          out.push({where: `${s.id} step ${i + 1}`, verdict: G.check(req, allow)});
          if (c.batch) {
            const inner = fill(c.url).replace(/^\/(v1\.0|beta)/, '');
            const b = {method: 'POST', url: GRAPH + c.url.split('/').slice(0, 2).join('/') + '/$batch', scopes: lv.scopes,
                       body: {requests: Array.from({length: 20}, (_, k) => ({id: String(k), method: 'GET', url: inner}))}};
            out.push({where: `${s.id} step ${i + 1} batch`, verdict: G.check(b, allow)});
          }
        }
      });
      return out;
    }
    case 'runSamples': {   // the whole scenario on its sample files, carrying the default ticks forward
      const carry = {}, steps = [];
      for (let i = 0; i < t.scenario.steps.length; i++) {
        const lv = t.scenario.steps[i].live;
        if (!lv || !(lv.calls || []).length) { steps.push(null); continue; }
        const log = [];
        const eng = R.create({send: R.sampleSender(t.samples[String(i)] || []), allow, sleep: async () => {}, onLog: e => log.push(e)});
        const carried = lv.from ? (carry[lv.from.carry] || []).filter(x => x.tick) : undefined;
        const res = await eng.runStep(lv, {input: lv.input && lv.input.default, carried});
        if (lv.carry) carry[lv.carry.name] = res.carry;
        steps.push({rows: res.rows.length, counts: Object.fromEntries(res.counts.map(c => [c.label, c.value])), errors: res.errors,
                    refused: res.refused || null, statuses: log.map(e => e.status), inner: log.map(e => (e.inner || []).map(x => x.status)),
                    cells: res.rows.slice(0, 3).map(r => lv.columns.map(c => R.cell(r, c)))});
      }
      return steps;
    }
    case 'throttle': {   // 429 with Retry-After 7, then 200: the runner waits 7 s and tries again
      const waits = [], log = []; let n = 0;
      const eng = R.create({allow, sleep: async ms => { waits.push(ms); }, onLog: e => log.push(e),
        send: async () => (++n === 1 ? reply(429, {error: {code: 'TooManyRequests'}}, {'Retry-After': '7'}) : reply(200, {value: [{id: 'a'}]}))});
      const res = await eng.runStep({scopes: ['Sites.Read.All'], calls: [{method: 'GET', url: '/v1.0/sites?search=x', rows: 'value', as: 'site'}],
                                     columns: [{label: 'Id', from: 'site.id'}]}, {});
      return {waits, statuses: log.map(e => e.status), rows: res.rows.length};
    }
    case 'throttleGivesUp': {   // always 429: three attempts, then a plain-words failure
      const log = [];
      const eng = R.create({allow, sleep: async () => {}, onLog: e => log.push(e), send: async () => reply(429, {}, {'Retry-After': '1'})});
      const res = await eng.runStep({scopes: ['Sites.Read.All'], calls: [{method: 'GET', url: '/v1.0/sites?search=x', rows: 'value', as: 'site'}],
                                     columns: [{label: 'Id', from: 'site.id'}]}, {});
      return {attempts: log.length, errors: res.errors};
    }
    case 'batching': {   // 45 items: three batches (20, 20, 5); one inner 429 is retried in a new batch
      const sizes = []; let throttled = false; const waits = [];
      const eng = R.create({allow, sleep: async ms => { waits.push(ms); }, send: async req => {
        sizes.push(req.body.requests.length);
        return reply(200, {responses: req.body.requests.map(r => {
          if (r.id === '3' && !throttled) { throttled = true; return {id: r.id, status: 429, headers: {'Retry-After': '4'}, body: {}}; }
          return {id: r.id, status: 200, body: {id: 'd-' + r.id}};
        })});
      }});
      const carried = Array.from({length: 45}, (_, i) => ({key: 'k' + i, value: {id: 's' + i}}));
      const res = await eng.runStep({scopes: ['Files.Read.All'], from: {carry: 'sites', as: 'site'},
        calls: [{method: 'GET', url: '/v1.0/sites/{site.id}/drive', as: 'drive', batch: true}], columns: [{label: 'Drive', from: 'drive.id'}]}, {carried});
      return {sizes, waits, rows: res.rows.length, errors: res.errors, firstDrive: R.cell(res.rows[0], {from: 'drive.id'})};
    }
    case 'foreignNextLink': {   // a nextLink to another host is refused by the guard, so the step is refused
      const sent = [];
      const eng = R.create({allow, sleep: async () => {}, send: async req => { sent.push(req.url); return reply(200, {value: [{id: 1}], '@odata.nextLink': 'https://graph.microsoft.com.evil.example/v1.0/sites?page=2'}); }});
      const res = await eng.runStep({scopes: ['Sites.Read.All'], calls: [{method: 'GET', url: '/v1.0/sites?search=x', rows: 'value', as: 'site', pages: 3}],
                                     columns: [{label: 'Id', from: 'site.id'}]}, {});
      return {sent, refused: res.refused || null};
    }
    case 'missingValue': {   // an item without the value its address needs fails on its own; the others run
      const sent = [];
      const eng = R.create({allow, sleep: async () => {}, send: async req => { sent.push(req.url); return reply(200, {value: {labels: []}}); }});
      const carried = [{key: 'a', value: {id: 'f1', parentReference: {driveId: 'd1'}}}, {key: 'b', value: {id: 'f2'}}];
      const res = await eng.runStep({scopes: ['Files.Read.All'], from: {carry: 'files', as: 'file'},
        calls: [{method: 'POST', url: '/v1.0/drives/{file.parentReference.driveId}/items/{file.id}/extractSensitivityLabels', rows: 'value', as: 'res', perItemErrors: true}],
        columns: [{label: 'File', from: 'file.id'}, {label: 'Problem', from: '_error', error: true}]}, {carried});
      return {sent, rows: res.rows.length, errors: res.errors.length};
    }
    case 'notes': {   // a 403 uses the step's own plain-words note
      const eng = R.create({allow, sleep: async () => {}, send: async () => reply(403, {error: {code: 'Forbidden', message: 'nope'}})});
      const res = await eng.runStep({scopes: ['Reports.Read.All'], notes: {'403': 'Needs a reports role.'},
        calls: [{method: 'GET', url: "/v1.0/copilot/reports/getMicrosoft365CopilotUsageUserDetail(period='D28')", format: 'csv', as: 'u'}],
        columns: [{label: 'User', from: 'u.User Principal Name'}]}, {});
      return {errors: res.errors};
    }
    case 'writeScopes': return G.writeScopesIn(t.scopes);
    case 'postNoRetry': {   // a POST is retried on 429 only; a 503 may mean it ran, so it isn't sent twice
      let n = 0; const log = [];
      const eng = R.create({allow, sleep: async () => {}, onLog: e => log.push(e), send: async () => { n++; return reply(503, {}); }});
      await eng.runStep({scopes: ['Files.Read.All'], calls: [{method: 'POST', url: '/v1.0/search/query', body: {requests: []}, rows: 'value', as: 'h'}],
                         columns: [{label: 'x', from: 'h'}]}, {});
      return {sent: n, statuses: log.map(e => e.status)};
    }
    case 'csv': return {out: R.toCsv(t.columns, t.rows), parsed: R.parseCsv(t.text)};
    default: throw new Error('unknown task ' + t.kind);
  }
}
(async () => {
  const out = [];
  for (const t of input.tasks) out.push(await task(t));
  process.stdout.write(JSON.stringify(out));
})().catch(e => { process.stderr.write(String(e && e.stack || e)); process.exit(1); });
