import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { JSDOM } from 'jsdom';

const app = readFileSync(new URL('../../src/campusflow_agent/web/app.js', import.meta.url), 'utf8');
const html = readFileSync(new URL('../../src/campusflow_agent/web/index.html', import.meta.url), 'utf8');
const user = {user_id: 'owner', school: '杭州电子科技大学', campus: '下沙校区', display_name: '同学'};
const candidate = {name: '<img src=x onerror=alert(1)>入口', address: '杭州 · 校园东侧', baidu_uid: 'uid-one',
  location: {lat: 30.31, lng: 120.34}, selection_token: 'private-fixture-token'};
const selection = {place_id: 'library', name: candidate.name, address: candidate.address,
  baidu_uid: candidate.baidu_uid, location: candidate.location, confirmed_at: '2026-11-08T10:00:00Z'};
const snapshot = {package: {package_id: 'hdu-xiasha', school: user.school, campus: user.campus,
  version: '2026.11.8', description: '校园资料', place_count: 2, notice_count: 0}, notices: [], corrections: [],
  places: [{place_id: 'library', name: '图书信息中心', aliases: ['图书馆', '校图书馆'], category: '学习', selection: null},
    {place_id: 'teaching_a', name: '杭州电子科技大学第1教学楼', category: '教学', selection: null}]};
const page = (overrides = {}) => ({place_id: 'library', query: '图书信息中心', page: 0, page_size: 20,
  total: 1, has_more: false, truncated: false, candidates: [candidate], expires_at: '2099-11-08T10:00:00Z', ...overrides});
const mapConfig = {configured: true, browser_ak: 'fixture-public-browser-ak', route_configured: true,
  campus_query: '杭州电子科技大学下沙校区', city: '杭州市'};
const settle = async () => { for (let i = 0; i < 6; i++) await new Promise(resolve => setTimeout(resolve, 0)); };

function environment(responder = () => page()) {
  const dom = new JSDOM(html, {url: 'http://localhost/', runScripts: 'outside-only', pretendToBeVisual: true});
  const calls = [];
  dom.window.fetch = async (path, options = {}) => {
    const call = {path: String(path), method: options.method ?? 'GET',
      body: options.body ? JSON.parse(options.body) : null, signal: options.signal};
    calls.push(call);
    const value = call.path === '/api/v1/me/baidu-maps/config' ? mapConfig : await responder(call, calls.length);
    return {ok: !value?.error, status: value?.error ? 422 : 200, json: async () => value?.error ? value.error : value};
  };
  dom.window.fixtureSnapshot = structuredClone(snapshot);
  dom.window.fixtureUser = structuredClone(user);
  dom.window.eval(`${app.replace(/initialize\(\);\s*$/, '')}
    state.user = window.fixtureUser;
    state.sessionId = 'chat-one';
    state.settingsTab = 'data';
    elements.authView.hidden = true;
    elements.appView.hidden = true;
    elements.settingsView.hidden = false;
    document.querySelector('[data-settings-panel="data"]').hidden = false;
    renderCampusData(window.fixtureSnapshot);
    window.fixture = {
      changeUser: (change) => { Object.assign(state.user, change); syncCampusPlaceSelection(); syncCampusRouteMaps();
        if (typeof syncBaiduMapSettings === 'function') syncBaiduMapSettings(); },
      changeSession: () => { state.sessionId = 'chat-two'; syncCampusPlaceSelection(); },
      hide: () => showOnly('auth'),
      switchTab: () => { state.settingsTab = 'profile'; syncCampusPlaceSelection(); },
      openMapSettings: () => switchSettingsTab('profile'),
      renderRoute: route => renderCampusRoute(route),
      sync: () => syncCampusPlaceSelection(),
      reload: () => loadCampusData(),
      render: value => renderCampusData(value),
    };`);
  const document = dom.window.document;
  const submit = () => document.getElementById('campusPlaceSearchForm')?.dispatchEvent(new dom.window.Event('submit', {bubbles: true, cancelable: true}));
  return {dom, window: dom.window, document, calls, submit,
    panel: () => document.getElementById('campusPlaceSelectionPanel'),
    select: () => document.getElementById('campusPlaceSelect'),
    query: () => document.getElementById('campusPlaceQuery'),
    status: () => document.getElementById('campusPlaceSelectionStatus')?.textContent ?? ''};
}

