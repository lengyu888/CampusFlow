import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { JSDOM } from 'jsdom';
const app = readFileSync(new URL('../../src/campusflow_agent/web/app.js', import.meta.url), 'utf8');
const origin = {place_id: 'a', name: '<img src=x onerror=alert(1)>', location: {lat: 30.3, lng: 120.3}};
const destination = {place_id: 'library', name: '杭州电子科技大学(高教园校区)-图书馆',
  aliases: ['图书馆', '校图书馆'], location: {lat: 30.4, lng: 120.4}, open_now: null};
const route = {provider: 'baidu', coordinate_system: 'bd09ll', origin, destination,
  polyline: [origin.location, destination.location], path: [], total_minutes: 4, distance_meters: 270, steps: []};
const mapConfig = {configured: true, browser_ak: 'fixture-public-browser-ak', route_configured: true,
  campus_query: '杭州电子科技大学下沙校区', city: '杭州市'};
const settle = async () => { for (let i = 0; i < 12; i++) await Promise.resolve(); };
const endpointError = status => Object.assign(new Error('private-error-value'), {status});
function environment(user = {user_id: 'owner', school: '杭州电子科技大学', campus: '下沙校区'},
  respond = () => ({...mapConfig, server_ak: 'never-forward-server-ak', user_id: 'owner'})) {
  const dom = new JSDOM('<div id="appView"></div><div id="messages"></div>',
    {url: 'http://localhost/', runScripts: 'outside-only', pretendToBeVisual: true});
  const start = app.includes('function campusRouteMapAllowed(') ? app.indexOf('function campusRouteMapAllowed(') : app.indexOf('const SVG_NS');
  dom.window.fixtureUser = user;
  const requests = [];
  dom.window.fixtureApi = async (path, options) => {
    requests.push({path, options});
    return respond(path);
  };
  dom.window.eval(`const state = {user: window.fixtureUser, appTab: 'agent'};
    const elements = {messages: document.getElementById('messages'), appView: document.getElementById('appView')};
    function clearEmptyState() {} function scrollMessages() {}
    async function api(path, options) { return window.fixtureApi(path, options); }
    ${app.slice(start, app.indexOf('const replyToolStates'))}
    window.renderRoute = renderCampusRoute;
    window.hideMaps = () => {state.appTab = 'today'; if (typeof syncCampusRouteMaps === 'function') syncCampusRouteMaps();};
    window.changeOwner = () => {state.user = {...state.user, user_id: 'another'}; if (typeof syncCampusRouteMaps === 'function') syncCampusRouteMaps();};`);
  return {dom, window: dom.window, document: dom.window.document, requests};
}
test('Baidu route iframe receives only allowlisted public map config and route geometry', async t => {
  const f = environment();
  f.window.renderRoute({...route, destination: {...destination, selection: {name: 'selected entrance'}},
    evidence: [{note: 'account evidence'}], polyline: [origin.location, {...destination.location, extra: 'ignored'}]});
  t.after(() => f.dom.window.close());
  const iframe = f.document.querySelector('iframe'); assert.ok(iframe);
  assert.equal(iframe.getAttribute('src'), '/static/baidu-map.html?v=3&managed=1');
  assert.equal(f.document.querySelector('svg, img'), null);
  assert.equal(f.document.querySelector('.campus-route-head h3').textContent, `${origin.name} → 图书馆`);
  assert.match(f.document.body.textContent, /270/);
  const calls = [];
  iframe.contentWindow.CampusFlowMap = {setConfig: value => calls.push(value), setState: value => calls.push(value),
    clear: () => calls.push('clear')};
  iframe.dispatchEvent(new f.window.Event('load'));
  await settle();
  assert.deepEqual(f.requests.map(({path}) => path), ['/api/v1/me/baidu-maps/config']);
  assert.equal(f.requests[0].options.cache, 'no-store');
  assert.deepEqual(structuredClone(calls[0]), mapConfig);
  const originForMap = {place_id: origin.place_id, location: origin.location};
  const destinationForMap = {place_id: destination.place_id, location: destination.location};
  assert.deepEqual(structuredClone(calls.at(-1)), {active: true, origin: originForMap, destination: destinationForMap,
    route: {provider: 'baidu', coordinate_system: 'bd09ll', origin: originForMap, destination: destinationForMap,
      polyline: [origin.location, destination.location]}});
  f.window.hideMaps(); assert.equal(calls.at(-1).active, false);
  f.window.changeOwner(); assert.equal(calls.at(-1), 'clear');
});

