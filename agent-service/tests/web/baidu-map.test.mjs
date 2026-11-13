import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import test from 'node:test';
import { JSDOM } from 'jsdom';

const scriptUrl = new URL('../../src/campusflow_agent/web/baidu-map.js', import.meta.url);
const source = existsSync(scriptUrl) ? readFileSync(scriptUrl, 'utf8') : '';
const pointA = {lat: 30.31, lng: 120.34}, pointB = {lat: 30.32, lng: 120.35};
const origin = {place_id: 'a', name: '起点', location: pointA};
const destination = {place_id: 'b', name: '终点', location: pointB};
const route = {provider: 'baidu', coordinate_system: 'bd09ll', origin, destination, polyline: [pointA, pointB]};
const targetViewport = {center: {lat: 30.315, lng: 120.345}, zoom: 17};
const settle = async () => { for (let i = 0; i < 8; i++) await Promise.resolve(); };
function environment(config = {configured: true, browser_ak: 'fixture-public-ak', route_configured: true,
  campus_query: '杭州电子科技大学下沙校区', city: '杭州市'}, options = {}) {
  const dom = new JSDOM('<div id="map"></div><section id="map-status"><span id="map-message"></span><button id="map-retry">重试</button></section>',
    {url: options.url ?? 'http://localhost/static/baidu-map.html', runScripts: 'outside-only', pretendToBeVisual: true});
  const {window} = dom, requests = [], maps = [], searches = [], timers = new Map();
  if (options.userAgent) Object.defineProperty(window.navigator, 'userAgent', {value: options.userAgent});
  Object.defineProperties(window.document.getElementById('map'), {
    clientWidth: {value: 340}, clientHeight: {value: 400},
  });
  const frames = new Map();
  let frameId = 0, frameTime = 0, frameScheduled = false;
  function runFrame() {
    frameTime += 16;
    // Callbacks requested during this frame belong to the next frame.
    for (const [id, callback] of [...frames]) {
      if (frames.delete(id)) callback(frameTime);
    }
  }
  window.requestAnimationFrame = callback => {
    frames.set(++frameId, callback);
    if (!options.manualFrames && !frameScheduled) {
      frameScheduled = true;
      queueMicrotask(() => {
        frameScheduled = false;
        runFrame();
      });
    }
    return frameId;
  };
  window.cancelAnimationFrame = id => frames.delete(id);
  async function advanceFrame() {
    await settle();
    runFrame();
    await settle();
  }
  if (options.clock) {
    let id = 0;
    window.setTimeout = (fn, ms) => {timers.set(++id, {fn, ms}); return id;};
    window.clearTimeout = id => timers.delete(id);
  }
  if (options.hidden) Object.defineProperty(window.document, 'hidden', {value: true, configurable: true});
  window.fetch = async (url, options) => { requests.push({url, options}); return {ok: true, json: async () => config}; };
  window.eval(source);
  const sdk = {
    Point: class {constructor(lng, lat) {Object.assign(this, {lng, lat});}},
    Map: class {
      constructor() {
        this.overlays = [];
        this.listeners = new Map();
        this.viewportRequests = [];
        this.centerRequests = 0;
        this.pixelScale = 1;
        this.pixelOffset = {x: 0, y: 0};
        maps.push(this);
      }
      clearOverlays() {this.overlays = [];}
      addOverlay(value) {this.overlays.push(value);}
      removeOverlay(value) {this.overlays = this.overlays.filter(overlay => overlay !== value);}
      setViewport(points, {callback} = {}) {
        const complete = () => {
          this.viewport = points;
          callback?.();
        };
        this.viewportRequests.push({points, complete});
        if (!options.deferViewport) complete();
      }
      getViewport() {return {...targetViewport, center: {...targetViewport.center}};}
      getCenter() {return this.camera?.center;}
      getZoom() {return this.camera?.zoom;}
      centerAndZoom(point, _zoom, {callback} = {}) {
        this.centerRequests++;
        this.center = point;
        callback?.();
      }
      pointToPixel(point) {
        return {
          x: Math.round((point.lng - 120.33) * 10000) * this.pixelScale + this.pixelOffset.x,
          y: Math.round((30.33 - point.lat) * 10000) * this.pixelScale + this.pixelOffset.y,
        };
      }
      addEventListener(name, callback) {
        if (!this.listeners.has(name)) this.listeners.set(name, new Set());
        this.listeners.get(name).add(callback);
      }
      removeEventListener(name, callback) {this.listeners.get(name)?.delete(callback);}
      emit(name) {
        for (const callback of this.listeners.get(name) ?? []) callback({type: name, target: this});
      }
      enableScrollWheelZoom() {} enableDragging() {} disableDragging() {} disableScrollWheelZoom() {}
    },
    Polyline: class {constructor(points) {this.points = points;}},
    Marker: class {constructor(point) {this.point = point;} setLabel(label) {this.label = label;}},
    Label: class {constructor(text) {this.text = text;}},
    LocalSearch: class {constructor(city, options) {this.city = city; this.options = options; searches.push(this);}
      search(query) {this.query = query;} getStatus() {return 0;}}
  };
  async function loadSdk(version = '4.0') {
    await settle();
    const script = window.document.querySelector('script[src]');
    assert.ok(script, 'configured active map should request SDK');
    const url = new URL(script.src);
    assert.equal(url.origin + url.pathname, 'https://api.map.baidu.com/api');
    assert.equal(url.searchParams.get('v'), version);
    assert.equal(url.searchParams.has('type'), false);
    window.BMap = sdk;
    window[url.searchParams.get('callback')]();
    await settle();
  }
  return {dom, window, requests, maps, searches, timers, loadSdk, advanceFrame, bridge: window.CampusFlowMap,
    message: () => window.document.getElementById('map-message').textContent};
}