test('campus data offers explicit candidate preview and confirmation; refreshing preserves the selected place', async () => {
  let saved = false;
  const f = environment(call => {
    if (call.method === 'PUT') {saved = true; return selection;}
    if (call.path === '/api/v1/campus-data') return {...snapshot,
      places: snapshot.places.map(place => place.place_id === 'library' ? {...place, selection} : place)};
    return page();
  });
  assert.ok(f.panel(), 'campus data must expose a place confirmation panel');
  assert.equal(f.select().options.length, 2);
  assert.deepEqual(Array.from(f.select().options, option => [option.value, option.textContent]),
    [['library', '图书馆'], ['teaching_a', '杭州电子科技大学第1教学楼']]);
  assert.equal(f.document.getElementById('campusPlaceConfirmButton').disabled, true);
  f.query().value = '图书信息中心 东门';
  f.submit(); await settle();
  const query = new URL(f.calls[0].path, 'http://localhost');
  assert.equal(query.pathname, '/api/v1/campus-data/places/library/candidates');
  assert.equal(query.searchParams.get('page'), '0');
  assert.equal(query.searchParams.get('query'), '图书信息中心 东门');
  assert.match(f.panel().textContent, /校园东侧/);
  assert.ok(f.panel().textContent.includes(candidate.name), 'candidate preview must keep the actual provider name');
  assert.equal(f.panel().querySelector('img'), null, 'candidate names must remain plain text');
  assert.equal(saved, false);
  f.document.querySelector('[data-campus-place-preview]').click();
  const iframe = f.panel().querySelector('iframe'); assert.ok(iframe);
  assert.equal(iframe.getAttribute('src'), '/static/baidu-map.html?v=3&managed=1');
  const states = [];
  iframe.contentWindow.CampusFlowMap = {setConfig: value => states.push(value), setState: value => states.push(value),
    clear: () => states.push('clear')};
  iframe.dispatchEvent(new f.window.Event('load'));
  await settle();
  assert.deepEqual(structuredClone(states[0]), mapConfig);
  assert.equal(states.at(-1).origin.location.lat, 30.31);
  assert.equal(states.at(-1).active, true);
  assert.doesNotMatch(JSON.stringify(states), /private-fixture-token|selection_token|baidu_uid|owner/);
  assert.equal(saved, false);
  f.document.getElementById('campusPlaceConfirmButton').click(); await settle();
  assert.equal(saved, true);
  const put = f.calls.find(call => call.method === 'PUT');
  assert.equal(put.path, '/api/v1/campus-data/places/library/selection');
  assert.deepEqual(put.body, {selection_token: 'private-fixture-token'});
  assert.equal(f.select().value, 'library');
  assert.equal(f.select().selectedOptions[0].textContent, '图书馆 · 已确认');
  assert.match(f.document.getElementById('campusPlaceSavedSelection').textContent, /已确认.*校园东侧/s);
  assert.equal(f.document.getElementById('campusPlaceConfirmButton').disabled, true);
  f.document.getElementById('campusPlaceReselectButton').click(); await settle();
  assert.equal(f.calls.at(-1).method, 'GET');
  assert.match(f.calls.at(-1).path, /\/candidates\?/);
  f.dom.window.close();
});

test('account map settings omit blank passwords, clear a single override and rebuild existing route maps', async t => {
  const account = {configured: true, source: 'account', hint: 'private-raw-fixture'};
  const server = {configured: true, source: 'server', hint: null};
  const f = environment(call => call.method === 'PUT'
    ? {browser: call.body.browser_ak === null ? server : account, server, server_ak: 'raw-returned-fixture'}
    : {browser: account, server});
  t.after(() => f.dom.window.close());
  f.window.fixture.openMapSettings();
  await settle();
  const form = f.document.getElementById('baiduMapSettingsForm');
  assert.ok(form);
  const browser = f.document.getElementById('baiduBrowserAk');
  const backend = f.document.getElementById('baiduServerAk');
  assert.equal(browser.type, 'password');
  assert.equal(backend.type, 'password');
  assert.equal(browser.value + backend.value, '');
  assert.match(f.document.getElementById('baiduBrowserStatus').textContent, /个人配置/);
  assert.match(f.document.getElementById('baiduServerStatus').textContent, /服务器配置/);

  const submit = () => form.dispatchEvent(new f.window.Event('submit', {bubbles: true, cancelable: true}));
  submit(); await settle();
  assert.equal(f.calls.some(call => call.method === 'PUT'), false);
  f.window.fixture.renderRoute({provider: 'baidu', coordinate_system: 'bd09ll',
    origin: snapshot.places[0], destination: snapshot.places[1]});
  const oldMap = f.document.querySelector('.campus-route-map iframe');
  assert.ok(oldMap);
  browser.value = 'new-fixture-browser-ak';
  backend.value = '   ';
  submit(); await settle();
  assert.deepEqual(f.calls.filter(call => call.method === 'PUT').map(call => call.body),
    [{browser_ak: 'new-fixture-browser-ak'}]);
  assert.equal(browser.value + backend.value, '');
  assert.equal(oldMap.isConnected, false);
  assert.ok(f.document.querySelector('.campus-route-map iframe'));

  f.document.getElementById('clearBaiduBrowserAk').click(); await settle();
  assert.deepEqual(f.calls.filter(call => call.method === 'PUT').at(-1).body, {browser_ak: null});
  assert.match(f.document.getElementById('baiduBrowserStatus').textContent, /服务器配置/);
  assert.doesNotMatch(form.textContent, /private-raw-fixture|raw-returned-fixture|new-fixture-browser-ak/);
});

