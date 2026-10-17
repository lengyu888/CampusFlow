import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { test } from 'node:test';

const read = path => readFileSync(new URL(`../entry/src/main/ets/${path}`, import.meta.url), 'utf8');
const noImports = source => source.replace(/^import [\s\S]*? from '[^']+';\r?\n/gm, '');
const utility = async name => import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(noImports(read(`utils/${name}.ets`)))).toString('base64')}`);
const evidence = await utility('EvidencePresentation');
const feedback = await utility('AgentFeedback');
const now = Date.parse('2026-10-18T03:00:00Z');
const source = (extra = {}) => ({ source_id: 'weather:city', label: '公开天气来源', kind: 'remote', status: 'fresh',
  updated_at: '2026-10-18T02:55:00Z', expires_at: '2026-10-18T03:10:00Z', url: 'https://open-meteo.com/', note: '城市级预报。', ...extra });
const forecast = (extra = {}) => ({ date: '2026-10-18', location_label: '杭州城市级预报', available: true, condition: '多云',
  temperature_min_c: 17, temperature_max_c: 24, precipitation_probability: 20, evidence: [source()], ...extra });
const deferred = () => { let resolve, reject; const promise = new Promise((a, b) => { resolve = a; reject = b; }); return { promise, resolve, reject }; };
const flush = async () => { for (let i = 0; i < 6; i++) await Promise.resolve(); };

test('source absence, malformed fields and legacy results are unverified, never fresh', () => {
  for (const items of [undefined, null, [], 'bad', [null], [{ label: '未带时间' }]]) {
    assert.match(evidence.evidenceSummary(items, now), /待核验/);
    assert.equal(evidence.hasFreshEvidence(items, now), false);
  }
  for (const stamp of [null, '', '2026-02-30T00:00:00Z', '2026-10-18T24:00:00Z', '2026-10-18 11:00:00', '2099-01-01T00:00:00Z']) {
    assert.equal(evidence.evidenceStatus(source({ updated_at: stamp }), now), 'unverified');
  }
});

test('expiry is recomputed from current time, and malformed or reversed expiry cannot become unlimited', () => {
  const item = source();
  assert.equal(evidence.evidenceStatus(item, now), 'fresh');
  assert.equal(evidence.evidenceStatus(item, Date.parse(item.expires_at)), 'stale');
  assert.match(evidence.evidenceSummary([item], now + 600000), /已过期/);
  assert.equal(item.status, 'fresh', 'the original server projection is not mutated');
  for (const expiry of ['bad', '2026-02-30T00:00:00Z', '2026-10-18T02:50:00Z', undefined]) {
    assert.equal(evidence.hasFreshEvidence([source({ expires_at: expiry })], now), false);
  }
  assert.equal(evidence.hasFreshEvidence([source({ kind: 'user', expires_at: null })], now), true);
  assert.equal(evidence.hasFreshEvidence([source({ kind: 'demo' })], now), false);
});

test('explicit error, missing and stale source states are not promoted by newer client clocks', () => {
  for (const status of ['error', 'missing', 'stale', 'unverified']) {
    assert.equal(evidence.evidenceStatus(source({ status }), now), status);
  }
  assert.match(evidence.evidenceSummary([source(), source({ status: 'missing' })], now), /尚无数据/);
  assert.equal(evidence.evidenceTime('2026-10-18T03:00:00Z'), '2026-10-18 11:00:00（上海）');
  assert.equal(evidence.evidenceTime('2026-10-18T11:00:00+08:00'), '2026-10-18 11:00:00（上海）');
  assert.equal(evidence.evidenceTime(null), '未提供');
});

test('only public HTTPS attribution without credentials, queries or fragments is copyable', () => {
  for (const url of [null, '', 'http://example.com', 'https://u:p@example.com', 'https://example.com/?token=secret',
    'https://example.com/#key', 'https://127.0.0.1/', 'https://192.168.1.2', 'https://localhost/',
    'https://a.local/', 'https://a.internal/', 'https://[::1]/', 'https://example.com:8080', 'https://example.com\\@evil.invalid',
    'https://-bad.example/', 'https://example.com\n']) { assert.equal(evidence.publicSourceUrl(url), null, String(url)); }
  assert.equal(evidence.publicSourceUrl('https://open-meteo.com/en/docs'), 'https://open-meteo.com/en/docs');
});

test('evidence uses an isolated whitelist projection and explains excess sources', () => {
  const item = source({ url: 'https://example.com/?token=private', raw: { token: 'private' }, arguments: 'private' });
  const result = evidence.normalizeEvidence([item]);
  assert.equal(result[0].url, null); assert.equal(JSON.stringify(result).includes('private'), false);
  result[0].label = 'edited'; assert.equal(item.label, '公开天气来源');
  const many = evidence.normalizeEvidence(Array.from({ length: 33 }, () => source()));
  assert.equal(many.length, 33); assert.match(many[32].note, /超过/);
});

test('unknown opening and old unverified boolean never claim a location is closed or open', () => {
  assert.equal(evidence.openingStatus({ open_now: null, evidence: [source()] }, now), '当前开放状态未知');
  assert.equal(evidence.openingStatus({ open_now: false }, now), '当前开放状态未知');
  assert.equal(evidence.openingStatus({ open_now: true, evidence: [source()] }, now), '来源记录：开放中');
  assert.equal(evidence.openingStatus({ open_now: false, evidence: [source()] }, now + 600000), '当前开放状态未知');
});

test('weather validates date, units, bounded numeric fields and source availability without placeholders', () => {
  assert.equal(evidence.validWeather(forecast(), '2026-10-18'), true);
  assert.equal(evidence.weatherUsable(forecast(), now), true);
  assert.equal(evidence.weatherUsable(forecast(), now + 600000), false);
  assert.equal(evidence.weatherUsable(forecast({ evidence: [] }), now), false);
  for (const extra of [{ date: '2026-10-17' }, { temperature_min_c: '17' }, { temperature_max_c: Infinity },
    { temperature_min_c: 25 }, { precipitation_probability: 101 }, { precipitation_probability: null },
    { condition: null }, { evidence: null }]) { assert.equal(evidence.validWeather(forecast(extra), '2026-10-18'), false); }
  const missing = forecast({ available: false, condition: null, temperature_min_c: null, temperature_max_c: null, precipitation_probability: null });
  assert.equal(evidence.validWeather(missing, '2026-10-18'), true); assert.equal(evidence.weatherUsable(missing, now), false);
  assert.equal(evidence.weatherUsable(null, now), false);
});

function nativeMethods(path, name, marker) {
  return noImports(read(path).split(marker)[0]).replace(/^@Component\r?\n/gm, '')
    .replace(/@(State|Prop)\s+|@Watch\('[^']+'\)\s*/g, '').replace(`export struct ${name}`, `class ${name}`) + '\n}';
}
const campusCode = nativeMethods('pages/CampusPage.ets', 'CampusPage', '\n  @Builder');
function campusSetup(hook = async () => forecast()) {
  const calls = [], timers = new Map(); let clock = now, nextTimer = 1;
  class FakeDate extends Date { static now() { return clock; } }
  class Api { constructor(base, token) { this.base = base; this.token = token; } weather(date) { calls.push([date, this.base, this.token]); return hook(date); } }
  const Page = new Function('CampusFlowApi', 'Scroller', 'shanghaiDate', 'validWeather', 'weatherUsable', 'Date', 'setInterval', 'clearInterval',
    stripTypeScriptTypes(campusCode) + '\nreturn CampusPage;')(Api, class Scroller {}, ms => new Date(ms + 28800000).toISOString().slice(0, 10),
    evidence.validWeather, evidence.weatherUsable, FakeDate, fn => { const id = nextTimer++; timers.set(id, fn); return id; }, id => timers.delete(id));
  const page = new Page(); page.baseUrl = 'https://fixture.invalid'; page.token = 'fixture-only';
  page.user = { user_id: 'a', school: '杭州电子科技大学', campus: '下沙校区' }; page.pageActive = true;
  return { page, calls, timers, advance(ms) { clock += ms; for (const fn of timers.values()) fn(); } };
}

test('weather card queries actual Shanghai date, expires while open, and cleans timers on hide/dispose', async () => {
  const f = campusSetup(); f.page.aboutToAppear(); await flush();
  assert.deepEqual(f.calls[0], ['2026-10-18', 'https://fixture.invalid', 'fixture-only']);
  assert.equal(f.page.currentForecast(), true); assert.equal(f.timers.size, 1);
  f.advance(600000); assert.equal(f.page.currentForecast(), false);
  f.page.active = false; f.page.activeChanged(); assert.equal(f.timers.size, 0);
  f.page.active = true; f.page.activeChanged(); await flush(); assert.equal(f.calls.length, 2);
  f.page.aboutToDisappear(); assert.equal(f.timers.size, 0);
});

test('latest weather request wins and hidden, changed-account, changed-campus or changed-server responses cannot appear', async () => {
  const old = deferred(); let count = 0; const f = campusSetup(() => ++count === 1 ? old.promise : Promise.resolve(forecast({ condition: '新预报' })));
  const first = f.page.loadWeather(); await f.page.loadWeather(); old.resolve(forecast({ condition: '旧预报' })); await first;
  assert.equal(f.page.forecast.condition, '新预报');
  for (const mutation of [p => p.aboutToDisappear(), p => { p.active = false; p.activeChanged(); },
    p => p.token = 'other', p => p.baseUrl = 'https://other.invalid', p => p.user.user_id = 'b', p => p.user.campus = '其他校区']) {
    const pending = deferred(); const f2 = campusSetup(() => pending.promise); const read = f2.page.loadWeather(); mutation(f2.page);
    pending.resolve(forecast()); await read; assert.equal(f2.page.forecast, null);
  }
});

test('weather failure preserves labeled old record, rejects malformed success, and never leaks raw error', async () => {
  const f = campusSetup(async () => { throw Error('https://private/?key=SECRET'); }); f.page.forecast = forecast();
  await f.page.loadWeather(); assert.match(f.page.weatherError, /未完成/); assert.doesNotMatch(f.page.weatherError, /SECRET|private/);
  assert.equal(f.page.currentForecast(), false); assert.equal(f.page.forecast.condition, '多云');
  const bad = campusSetup(async () => forecast({ temperature_min_c: 'NaN' })); await bad.page.loadWeather();
  assert.equal(bad.page.forecast, null); assert.ok(bad.page.weatherError);
});

test('campus change invalidates cached weather even when user ID stays the same', async () => {
  const f = campusSetup(); await f.page.loadWeather();
  f.page.user.campus = '其他校区'; f.page.profileChanged(); await flush();
  assert.equal(f.calls.length, 2); assert.equal(f.page.weatherCampus, 'a|杭州电子科技大学|其他校区'); f.page.aboutToDisappear();
});

test('server or token change immediately clears a still-fresh forecast and loads in the new connection', async () => {
  for (const property of ['token', 'baseUrl']) {
    const pending = deferred(); let calls = 0;
    const f = campusSetup(() => ++calls === 1 ? Promise.resolve(forecast()) : pending.promise);
    await f.page.loadWeather(); assert.equal(f.page.currentForecast(), true);
    f.page[property] = property === 'token' ? 'new-account' : 'https://new.invalid'; f.page.connectionChanged();
    assert.equal(f.page.forecast, null); assert.equal(f.page.weatherLoading, true);
    pending.resolve(forecast({ condition: '新连接预报' })); await flush();
    assert.equal(f.page.forecast.condition, '新连接预报'); assert.equal(f.calls.length, 2); f.page.aboutToDisappear();
  }
});

test('actual Index CampusPage active binding matches visible campus route and foreground, never Skills route', () => {
  const index = read('pages/Index.ets');
  const block = index.slice(index.indexOf('CampusPage({'), index.indexOf('      Column() {', index.indexOf('CampusPage({')));
  const activeExpression = /active: ([^,\n]+)/.exec(block)?.[1];
  const visibleExpression = /\.visibility\(([^\n]+)\)/.exec(block)?.[1];
  assert.ok(activeExpression); assert.ok(visibleExpression);
  const active = new Function(`return ${activeExpression};`);
  const visible = new Function('Visibility', `return ${visibleExpression};`);
  const Visibility = { Visible: true, Hidden: false };
  for (const activeTab of [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]) {
    const view = { activeTab, voiceForeground: true };
    assert.equal(active.call(view), visible.call(view, Visibility), `route ${activeTab}`);
    assert.equal(active.call(view), activeTab === 8);
    assert.equal(active.call({ activeTab, voiceForeground: false }), false);
  }
});

test('source panel clock stops on hidden/unmounted views and late timer cannot update destroyed state', () => {
  const code = nativeMethods('components/EvidencePanel.ets', 'EvidencePanel', '\n  build()');
  const timers = new Map(); let clock = now, next = 1;
  class FakeDate extends Date { static now() { return clock; } }
  const Panel = new Function('Date', 'setInterval', 'clearInterval', 'normalizeEvidence', stripTypeScriptTypes(code) + '\nreturn EvidencePanel;')(
    FakeDate, fn => { const id = next++; timers.set(id, fn); return id; }, id => timers.delete(id), evidence.normalizeEvidence);
  const panel = new Panel(); panel.aboutToAppear(); const tick = [...timers.values()][0];
  const revision = panel.sourceRevision;
  clock += 600000; tick(); assert.equal(panel.now, clock); panel.toggle(); assert.equal(panel.expanded, true);
  assert.equal(panel.sourceRevision, revision, 'clock updates keep source row identity stable for copying');
  panel.sourcesChanged(); assert.equal(panel.sourceRevision, revision + 1);
  panel.active = false; panel.activeChanged(); assert.equal(timers.size, 0); const last = panel.now;
  clock += 30000; tick(); assert.equal(panel.now, last);
  panel.active = true; panel.activeChanged(); assert.equal(timers.size, 1); panel.aboutToDisappear(); assert.equal(timers.size, 0);
});

test('tool summary retains sources while rendering helper discards every undeclared source field', () => {
  const result = feedback.displayToolTraces([{ tool_name: 'secret-internal', result: { key: 'SECRET' },
    display: { label: '天气', state: 'success', summary: '城市预报', evidence: [source({ raw: 'SECRET' })] } }]);
  assert.equal(result[0].evidence.length, 1);
  assert.equal(JSON.stringify(evidence.normalizeEvidence(result[0].evidence)).includes('SECRET'), false);
  assert.equal(result[0].tool_name, undefined); assert.equal(result[0].result, undefined);
});

test('weather API is authenticated encoded GET, with safe errors and released HTTP client', async () => {
  const apiCode = noImports(read('services/CampusFlowApi.ets')).replace(/^import http[^\n]+\n/m, '').replace('export class CampusFlowApi', 'class CampusFlowApi');
  const calls = []; let destroyed = 0, fail = false;
  const http = { RequestMethod: { GET: 'GET' }, HttpDataType: { STRING: 'STRING' }, createHttp: () => ({
    request: async (url, options) => { calls.push([url, options]); return fail ? { responseCode: 500, result: '<html>SECRET</html>' }
      : { responseCode: 200, result: JSON.stringify(forecast()) }; }, destroy() { destroyed++; } }) };
  const Api = new Function('http', 'CampusFlowRequestError', 'localRequestFailure', 'requestFailure', stripTypeScriptTypes(apiCode) + '\nreturn CampusFlowApi;')(
    http, feedback.CampusFlowRequestError, feedback.localRequestFailure, feedback.requestFailure);
  const api = new Api('https://fixture.invalid', 'fixture-only'); const actual = await api.weather('2026-10-18&extra=1');
  assert.equal(actual.condition, '多云'); assert.match(calls[0][0], /date=2026-10-18%26extra%3D1$/);
  assert.equal(calls[0][1].method, 'GET'); assert.equal(calls[0][1].header.Authorization, 'Bearer fixture-only');
  fail = true; await assert.rejects(api.weather('2026-10-18'), error => !error.message.includes('SECRET') && error instanceof feedback.CampusFlowRequestError);
  assert.equal(destroyed, 2);
});