const roadLines = f => f.window.document.querySelectorAll('svg.map-route polyline');
const routeState = {active: true, route, origin, destination};
const accountConfig = {configured: true, browser_ak: 'fixture-account-browser', route_configured: true,
  campus_query: '杭州电子科技大学下沙校区', city: '杭州市'};

test('managed map waits for its account configuration without a public config request', async t => {
  const f = environment(undefined, {url: 'https://service.test/static/baidu-map.html?v=3&managed=1'});
  t.after(() => f.dom.window.close());
  f.bridge.setState(routeState);
  await settle();
  assert.equal(f.requests.length, 0);
  assert.equal(f.window.document.querySelector('script[src]'), null);
  f.bridge.setConfig({...accountConfig, server_ak: 'not-for-the-map'});
  await settle();
  const script = new URL(f.window.document.querySelector('script[src]').src);
  assert.equal(script.searchParams.get('ak'), accountConfig.browser_ak);
  assert.doesNotMatch(script.href, /not-for-the-map/);
  await f.loadSdk();
  assert.equal(roadLines(f).length, 1);
});

test('changing an already loaded managed browser key hides the old document', async t => {
  const f = environment(undefined, {url: 'https://service.test/static/baidu-map.html?v=3&managed=1'});
  t.after(() => f.dom.window.close());
  f.bridge.setConfig(accountConfig);
  f.bridge.setState(routeState);
  await f.loadSdk();
  f.bridge.setConfig({...accountConfig, browser_ak: 'fixture-another-browser'});
  f.bridge.setState(routeState);
  await settle();
  assert.equal(roadLines(f).length, 0);
  assert.equal(f.window.document.getElementById('map').hidden, true);
  assert.equal(f.window.document.querySelectorAll('script[src]').length, 1);
  assert.match(f.message(), /重新打开/);
});

test('managed ArkWeb draws the route and keeps it visible even when a gesture has no end event', async t => {
  const f = environment(undefined, {
    url: 'https://service.test/static/baidu-map.html?v=4&managed=1',
    userAgent: 'Mozilla/5.0 Chrome/132.0 ArkWeb/6.1.0.120',
    deferViewport: true,
  });
  t.after(() => f.dom.window.close());
  f.bridge.setConfig(accountConfig);
  f.bridge.setState(routeState);
  await f.loadSdk('3.0');

  const [map] = f.maps;
  assertRoadLine(f);
  assert.equal(roadLines(f)[0].parentElement.previousElementSibling.id, 'map');
  assert.match(f.window.document.getElementById('map').getAttribute('aria-label'), /已绘制步行路线/);
  const [start, end] = map.overlays;
  assert.deepEqual([start.label.text, end.label.text], ['起点', '终点']);
  map.emit('movestart');
  await settle();
  assertRoadLine(f);
  assert.equal(map.overlays.length, 2);
  map.pixelOffset = {x: 10, y: 20};
  map.emit('moveend');
  await settle();
  assertRoadLine(f, [110, 220, 210, 120]);
  map.emit('zoomstart');
  assertRoadLine(f, [110, 220, 210, 120]);
  map.pixelScale = 2;
  map.emit('zoomend');
  await settle();
  assertRoadLine(f, [210, 420, 410, 220]);

  f.bridge.setState({...routeState, route: null});
  assert.equal(map.overlays.length, 0);
  await settle();
  assert.equal(map.overlays.length, 2);
  f.bridge.clear();
  assert.equal(map.overlays.length, 0);
});