test('an earlier account saving a map key cannot replace the current settings', async t => {
  const account = {configured: true, source: 'account', hint: '•••• test'};
  const server = {configured: true, source: 'server', hint: null};
  let resolveSave;
  let initial = true;
  const f = environment(call => {
    if (call.method === 'PUT') return new Promise(resolve => { resolveSave = resolve; });
    const browser = initial ? account : server;
    initial = false;
    return {browser, server};
  });
  t.after(() => f.dom.window.close());
  f.window.fixture.openMapSettings();
  await settle();
  const browser = f.document.getElementById('baiduBrowserAk');
  const status = f.document.getElementById('baiduBrowserStatus');
  browser.value = 'old-account-fixture';
  f.document.getElementById('baiduMapSettingsForm').dispatchEvent(new f.window.Event('submit', {bubbles: true, cancelable: true}));
  assert.equal(typeof resolveSave, 'function');
  f.window.fixture.changeUser({user_id: 'another-account'});
  await settle();
  assert.equal(browser.value, '');
  assert.match(status.textContent, /服务器配置/);
  resolveSave({browser: account, server});
  await settle();
  assert.match(status.textContent, /服务器配置/);
  assert.doesNotMatch(f.document.getElementById('baiduMapSettingsStatus').textContent, /已更新/);
});

test('empty candidate pages keep explicit pagination and never select the first returned candidate', async () => {
  const f = environment(call => new URL(call.path, 'http://localhost').searchParams.get('page') === '0'
    ? page({candidates: [], total: 44, has_more: true})
    : page({page: 1, total: 44, has_more: true}));
  assert.ok(f.panel(), 'campus data must expose candidate pagination');
  f.submit(); await settle();
  assert.match(f.status(), /本页|更多/);
  assert.equal(new URL(f.calls[0].path, 'http://localhost').searchParams.has('query'), false,
    'empty search must let the backend use its canonical Baidu name');
  const more = f.document.getElementById('campusPlaceMoreButton');
  assert.equal(more.hidden, false); more.click(); await settle();
  assert.equal(new URL(f.calls[1].path, 'http://localhost').searchParams.get('page'), '1');
  assert.equal(f.document.querySelectorAll('[data-campus-place-preview]').length, 1);
  assert.equal(f.document.getElementById('campusPlaceConfirmButton').disabled, true);
  assert.equal(f.calls.some(call => call.method === 'PUT'), false);
  f.dom.window.close();
});

test('place, query, account, session, service, school, tab and visibility changes discard pending candidate replies', async () => {
  for (const change of ['place', 'query', 'owner', 'session', 'service', 'school', 'campus', 'tab', 'view', 'hidden']) {
    let resolve;
    const f = environment(() => new Promise(done => {resolve = done;}));
    assert.ok(f.panel(), 'candidate lifecycle must be available');
    f.submit(); await settle();
    if (change === 'place') {f.select().value = 'teaching_a'; f.select().dispatchEvent(new f.window.Event('change'));}
    if (change === 'query') {f.query().value = '新查询'; f.query().dispatchEvent(new f.window.Event('input'));}
    if (change === 'owner') f.window.fixture.changeUser({user_id: 'another'});
    if (change === 'session') f.window.fixture.changeSession();
    if (change === 'service') {f.dom.reconfigure({url: 'http://another-service/'}); f.window.fixture.sync();}
    if (change === 'school') f.window.fixture.changeUser({school: '其他学校'});
    if (change === 'campus') f.window.fixture.changeUser({campus: '其他校区'});
    if (change === 'tab') f.window.fixture.switchTab();
    if (change === 'view') f.window.fixture.hide();
    if (change === 'hidden') {
      Object.defineProperty(f.document, 'hidden', {value: true, configurable: true});
      f.document.dispatchEvent(new f.window.Event('visibilitychange'));
    }
    resolve(page()); await settle();
    assert.equal(f.document.querySelectorAll('[data-campus-place-preview]').length, 0, change);
    assert.equal(f.document.getElementById('campusPlaceConfirmButton').disabled, true, change);
    assert.equal(f.panel().querySelector('iframe'), null, change);
    f.dom.window.close();
  }
});