test('the route card distinguishes unknown opening status from a closed record', t => {
  const f = environment();
  t.after(() => f.dom.window.close());
  f.window.renderRoute(route);
  f.window.renderRoute({...route, destination: {...destination, open_now: false, open_hours: '08:00–21:00'}});
  const statusMetrics = [...f.document.querySelectorAll('.campus-route-metrics > div:last-child')];
  assert.deepEqual(statusMetrics.map(metric => metric.querySelector('strong').textContent), ['状态未知', '关闭记录']);
  assert.equal(statusMetrics[0].querySelector('span').textContent, '开放时间未提供');
  assert.equal(statusMetrics[1].querySelector('span').textContent, '08:00–21:00');
});

test('only a missing account config endpoint falls back to the old public endpoint', async t => {
  for (const status of [404, 401, 503]) {
    const f = environment(undefined, path => {
      if (path === '/api/v1/me/baidu-maps/config') throw endpointError(status);
      return mapConfig;
    });
    t.after(() => f.dom.window.close());
    f.window.renderRoute(route);
    const iframe = f.document.querySelector('iframe'), calls = [];
    iframe.contentWindow.CampusFlowMap = {setConfig: value => calls.push(value), setState: value => calls.push(value)};
    iframe.dispatchEvent(new f.window.Event('load'));
    await settle();
    assert.deepEqual(f.requests.map(({path}) => path), status === 404
      ? ['/api/v1/me/baidu-maps/config', '/api/v1/maps/baidu/config'] : ['/api/v1/me/baidu-maps/config']);
    if (status === 404) assert.deepEqual(structuredClone(calls[0]), mapConfig);
    else {
      assert.equal(calls.length, 0);
      assert.match(f.document.body.textContent, /重试/);
      assert.doesNotMatch(f.document.body.textContent, /private-error-value/);
    }
  }
});

test('a config response from a previous account never reaches an iframe', async t => {
  let resolve;
  const f = environment(undefined, () => new Promise(done => { resolve = done; }));
  t.after(() => f.dom.window.close());
  f.window.renderRoute(route);
  const iframe = f.document.querySelector('iframe'), calls = [];
  iframe.contentWindow.CampusFlowMap = {setConfig: value => calls.push(value), setState: value => calls.push(value), clear() {}};
  iframe.dispatchEvent(new f.window.Event('load'));
  f.window.changeOwner();
  resolve(mapConfig);
  await settle();
  assert.equal(iframe.isConnected, false);
  assert.equal(calls.length, 0);
});
test('legacy history retains textual summary without constructing fake SVG or loading a map', () => {
  const f = environment(); f.window.renderRoute({...route, provider: 'reference', coordinate_system: 'image', path: [{x: 1, y: 2}]});
  assert.equal(f.document.querySelector('svg, iframe'), null);
  assert.equal(f.document.querySelector('.campus-route-head h3').textContent, `${origin.name} → ${destination.name}`);
  assert.match(f.document.body.textContent, /历史/); f.dom.window.close();
});
test('account outside supported school/campus cannot load the configured campus map', () => {
  const f = environment({user_id: 'other', school: '其他学校', campus: '下沙校区'});
  f.window.renderRoute(route); assert.equal(f.document.querySelector('iframe'), null);
  f.dom.window.close();
});

test('a response belonging to a prior account or chat cannot add a route card', () => {
  const f = environment();
  f.window.renderRoute(route, {owner: 'prior-account', sessionId: undefined});
  assert.equal(f.document.querySelector('.campus-route-card'), null);
  f.window.renderRoute(route, {owner: 'owner', sessionId: 'prior-chat'});
  assert.equal(f.document.querySelector('.campus-route-card'), null);
  f.dom.window.close();
});

test('school and campus aliases match the backend supported-campus rule', () => {
  for (const user of [{user_id: 'owner', school: ' HDU ', campus: ' Xiasha '},
    {user_id: 'owner', school: '杭电', campus: '下沙'}]) {
    const f = environment(user); f.window.renderRoute(route);
    assert.ok(f.document.querySelector('iframe')); f.dom.window.close();
  }
  const f = environment({user_id: 'owner', school: '杭州电子科大', campus: '下沙校区'});
  f.window.renderRoute(route); assert.equal(f.document.querySelector('iframe'), null); f.dom.window.close();
});