test('a candidate preview shows only its pin and does not show route instructions', async t => {
  const f = environment(undefined, {url: 'https://service.test/static/baidu-map.html?managed=1'});
  t.after(() => f.dom.window.close());
  f.bridge.setConfig(accountConfig);
  f.bridge.setState({active: true, preview: true, origin: null, destination});
  await f.loadSdk();
  const [map] = f.maps;
  assert.equal(map.overlays.length, 1);
  assert.equal(map.overlays[0].label.text, '预览');
  assert.equal(map.center.lng, pointB.lng);
  assert.equal(f.message(), '');
});
function assertRoadLine(f, expected = [100, 200, 200, 100]) {
  const lines = roadLines(f);
  assert.equal(lines.length, 1, 'exactly one SVG route line must be visible');
  assert.equal(lines[0].namespaceURI, 'http://www.w3.org/2000/svg');
  assert.deepEqual(lines[0].getAttribute('points').trim().split(/[\s,]+/).map(Number), expected);
}

test('first route waits for the fitted viewport and a paint before adding overlays', async t => {
  const f = environment(undefined, {manualFrames: true, deferViewport: true});
  t.after(() => f.dom.window.close());
  f.bridge.setState(routeState);
  await f.loadSdk();
  await f.advanceFrame();
  const map = f.maps[0];
  assert.equal(map.viewportRequests.length, 1, 'the route must request a fitted viewport');
  assert.equal(map.overlays.length, 0, 'the old viewport must have no new route overlays');
  assert.equal(roadLines(f).length, 0);

  map.viewportRequests[0].complete();
  await f.advanceFrame();
  assert.equal(map.overlays.length, 0, 'one frame is needed for the fitted view to paint');
  assert.equal(roadLines(f).length, 0);
  await f.advanceFrame();
  assertRoadLine(f);
  assert.equal(map.overlays.length, 2, 'only the endpoint markers belong to the SDK');
  assert.deepEqual(map.overlays.map(({point}) => [point.lng, point.lat]),
    [[120.34, 30.31], [120.35, 30.32]]);
});

for (const {name, camera, draw} of [
  {name: 'recovers a settled route', camera: targetViewport, draw: true},
  {name: 'offers retry when the zoom differs', camera: {...targetViewport, zoom: 15}, draw: false},
  {name: 'offers retry when the center differs', camera: {...targetViewport, center: pointA}, draw: false},
]) {
  test(`a missing viewport callback ${name}`, async t => {
    const f = environment(undefined, {clock: true, manualFrames: true, deferViewport: true});
    t.after(() => f.dom.window.close());
    f.bridge.setState(routeState);
    await f.loadSdk();
    await f.advanceFrame();
    const map = f.maps[0];
    assert.equal(map.viewportRequests.length, 1);
    map.camera = camera;
    assert.equal(roadLines(f).length, 0, 'the route should wait for the viewport');

    // Expire the pending fit timer without delivering the SDK callback.
    for (const [id, timer] of [...f.timers]) {
      if (f.timers.delete(id)) timer.fn();
    }
    await f.advanceFrame();
    await f.advanceFrame();
    const retry = f.window.document.getElementById('map-retry');
    if (draw) {
      assertRoadLine(f);
      assert.equal(map.overlays.length, 2);
      assert.equal(retry.hidden, true);
    } else {
      assert.equal(roadLines(f).length, 0);
      assert.equal(map.overlays.length, 0);
      assert.equal(retry.hidden, false, 'an unconfirmed camera needs a visible retry');
      assert.ok(f.message(), 'explain why the route is unavailable');
    }
  });
}