test('hiding selection clears preview map and an expired credential cannot be submitted again', async () => {
  const f = environment(call => call.method === 'PUT'
    ? {error: {detail: {code: 'MAP_SELECTION_EXPIRED', message: 'private-fixture-token https://unsafe.example'}}}
    : page());
  assert.ok(f.panel()); f.submit(); await settle();
  f.document.querySelector('[data-campus-place-preview]').click();
  f.document.getElementById('campusPlaceConfirmButton').click(); await settle();
  assert.match(f.status(), /过期|重新检索/);
  assert.doesNotMatch(f.panel().textContent, /private-fixture-token|unsafe\.example/);
  assert.equal(f.document.getElementById('campusPlaceConfirmButton').disabled, true);
  assert.equal(f.document.querySelectorAll('[data-campus-place-preview]').length, 0);
  f.submit(); await settle(); f.document.querySelector('[data-campus-place-preview]').click();
  const frame = f.panel().querySelector('iframe'), calls = [];
  frame.contentWindow.CampusFlowMap = {setConfig: value => calls.push(value), setState: value => calls.push(value),
    clear: () => calls.push('clear')};
  frame.dispatchEvent(new f.window.Event('load'));
  await settle();
  f.window.fixture.switchTab();
  assert.equal(calls.at(-1), 'clear'); assert.equal(frame.isConnected, false);
  f.dom.window.close();
});

test('late snapshot refresh and confirmation results cannot overwrite another account or package', async () => {
  let resolve;
  const f = environment(call => call.path === '/api/v1/campus-data'
    ? new Promise(done => {resolve = done;}) : page());
  assert.ok(f.panel());
  const refresh = f.window.fixture.reload(); await settle();
  f.window.fixture.changeUser({user_id: 'another'});
  resolve({...snapshot, package: {...snapshot.package, description: 'stale-owner-snapshot'}});
  await refresh;
  assert.doesNotMatch(f.document.body.textContent, /stale-owner-snapshot/);
  f.dom.window.close();
  let finish;
  const pending = environment(call => call.method === 'PUT' ? new Promise(done => {finish = done;}) : page());
  pending.submit(); await settle(); pending.document.querySelector('[data-campus-place-preview]').click();
  pending.document.getElementById('campusPlaceConfirmButton').click(); await settle();
  pending.window.fixture.render({...snapshot, package: {...snapshot.package, version: 'next-version'}});
  finish(selection); await settle();
  assert.equal(pending.calls.filter(call => call.path === '/api/v1/campus-data').length, 0);
  assert.doesNotMatch(pending.document.getElementById('campusPlaceSavedSelection').textContent, /已确认/);
  pending.dom.window.close();
});

test('loading more candidates cannot extend credentials from an earlier page', async () => {
  const f = environment(call => new URL(call.path, 'http://localhost').searchParams.get('page') === '0'
    ? page({expires_at: '2026-11-08T10:00:01Z', has_more: true})
    : page({page: 1, expires_at: '2026-11-08T10:05:00Z',
      candidates: [{...candidate, name: '南侧入口', selection_token: 'private-second-token'}]}));
  f.window.Date.now = () => Date.parse('2026-11-08T10:00:00Z');
  f.submit(); await settle();
  f.document.getElementById('campusPlaceMoreButton').click(); await settle();
  assert.equal(f.document.querySelectorAll('[data-campus-place-preview]').length, 2);
  f.window.Date.now = () => Date.parse('2026-11-08T10:00:02Z');
  f.document.querySelector('[data-campus-place-preview]').click();
  assert.equal(f.panel().querySelector('iframe'), null);
  assert.equal(f.document.getElementById('campusPlaceConfirmButton').disabled, true);
  assert.match(f.status(), /过期|重新检索/);
  assert.equal(f.calls.some(call => call.method === 'PUT'), false);
  f.dom.window.close();
});

test('a pending snapshot cannot restore an older data package after the current package changes', async () => {
  let resolve;
  const f = environment(() => new Promise(done => {resolve = done;}));
  const pending = f.window.fixture.reload(); await settle();
  f.window.fixture.render({...snapshot, package: {...snapshot.package, version: '2026.11.9'}});
  resolve({...snapshot, package: {...snapshot.package, description: 'stale-version-snapshot'}});
  await pending;
  assert.equal(f.document.getElementById('campusPackageVersion').textContent, 'v2026.11.9');
  assert.doesNotMatch(f.document.body.textContent, /stale-version-snapshot/);
  f.dom.window.close();
});
