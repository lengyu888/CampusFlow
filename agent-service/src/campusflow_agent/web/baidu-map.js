/* Shared, same-origin renderer. The bridge accepts route data and public map configuration. */
(() => {
  "use strict";
  const mapElement = document.getElementById("map");
  const message = document.getElementById("map-message");
  const status = document.getElementById("map-status");
  const retry = document.getElementById("map-retry");
  // Account maps wait for the authenticated parent to provide a browser AK.
  const managed = new URLSearchParams(window.location.search).get("managed") === "1";
  let state = {active: !managed && window.self === window.top, route: null, origin: null, destination: null};
  let sdk = null, map = null, config = null, loading = null, renderVersion = 0;
  let accountConfig = null, sdkBrowserAk = null, requiresReload = false;
  let cancelSearch = () => {};
  let callbackSequence = 0;
  let renderFrame = 0, routeFrame = 0, viewportTimer = 0;
  let zooming = false, moving = false, routeLayer = null, fittedRoute = null;
  let layoutSize = "", waitingForLayout = false;
  const isActive = () => state.active && !document.hidden && !requiresReload;
  const mapSize = () => mapElement.clientWidth && mapElement.clientHeight
    ? `${mapElement.clientWidth}x${mapElement.clientHeight}` : "";
  const validPoint = (p) => p && typeof p.lat === "number" && typeof p.lng === "number" &&
    Number.isFinite(p.lat) && Number.isFinite(p.lng) && Math.abs(p.lat) <= 90 && Math.abs(p.lng) <= 180;
  const toPoint = (p) => new sdk.Point(p.lng, p.lat);
  function show(text = "", canRetry = false) {
    status.hidden = !text;
    message.textContent = text;
    retry.hidden = !canRetry;
  }
  function routePoints() {
    const route = state.route;
    if (route?.provider !== "baidu" || route.coordinate_system !== "bd09ll" ||
      !Array.isArray(route.polyline) || route.polyline.length < 2 || route.polyline.length > 20000 ||
      !route.polyline.every(validPoint)) return null;
    if ((state.origin && state.origin.place_id !== route.origin?.place_id) ||
      (state.destination && state.destination.place_id !== route.destination?.place_id)) return null;
    return route.polyline;
  }
  async function getConfig() {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 6000);
    try {
      const response = await fetch(new URL("../api/v1/maps/baidu/config", document.baseURI).href, {
        credentials: "omit", cache: "no-store", signal: controller.signal,
      });
      if (!response.ok) throw new Error("config");
      return await response.json();
    } finally { clearTimeout(timer); }
  }
  function loadSdk(ak) {
    if (window.BMap?.Map) return Promise.resolve(window.BMap);
    return new Promise((resolve, reject) => {
      const script = document.createElement("script");
      const callback = `__campusFlowBaiduReady${++callbackSequence}`;
      let complete = false;
      const finish = (ok) => {
        if (complete) return;
        complete = true;
        clearTimeout(timer);
        script.onerror = null;
        // Late SDK callbacks after a timeout are harmless and contain no app state.
        window[callback] = () => {};
        if (!ok) script.remove();
        if (ok && window.BMap?.Map) resolve(window.BMap);
        else reject(new Error("sdk"));
      };
      const timer = setTimeout(() => finish(false), 12000);
      window[callback] = () => finish(true);
      script.onerror = () => finish(false);
      script.src = `https://api.map.baidu.com/api?v=4.0&ak=${encodeURIComponent(ak)}&callback=${callback}`;
      script.async = true;
      document.head.append(script);
    });
  }
  async function ensureReady() {
    if (!isActive()) return;
    if (managed && !accountConfig) { show("正在读取地图配置…"); return; }
    if (sdk) { queueRender(); return; }
    if (loading) return;
    show("正在加载校园地图…");
    loading = (async () => {
      try {
        config = managed ? accountConfig : await getConfig();
        if (!isActive()) return;
        if (!config?.configured || typeof config.browser_ak !== "string" || !config.browser_ak.trim()) {
          throw new Error("unconfigured");
        }
        sdkBrowserAk = config.browser_ak;
        sdk = await loadSdk(sdkBrowserAk);
        if (isActive()) queueRender();
      } catch (error) {
        if (isActive()) show(error.message === "unconfigured"
          ? managed ? "校园地图暂不可用，请在个人设置配置百度地图 AK。"
            : "校园地图暂不可用，请联系维护者完善配置后重试。"
          : "地图暂时无法加载，请检查网络后重试。", true);
      } finally { loading = null; }
    })();
    await loading;
  }
  function mark(point, name) {
    const marker = new sdk.Marker(toPoint(point));
    // Labels use fixed strings: upstream place names are never interpreted as HTML.
    marker.setLabel(new sdk.Label(name));
    map.addOverlay(marker);
  }
  function hideRoute() {
    cancelAnimationFrame(routeFrame);
    routeFrame = 0;
    if (!routeLayer) return;
    routeLayer.remove();
    routeLayer = null;
    map.clearOverlays();
  }
  function drawRouteLine(points) {
    const ns = "http://www.w3.org/2000/svg";
    const layer = document.createElementNS(ns, "svg");
    layer.setAttribute("class", "map-route");
    layer.setAttribute("aria-hidden", "true");
    const line = document.createElementNS(ns, "polyline");
    line.setAttribute("points", points.map((point) => {
      const {x, y} = map.pointToPixel(point);
      return `${x},${y}`;
    }).join(" "));
    layer.append(line);
    mapElement.append(layer);
    return layer;
  }
  function drawRouteAfterPaint() {
    if (!isActive() || !fittedRoute || zooming || moving || routeFrame || routeLayer) return;
    const points = fittedRoute;
    // Leave a frame for the settled basemap to paint without the previous projection.
    routeFrame = requestAnimationFrame(() => {
      routeFrame = requestAnimationFrame(() => {
        routeFrame = 0;
        if (!isActive() || zooming || moving || points !== fittedRoute || !mapSize()) return;
        try {
          mark(points[0], "起点");
          mark(points[points.length - 1], "终点");
          routeLayer = drawRouteLine(points);
          show();
        } catch {
          map.clearOverlays();
          show("地图暂时无法显示，请重试。", true);
        }
      });
    });
  }
  function queueRender() {
    if (renderFrame) return;
    renderFrame = requestAnimationFrame(() => {
      renderFrame = 0;
      render();
    });
  }
  function invalidateRender() {
    ++renderVersion;
    cancelSearch();
    clearTimeout(viewportTimer);
    fittedRoute = null;
    hideRoute();
  }
  function resizeMap() {
    if (!sdk || !isActive()) return;
    const size = mapSize();
    if (size === layoutSize) return;
    layoutSize = size;
    hideRoute();
    if (!size) return;
    map?.checkResize();
    if (waitingForLayout) queueRender();
    else drawRouteAfterPaint();
  }
  function fitRoute(path, version) {
    const margins = [64, 36, 48, 36];
    const current = () => version === renderVersion && isActive();
    const fitted = () => {
      if (!current()) return;
      clearTimeout(viewportTimer);
      fittedRoute = path;
      drawRouteAfterPaint();
    };
    viewportTimer = setTimeout(() => {
      if (!current()) return;
      // Some SDK builds skip completion for an already fitted camera.
      const target = map.getViewport(path, {margins});
      const center = map.getCenter();
      if (target?.center && center && Math.abs(center.lng - target.center.lng) < 1e-7 &&
        Math.abs(center.lat - target.center.lat) < 1e-7 && Math.abs(map.getZoom() - target.zoom) < 1e-6) {
        fitted();
      } else show("地图视野暂未就绪，请重试。", true);
    }, 1500);
    map.setViewport(path, {margins, enableAnimation: false, callback: fitted});
  }
  const normalize = (value) => String(value ?? "").replace(/[\s（）()·]/g, "");
  function locateCampus(version) {
    if (!config?.campus_query || !config.city) {
      show("校园位置尚未配置，请联系管理员后重试。", true); return;
    }
    let done = false;
    const timer = setTimeout(() => finish(null), 6000);
    const finish = (point) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      if (version !== renderVersion || !isActive()) return;
      if (point) {
        map.centerAndZoom(toPoint(point), 17);
        show(config.route_configured ? "" : "地图已加载，步行路线服务尚未配置。", !config.route_configured);
      } else show("无法确认当前校园位置，请联系管理员校准校园配置后重试。", true);
    };
    cancelSearch = () => { done = true; clearTimeout(timer); };
    const search = new sdk.LocalSearch(config.city, {
      pageCapacity: 20,
      onSearchComplete(result) {
        if (done || version !== renderVersion || !isActive()) return;
        if (search.getStatus() !== 0 || !result) {
          finish(null); return;
        }
        const candidates = [];
        for (let i = 0; i < result.getCurrentNumPois(); i++) {
          const poi = result.getPoi(i);
          if (poi && normalize(poi.title) === normalize(config.campus_query) &&
            normalize(poi.city) === normalize(config.city) && validPoint(poi.point)) candidates.push(poi.point);
        }
        finish(candidates.length === 1 ? candidates[0] : null);
      },
    });
    search.search(config.campus_query);
  }
  function render() {
    if (!isActive()) { pause(); return; }
    const size = mapSize();
    waitingForLayout = !size;
    if (waitingForLayout) return;
    const resized = size !== layoutSize;
    layoutSize = size;
    const version = renderVersion;
    try {
      if (!map) {
        map = new sdk.Map("map");
        map.addEventListener("zoomstart", () => {
          if (!isActive()) return;
          zooming = true;
          hideRoute();
        });
        map.addEventListener("zoomend", () => {
          zooming = false;
          drawRouteAfterPaint();
        });
        map.addEventListener("movestart", () => {
          if (!isActive()) return;
          moving = true;
          hideRoute();
        });
        map.addEventListener("moveend", () => {
          moving = false;
          drawRouteAfterPaint();
        });
      } else if (resized) map.checkResize();
      map.enableDragging();
      map.enableScrollWheelZoom(true);
      map.clearOverlays();
      const points = routePoints();
      if (points) {
        fitRoute(points.map(toPoint), version);
        show();
        return;
      }
      const selected = [state.origin?.location, state.destination?.location].filter(validPoint);
      if (selected.length) {
        if (validPoint(state.origin?.location)) mark(state.origin.location, "起点");
        if (validPoint(state.destination?.location)) mark(state.destination.location, "终点");
        if (selected.length === 1) map.centerAndZoom(toPoint(selected[0]), 17);
        else map.setViewport(selected.map(toPoint), {margins: [64, 36, 48, 36]});
        show(state.route ? "当前路线不可显示，请重新规划路线。" : "请选择起点和终点后规划步行路线。");
      } else {
        show("正在确认当前校园位置…");
        locateCampus(version);
      }
    } catch {
      clearTimeout(viewportTimer);
      map?.clearOverlays();
      show("地图暂时无法显示，请重试。", true);
    }
  }
  function pause() {
    invalidateRender();
    cancelAnimationFrame(renderFrame);
    renderFrame = 0;
    zooming = false;
    moving = false;
    map?.clearOverlays();
    map?.disableDragging();
    map?.disableScrollWheelZoom();
    mapElement.hidden = true;
    show();
  }
  function update() {
    if (!isActive()) {
      pause();
      if (requiresReload && state.active && !document.hidden) show("地图配置已变更，请重新打开地图。");
      return;
    }
    invalidateRender();
    mapElement.hidden = false;
    void ensureReady();
  }
  window.CampusFlowMap = Object.freeze({
    setConfig(value) {
      if (!managed || requiresReload) return;
      const next = {
        configured: value?.configured === true,
        browser_ak: typeof value?.browser_ak === "string" ? value.browser_ak.trim() : "",
        route_configured: value?.route_configured === true,
        campus_query: typeof value?.campus_query === "string" ? value.campus_query : "",
        city: typeof value?.city === "string" ? value.city : "",
      };
      // A loaded SDK is tied to its original key. The parent must replace this document.
      if (sdkBrowserAk !== null && sdkBrowserAk !== next.browser_ak) {
        accountConfig = null;
        requiresReload = true;
      } else {
        if (JSON.stringify(next) === JSON.stringify(accountConfig)) return;
        accountConfig = next;
        if (sdk) config = next;
      }
      update();
    },
    setState(value) {
      let next;
      try {
        // Clone across the bridge so caller mutations cannot resurrect a stale route.
        const copy = JSON.parse(JSON.stringify(value ?? {}));
        next = {active: copy.active === true, route: copy.route ?? null,
          origin: copy.origin ?? null, destination: copy.destination ?? null};
      } catch { next = {active: false, route: null, origin: null, destination: null}; }
      if (JSON.stringify(next) === JSON.stringify(state)) return;
      state = next;
      update();
    },
    clear() { state = {active: false, route: null, origin: null, destination: null}; pause(); },
  });
  retry.addEventListener("click", update);
  if (typeof ResizeObserver === "function") new ResizeObserver(resizeMap).observe(mapElement);
  document.addEventListener("visibilitychange", update);
  window.addEventListener("pagehide", () => window.CampusFlowMap.clear());
  update();
})();