test('gesture zoom clears the road line and redraws it once after paint without fitting again', async t => {
  const f = environment(undefined, {manualFrames: true});
  t.after(() => f.dom.window.close());
  f.bridge.setState(routeState);
  await f.loadSdk();
  for (let i = 0; i < 3; i++) await f.advanceFrame();
  const map = f.maps[0];
  assertRoadLine(f);
  const cameraRequests = map.viewportRequests.length + map.centerRequests;

  map.emit('zoomstart');
  assert.equal(roadLines(f).length, 0, 'remove the previous zoom projection immediately');
  map.pixelScale = 1.25;
  map.emit('zoomend');
  await f.advanceFrame();
  assert.equal(roadLines(f).length, 0);
  await f.advanceFrame();
  assertRoadLine(f, [125, 250, 250, 125]);
  assert.equal(map.viewportRequests.length + map.centerRequests, cameraRequests,
    'redrawing the route must preserve the zoom chosen by the user');
});

test('moving the map removes the old SVG and draws the new projection without refitting', async t => {
  const f = environment(undefined, {manualFrames: true});
  t.after(() => f.dom.window.close());
  f.bridge.setState(routeState);
  await f.loadSdk();
  for (let i = 0; i < 3; i++) await f.advanceFrame();
  const map = f.maps[0];
  const cameraRequests = map.viewportRequests.length + map.centerRequests;
  assertRoadLine(f);

  map.emit('movestart');
  assert.equal(roadLines(f).length, 0);
  map.pixelOffset = {x: 12, y: -25};
  map.emit('moveend');
  await f.advanceFrame();
  assert.equal(roadLines(f).length, 0);
  await f.advanceFrame();
  assertRoadLine(f, [112, 175, 212, 75]);
  assert.equal(map.viewportRequests.length + map.centerRequests, cameraRequests);
});

test('a second zoom cancels the pending redraw from the first zoom', async t => {
  const f = environment(undefined, {manualFrames: true});
  t.after(() => f.dom.window.close());
  f.bridge.setState(routeState);
  await f.loadSdk();
  for (let i = 0; i < 3; i++) await f.advanceFrame();
  const map = f.maps[0];

  map.emit('zoomstart');
  map.emit('zoomend');
  await f.advanceFrame();
  map.emit('zoomstart');
  await f.advanceFrame();
  await f.advanceFrame();
  assert.equal(roadLines(f).length, 0, 'the first zoom must not draw into the second zoom');

  map.emit('zoomend');
  await f.advanceFrame();
  await f.advanceFrame();
  assertRoadLine(f);
});

test('replacing a route or hiding the map invalidates earlier viewport callbacks', async t => {
  const f = environment(undefined, {manualFrames: true, deferViewport: true});
  t.after(() => f.dom.window.close());
  f.bridge.setState(routeState);
  await f.loadSdk();
  await f.advanceFrame();
  const map = f.maps[0];
  const firstViewport = map.viewportRequests[0];
  const reversed = {...route, polyline: [pointB, pointA], origin: destination, destination: origin};
  f.bridge.setState({active: true, route: reversed, origin: destination, destination: origin});
  firstViewport.complete();
  await f.advanceFrame();
  await f.advanceFrame();
  assert.equal(roadLines(f).length, 0, 'an obsolete viewport must not draw either route');
  assert.equal(map.overlays.length, 0);

  map.viewportRequests.at(-1).complete();
  await f.advanceFrame();
  await f.advanceFrame();
  assertRoadLine(f, [200, 100, 100, 200]);

  f.bridge.setState(routeState);
  await f.advanceFrame();
  const pending = map.viewportRequests.at(-1);
  f.bridge.setState({active: false});
  pending.complete();
  await f.advanceFrame();
  await f.advanceFrame();
  assert.equal(map.overlays.length, 0, 'a viewport callback must not restore overlays after hiding');
  assert.equal(roadLines(f).length, 0);
});

test('latest bridge state replaces pending route before JSAPI is ready', async () => {
  const f = environment();
  assert.equal(typeof f.bridge?.setState, 'function');
  f.bridge.setState({active: true, route, origin, destination});
  const latest = {...route, polyline: [pointB, pointA], origin: destination, destination: origin};
  f.bridge.setState({active: true, route: latest, origin: destination, destination: origin});
  await f.loadSdk();
  assertRoadLine(f, [200, 100, 100, 200]);
  assert.equal(f.maps[0].viewport.length, 2);
  assert.equal(f.requests[0].url, 'http://localhost/api/v1/maps/baidu/config');
  assert.equal(f.requests[0].options.credentials, 'omit');
  f.dom.window.close();
});

test('invalid coordinates, image routes and endpoint changes never draw a stale road line', async () => {
  const f = environment(); assert.ok(f.bridge);
  f.bridge.setState({active: true, route, origin, destination}); await f.loadSdk();
  for (const invalid of [{...route, polyline: [pointA, {lat: 91, lng: 120}]},
    {...route, provider: 'reference', coordinate_system: 'image'}, {...route, polyline: [pointA, {lat: NaN, lng: 120}]}]) {
    f.bridge.setState({active: true, route: invalid, origin, destination});
    assert.equal(roadLines(f).length, 0);
  }
  f.bridge.setState({active: true, route, origin: {...origin, place_id: 'changed'}, destination});
  assert.equal(roadLines(f).length, 0);
  f.dom.window.close();
});

test('hidden and cleared maps drop overlays and ignore in-flight SDK completion', async () => {
  const f = environment(); assert.ok(f.bridge);
  f.bridge.setState({active: true, route, origin, destination}); await settle();
  f.bridge.setState({active: false, route, origin, destination}); await f.loadSdk();
  assert.equal(f.maps.length, 0);
  f.bridge.setState({active: true, route, origin, destination}); await settle();
  assertRoadLine(f);
  assert.equal(f.maps[0].overlays.length, 2);
  f.bridge.clear(); assert.equal(f.maps[0].overlays.length, 0);
  assert.equal(roadLines(f).length, 0);
  f.dom.window.close();
});

test('SDK failure shows safe error and explicit retry loads again', async () => {
  const f = environment(); assert.ok(f.bridge); await settle();
  f.window.document.querySelector('script[src]').onerror(); await settle();
  assert.match(f.message(), /重试/); assert.doesNotMatch(f.message(), /fixture-public-ak|https:/);
  f.window.document.getElementById('map-retry').click(); await f.loadSdk();
  assert.equal(f.maps.length, 1); f.dom.window.close();
});

test('missing public AK never loads SDK and retry re-reads public configuration', async () => {
  const f = environment({configured: false}); assert.ok(f.bridge); await settle();
  assert.equal(f.window.document.querySelector('script[src]'), null);
  assert.match(f.message(), /配置/);
  assert.doesNotMatch(f.message(), /AK|api\.map|BAIDU_/);
  f.window.document.getElementById('map-retry').click(); await settle();
  assert.equal(f.requests.length, 2); f.dom.window.close();
});

test('ambiguous campus POIs are rejected and late campus resolution cannot replace a newer route', async () => {
  const f = environment(); assert.ok(f.bridge); await f.loadSdk();
  const search = f.searches[0];
  const poi = {title: '杭州电子科技大学（下沙校区）', city: '杭州市', point: pointA};
  search.options.onSearchComplete({getNumPois: () => 2, getCurrentNumPois: () => 2, getPoi: () => poi});
  await settle(); assert.equal(f.maps[0].center, undefined); assert.match(f.message(), /校园/);
  f.window.document.getElementById('map-retry').click(); await settle();
  const pending = f.searches.at(-1);
  f.bridge.setState({active: true, route, origin, destination});
  pending.options.onSearchComplete({getNumPois: () => 1, getCurrentNumPois: () => 1, getPoi: () => poi});
  await settle(); assert.equal(f.maps[0].center, undefined);
  assertRoadLine(f); f.dom.window.close();
});

test('SDK timeout can retry and its late callback cannot render stale state', async () => {
  const f = environment(undefined, {clock: true}); assert.ok(f.bridge); await settle();
  const oldScript = f.window.document.querySelector('script[src]');
  const oldCallback = new URL(oldScript.src).searchParams.get('callback');
  [...f.timers.values()].find(timer => timer.ms === 12000).fn(); await settle();
  assert.match(f.message(), /重试/); assert.equal(oldScript.isConnected, false);
  f.bridge.setState({active: true, route, origin, destination}); await settle();
  f.window[oldCallback](); assert.equal(f.maps.length, 0);
  await f.loadSdk(); assertRoadLine(f); f.dom.window.close();
});

test('initially hidden document does not fetch config or SDK until made visible', async () => {
  const f = environment(undefined, {hidden: true}); assert.ok(f.bridge); await settle();
  assert.equal(f.requests.length, 0);
  f.bridge.setState({active: true, route, origin, destination}); await settle();
  assert.equal(f.requests.length, 0);
  Object.defineProperty(f.window.document, 'hidden', {value: false, configurable: true});
  f.window.document.dispatchEvent(new f.window.Event('visibilitychange'));
  await f.loadSdk(); assertRoadLine(f);
  assert.equal(f.maps[0].overlays.length, 2);
  Object.defineProperty(f.window.document, 'hidden', {value: true, configurable: true});
  f.window.document.dispatchEvent(new f.window.Event('visibilitychange'));
  assert.equal(f.maps[0].overlays.length, 0); assert.equal(f.window.document.getElementById('map').hidden, true);
  assert.equal(roadLines(f).length, 0);
  f.dom.window.close();
});

test('only unique exact-campus and exact-city POI centers default map', async () => {
  const f = environment(); await f.loadSdk();
  f.searches[0].options.onSearchComplete({getNumPois: () => 1, getCurrentNumPois: () => 1,
    getPoi: () => ({title: '杭州电子科技大学（下沙校区）', city: '杭州市', point: pointA})});
  await settle(); assert.equal(f.maps[0].center.lat, 30.31); assert.equal(f.maps[0].center.lng, 120.34);
  f.dom.window.close();
});

test('campus localization filters fuzzy and wrong-city matches before uniqueness even when more results exist', async () => {
  const f = environment(); await f.loadSdk();
  const pois = [
    {title: '杭州电子科技大学下沙校区北门', city: '杭州市', point: pointB},
    {title: '杭州电子科技大学（下沙校区）', city: '其他市', point: pointB},
    {title: '杭州电子科技大学（下沙校区）', city: '杭州市', point: pointA},
  ];
  f.searches[0].options.onSearchComplete({getNumPois: () => 65, getCurrentNumPois: () => 3, getPoi: index => pois[index]});
  await settle(); assert.equal(f.maps[0].center?.lat, 30.31); assert.equal(f.maps[0].center?.lng, 120.34);
  f.dom.window.close();
});

test('campus localization never centers the first fuzzy match on an incomplete result page', async () => {
  const f = environment(); await f.loadSdk();
  f.searches[0].options.onSearchComplete({getNumPois: () => 45, getCurrentNumPois: () => 1,
    getPoi: () => ({title: '杭州电子科技大学下沙校区东门', city: '杭州市', point: pointA})});
  await settle(); assert.equal(f.maps[0].center, undefined); assert.match(f.message(), /无法确认/);
  f.dom.window.close();
});

test('embedded renderer waits for owner bridge before any public config or SDK request', async () => {
  const dom = new JSDOM('<iframe></iframe>', {url: 'http://localhost/', runScripts: 'outside-only', pretendToBeVisual: true});
  const child = dom.window.document.querySelector('iframe').contentWindow;
  child.document.body.innerHTML = '<div id="map"></div><div id="map-status"><span id="map-message"></span><button id="map-retry"></button></div>';
  let requests = 0;
  child.fetch = async () => {requests++; return {ok: true, json: async () => ({configured: false})};};
  child.eval(source); await settle(); assert.equal(requests, 0);
  child.CampusFlowMap.setState({active: true, route}); await settle(); assert.equal(requests, 1);
  dom.window.close();
});

test('prefixed service loads static resources under the same prefix', () => {
  const pageUrl = 'https://campus.example/prefix/static/baidu-map.html';
  const html = readFileSync(new URL('../../src/campusflow_agent/web/baidu-map.html', import.meta.url), 'utf8');
  const dom = new JSDOM(html, {url: pageUrl});
  assert.equal(dom.window.document.querySelector('link[rel="stylesheet"]').href,
    'https://campus.example/prefix/static/baidu-map.css?v=4');
  assert.equal(dom.window.document.querySelector('script[src]').src,
    'https://campus.example/prefix/static/baidu-map.js?v=8');
  dom.window.close();
});

test('prefixed service fetches public config under the same prefix', async () => {
  const pageUrl = 'https://campus.example/prefix/static/baidu-map.html';
  const f = environment({configured: false}, {url: pageUrl}); await settle();
  assert.equal(new URL(f.requests[0].url, pageUrl).href,
    'https://campus.example/prefix/api/v1/maps/baidu/config');
  f.dom.window.close();
});
