(() => {
  "use strict";

  const root = document.getElementById("windowsCampusRoot");
  if (document.documentElement.dataset.platform !== "windows" || !root) return;
  const surface = root.closest("[data-app-surface]");
  const appView = document.getElementById("appView");
  const windows = () => window.CampusFlowWindows;
  const mapDocument = "/static/baidu-map.html?v=3&managed=1";
  const classroomsPath = "/api/v1/campus-services/classrooms";
  const buildings = [["", "全部教学楼"], ["1", "1教"], ["2", "2教"], ["3", "3教"], ["4", "4教"],
    ["5n", "5教北楼"], ["5s", "5教南楼"], ["6n", "6教北楼"], ["6s", "6教南楼"],
    ...["7", "8", "9", "10", "11", "12"].map(id => [id, id + "教"])];
  const periods = [["", "当前时段"], ["1,2", "第 1–2 节"], ["3,4,5", "第 3–5 节"],
    ["6,7,8,9", "第 6–9 节"], ["10,11,12,13", "第 10–13 节"]];
  const services = [["classrooms", "空闲教室"], ["electricity", "寝室电费"], ["library", "图书馆"],
    ["card", "校园卡"], ["route", "校园导航"], ["weather", "今日天气"], ["knowledge", "办事指南"]];
  const dateFormat = new Intl.DateTimeFormat("zh-CN", { dateStyle: "medium", timeStyle: "short", timeZone: "Asia/Shanghai" });
  const dateKey = new Intl.DateTimeFormat("sv-SE", { timeZone: "Asia/Shanghai", year: "numeric", month: "2-digit", day: "2-digit" });
  let active = "classrooms";
  let scope = "";
  let request = null;
  let routeDraft = null;

  function node(tag, text, className) {
    const element = document.createElement(tag);
    if (text !== undefined) element.textContent = text;
    if (className) element.className = className;
    return element;
  }

  function button(text, onClick, kind = "line-button") {
    const element = node("button", text, kind);
    element.type = "button";
    element.addEventListener("click", onClick);
    return element;
  }

  function section(title, controls) {
    const element = node("section", undefined, "win-campus-card");
    const header = node("header", undefined, "win-campus-card-head");
    header.append(node("h2", title));
    if (controls) header.append(controls);
    element.append(header);
    return element;
  }

  function field(label, options) {
    const wrapper = node("label", label);
    const select = node("select");
    for (const [value, title] of options) {
      const option = node("option", title);
      option.value = value;
      select.append(option);
    }
    wrapper.append(select);
    return { wrapper, select };
  }

  function formatDate(value) {
    const date = new Date(value ?? "");
    return Number.isNaN(date.valueOf()) ? "" : dateFormat.format(date);
  }

  function statusText(text, isError = false) {
    const status = node("p", text, isError ? "win-campus-status win-campus-error" : "win-campus-status");
    status.setAttribute("role", "status");
    return status;
  }

  function fail(target, error, retry) {
    const message = error.status === 401 ? "请重新登录后再查询。" :
      error.status === 404 && error.message === "Not Found" ? "此服务器未提供该项服务。" :
      error.message === "Failed to fetch" ? "服务暂时无法连接，请稍后再试。" :
      error.message || "读取失败，请稍后再试。";
    target.replaceChildren(statusText(message, true), button("重试", retry));
    if (message.includes("请先连接 HDUHelp") || message.includes("重新连接") || message.includes("核对 HDUHelp 授权")) {
      target.append(button("管理校园连接", manage));
    }
  }

  function addSource(target, data, retry) {
    const status = data.data_status;
    const evidence = Array.isArray(data.evidence) ? data.evidence : [];
    if (!status && !evidence.length) return;
    const details = node("details", undefined, "win-campus-source");
    details.append(node("summary", "数据状态与来源"));
    if (status) {
      const stamp = formatDate(status.updated_at);
      details.append(node("p", [status.message, stamp && "更新于 " + stamp].filter(Boolean).join(" · ")));
      if (status.action === "connect") details.append(button("管理校园连接", manage));
      if (status.action === "retry" && retry) details.append(button("重新读取", retry));
    }
    for (const source of evidence) {
      details.append(node("p", [source.label, formatDate(source.updated_at), source.note].filter(Boolean).join(" · ")));
    }
    if (status?.state === "unavailable" || status?.state === "stale") details.open = true;
    target.append(details);
  }

  function manage() { windows().open("campus-data"); }

  function ask(prompt) {
    windows().open("agent");
    const composer = document.getElementById("messageInput");
    if (!composer) return;
    composer.value = prompt;
    composer.dispatchEvent(new Event("input"));
    composer.focus();
  }

  function validPoint(point) {
    return Number.isFinite(point?.lat) && Number.isFinite(point?.lng) &&
      Math.abs(point.lat) <= 90 && Math.abs(point.lng) <= 180;
  }

  function savedEntranceConflict(place) {
    if (!place?.selection?.name) return false;
    const expected = [place.name, ...(place.aliases ?? [])].join(" ");
    const actual = place.selection.name;
    const parcel = /快递|驿站|物流|邮政|自提|丰巢|兔喜/;
    if (!parcel.test(expected) || !parcel.test(actual)) return false;
    const brands = ["菜鸟", "京东", "顺丰", "中通", "圆通", "申通", "韵达", "邮政", "极兔", "兔喜", "丰巢"];
    return brands.some(brand => expected.includes(brand)) && brands.some(brand => actual.includes(brand)) &&
      !brands.some(brand => expected.includes(brand) && actual.includes(brand));
  }

  function key() {
    const user = windows()?.user();
    return user?.user_id && !surface.hidden && !appView.hidden ? String(user.user_id) : "";
  }

  function cancel() {
    request?.abort();
    request = null;
  }

  async function run(signal, target, operation, render, retry) {
    const owner = scope;
    target.replaceChildren(statusText("正在读取…"));
    target.setAttribute("aria-busy", "true");
    try {
      const data = await operation();
      if (!signal.aborted && target.isConnected && key() === owner) render(data);
    } catch (error) {
      if (!signal.aborted && target.isConnected && key() === owner) fail(target, error, retry);
    } finally {
      if (!signal.aborted && target.isConnected) target.removeAttribute("aria-busy");
    }
  }

  function row(title, detail, action) {
    const element = node("div", undefined, "win-campus-row");
    const body = node("div");
    body.append(node("strong", title));
    if (detail) body.append(node("p", detail));
    element.append(body);
    if (action) element.append(action);
    return element;
  }

  function classrooms(host, signal) {
    const card = section("空闲教室");
    const filters = node("div", undefined, "win-campus-filters");
    const building = field("教学楼", buildings);
    const period = field("节次", periods);
    const results = node("div", undefined, "win-campus-results");
    const pagination = node("div", undefined, "win-campus-results");
    const usage = node("div", undefined, "win-campus-results");
    let query;
    let usageRequest;

    function showUsage(room) {
      usageRequest?.abort();
      usageRequest = new AbortController();
      const requestSignal = AbortSignal.any([signal, usageRequest.signal]);
      const panel = section(room.location_name + " · 占用安排", button("收起", () => {
        usageRequest.abort();
        usage.replaceChildren();
      }));
      const entries = node("div", undefined, "win-campus-results");
      panel.append(entries);
      usage.replaceChildren(panel);
      void run(requestSignal, entries,
        () => windows().api(classroomsPath + "/" + encodeURIComponent(room.location_id) + "/usage", { signal: requestSignal }),
        data => {
          const rows = data.items.map(item => row(item.course_name || "课程占用",
            ["第 " + item.week + " 周", "周" + ("一二三四五六日"[item.weekday - 1] || item.weekday),
              "第 " + item.section + " 节", item.start_time && item.end_time && item.start_time + "–" + item.end_time].filter(Boolean).join(" · ")));
          entries.replaceChildren(...(rows.length ? rows : [statusText("暂无占用记录。")]));
          addSource(entries, data, () => showUsage(room));
        }, () => showUsage(room));
    }

    function load() {
      query?.abort();
      usageRequest?.abort();
      usage.replaceChildren();
      pagination.replaceChildren();
      query = new AbortController();
      const requestSignal = AbortSignal.any([signal, query.signal]);
      const params = new URLSearchParams({ limit: "30", offset: "0" });
      if (building.select.value) params.set("building_id", building.select.value);
      if (period.select.value) period.select.value.split(",").forEach(part => params.append("section", part));
      let rooms = [];

      function page(offset) {
        params.set("offset", String(offset));
        void run(requestSignal, offset ? pagination : results,
          () => windows().api(classroomsPath + "?" + params, { signal: requestSignal }), data => {
          rooms = [...new Map([...rooms, ...data.items].map(room => [room.location_id, room])).values()];
          const heading = statusText(data.query_label + (rooms.length ? " · 已显示 " + rooms.length + " 间" : ""));
          const list = rooms.map(room => row(room.location_name, [room.building_name,
            room.capacity > 0 ? room.capacity + " 人" : "", room.self_study ? "可自习" : ""].filter(Boolean).join(" · "),
          button("占用安排", () => showUsage(room))));
          results.replaceChildren(heading, ...(list.length ? list : [statusText("所选时段暂无空闲教室。")]));
          pagination.replaceChildren();
          if (data.has_more && data.items.length > 0) pagination.append(button("加载更多", () => page(offset + data.items.length)));
          addSource(results, data, load);
        }, () => page(offset));
      }
      page(0);
    }

    filters.append(building.wrapper, period.wrapper, button("查询", load, "primary-action"));
    building.select.addEventListener("change", load);
    period.select.addEventListener("change", load);
    card.append(filters, results, pagination);
    host.append(card, usage);
    load();
  }

  function electricity(host, signal) {
    const card = section("寝室电费", button("刷新余额", load));
    const results = node("div", undefined, "win-campus-results");
    card.append(results);
    host.append(card);
    function load() {
      if (results.getAttribute("aria-busy") === "true") return;
      void run(signal, results, () => windows().api("/api/v1/campus-services/electricity", { signal }), data => {
        results.replaceChildren();
        if (!data.bound) results.append(statusText("未取得电表记录，请在 HDUHelp 核对电表绑定。"));
        else {
          const balance = node("div", undefined, "win-campus-metric");
          balance.append(node("p", "最近余额"), node("strong", Number.isFinite(data.balance) ? "¥ " + data.balance.toFixed(2) : "—"),
            node("p", [data.campus_name, data.building_name, data.room_name].filter(Boolean).join(" · ")),
            node("p", [data.daily_average && "日均 ¥" + data.daily_average,
              data.meter_hint, formatDate(data.balance_updated_at)].filter(Boolean).join(" · ")));
          results.append(balance, node("h3", "近 14 天余额"));
          results.append(...(data.history.length ? data.history.map(item =>
            row(item.date, "余额 ¥" + item.balance, node("span", item.change === "-" ? "首日" : item.change + " 元"))) :
            [statusText("暂无历史记录。")]));
        }
        addSource(results, data, load);
      }, load);
    }
    load();
  }

  function accountServices(host, signal, library) {
    const card = section(library ? "图书馆记录" : "校园卡余额", button("重新读取", () => load()));
    const results = node("div", undefined, "win-campus-results");
    card.append(results);
    host.append(card);
    function load(resource) {
      if (results.getAttribute("aria-busy") === "true") return;
      const path = resource ? "/api/v1/hduhelp/resources/" + encodeURIComponent(resource) + "/refresh" : "/api/v1/hduhelp/data";
      void run(signal, results, () => windows().api(path, { signal, method: resource ? "POST" : "GET" }), data => {
        results.replaceChildren();
        if (!data.status?.configured) {
          results.append(statusText("请先连接 HDUHelp，获取已授权的校园记录。"), button("管理校园连接", manage));
          return;
        }
        const match = name => library ? name.startsWith("library_") : name === "card_balance";
        const sections = data.sections.filter(item => match(item.resource));
        if (!sections.length) results.append(statusText(library ? "暂无图书馆记录。" : "暂无校园卡余额记录。"));
        const rendered = new Set();
        for (const entry of sections) {
          rendered.add(entry.resource);
          const group = node("section", undefined, "win-campus-group");
          group.append(node("h3", entry.title));
          if (entry.summary) group.append(statusText(entry.summary));
          for (const item of entry.items) group.append(row(item.label, item.value));
          addSource(group, { data_status: data.resource_statuses?.[entry.resource], evidence: entry.evidence }, () => load(entry.resource));
          results.append(group);
        }
        for (const [name, status] of Object.entries(data.resource_statuses ?? {})) {
          if (match(name) && !rendered.has(name)) addSource(results, { data_status: status }, () => load(name));
        }
        const suggestions = (data.suggested_prompts ?? []).filter(suggestion => typeof suggestion.resource === "string" &&
          match(suggestion.resource) && typeof suggestion.prompt === "string" && suggestion.prompt.length > 0);
        if (suggestions.length) {
          const prompts = node("div", undefined, "win-campus-filters");
          for (const suggestion of suggestions) prompts.append(button(suggestion.title, () => ask(suggestion.prompt)));
          results.append(prompts);
        }
      }, () => load(resource));
    }
    load();
  }

  function route(host, signal) {
    const card = section("校园步行导航");
    const inputs = node("div", undefined, "win-campus-route");
    const results = node("div", undefined, "win-campus-results");
    card.append(inputs, results);
    host.append(card);
    let planRequest;

    function load() {
      void run(signal, inputs, () => windows().api("/api/v1/campus-data", { signal, cache: "no-store" }), data => {
        const from = routeField("起点", data.places);
        const to = routeField("终点", data.places);
        const endpoints = node("div", undefined, "win-campus-route-endpoints win-campus-filters");
        const actions = node("div", undefined, "win-campus-route-actions");
        const routeStatus = statusText("");
        const picker = node("section", undefined, "win-campus-entrance-picker");
        picker.id = "desktopCampusEntrancePicker";
        picker.hidden = true;
        let editRequest;

        const submit = button("规划步行路线", () => {
          if (!hasLocation(chosen(from))) openEntrance(from);
          else if (!hasLocation(chosen(to))) openEntrance(to);
          else plan();
        }, "primary-action");
        const swap = button("交换", () => {
          closeEntrance();
          from.resetSearch();
          to.resetSearch();
          [from.select.value, to.select.value] = [to.select.value, from.select.value];
          update();
        });
        for (const item of [from, to]) {
          item.entrance.addEventListener("click", () => openEntrance(item));
          item.select.addEventListener("change", () => {
            closeEntrance();
            update();
          });
        }

        function chosen(item) { return data.places.find(place => place.place_id === item.select.value); }
        function hasLocation(place) { return validPoint(place?.selection?.location ?? place?.location); }
        function update(message = "") {
          planRequest?.abort();
          results.replaceChildren();
          results.removeAttribute("aria-busy");
          const origin = chosen(from);
          const destination = chosen(to);
          routeDraft = { owner: scope, origin: origin?.place_id ?? "", destination: destination?.place_id ?? "" };
          const valid = origin && destination && origin.place_id !== destination.place_id;
          const needsReview = valid && (savedEntranceConflict(origin) || savedEntranceConflict(destination));
          routeStatus.textContent = message || (origin && destination && !valid ? "请选择两个不同的地点。" :
            needsReview ? "已保存入口和地点名称有差异，请核对后规划。" : "");
          routeStatus.classList.toggle("win-campus-error", !!needsReview && !message);
          submit.textContent = !valid ? "规划步行路线" :
            !hasLocation(origin) ? "确认起点入口" : !hasLocation(destination) ? "确认终点入口" :
              needsReview ? "按已保存入口规划" : "规划步行路线";
          updateSubmit();
          for (const [item, place] of [[from, origin], [to, destination]]) {
            item.entrance.hidden = !place;
            item.entrance.textContent = (hasLocation(place) ? "更换" : "选择") + item.title + "入口";
            item.entranceStatus.textContent = place?.selection?.name ? "已保存 · " + place.selection.name :
              hasLocation(place) ? "使用校园默认入口" : place ? "待确认入口" : "";
          }
        }

        function updateSubmit() {
          submit.disabled = !picker.hidden || !from.select.value || !to.select.value ||
            from.select.value === to.select.value || results.getAttribute("aria-busy") === "true";
        }

        function closeEntrance() {
          editRequest?.abort();
          editRequest = null;
          picker.replaceChildren();
          picker.hidden = true;
          results.hidden = false;
          from.entrance.setAttribute("aria-expanded", "false");
          to.entrance.setAttribute("aria-expanded", "false");
          updateSubmit();
        }

        function openEntrance(item) {
          const place = chosen(item);
          if (!place) return;
          closeEntrance();
          picker.hidden = false;
          results.hidden = true;
          item.entrance.setAttribute("aria-expanded", "true");
          editRequest = new AbortController();
          updateSubmit();
          routeEntrancePicker(picker, item.title, place, AbortSignal.any([signal, editRequest.signal]), {
            close() {
              closeEntrance();
              item.entrance.focus();
            },
            save(selection) {
              place.selection = selection;
              closeEntrance();
              update(item.title + "入口已保存");
              item.entrance.focus();
            },
            setSaving(saving) {
              for (const endpoint of [from, to]) {
                endpoint.select.disabled = saving;
                endpoint.entrance.disabled = saving;
              }
              swap.disabled = saving;
            },
          });
        }

        function plan() {
          if (!picker.hidden) return;
          planRequest?.abort();
          planRequest = new AbortController();
          const requestSignal = AbortSignal.any([signal, planRequest.signal]);
          const origin = from.select.value;
          const destination = to.select.value;
          const params = new URLSearchParams({ origin, destination });
          submit.disabled = true;
          void run(requestSignal, results, async () => {
            try {
              return await windows().api("/api/v1/campus-data/route?" + params, { signal: requestSignal, cache: "no-store" });
            } catch (error) {
              if (["MAP_PLACE_SELECTION_REQUIRED", "MAP_PLACE_UNRESOLVED"].includes(error.code)) {
                throw new Error("无法定位路线入口，请在上方重新选择起点或终点入口。");
              }
              throw error;
            }
          },
            value => {
              if (value.provider !== "baidu" || value.coordinate_system !== "bd09ll" || value.origin?.place_id !== origin ||
                value.destination?.place_id !== destination || !Array.isArray(value.polyline) || value.polyline.length < 2 ||
                value.polyline.length > 20000 || !value.polyline.every(validPoint) ||
                !validPoint(value.origin.location) || !validPoint(value.destination.location) ||
                value.package_id !== data.package.package_id || value.package_version !== data.package.version) {
                throw new Error("未取得可显示的百度步行路线。");
              }
              results.replaceChildren(node("h3", value.origin.name + " → " + value.destination.name),
                statusText("约 " + value.total_minutes + " 分钟 · " + value.distance_meters + " 米"));
              const endpoint = item => ({ place_id: item.place_id, location: item.location });
              const routeOrigin = endpoint(value.origin);
              const routeDestination = endpoint(value.destination);
              drawMap(results, { origin: routeOrigin, destination: routeDestination, route: {
                provider: value.provider, coordinate_system: value.coordinate_system,
                origin: routeOrigin, destination: routeDestination, polyline: value.polyline,
              } }, requestSignal);
              const steps = node("ol", undefined, "win-campus-steps");
              for (const step of value.steps) steps.append(node("li", step.instruction));
              results.append(steps);
              if (value.note) results.append(statusText(value.note));
              addSource(results, value);
            }, plan).finally(() => { if (!requestSignal.aborted) updateSubmit(); });
        }

        endpoints.append(from.wrapper, to.wrapper);
        actions.append(routeStatus, swap, submit);
        inputs.replaceChildren(endpoints, actions, picker);
        if (routeDraft?.owner === scope) {
          from.select.value = routeDraft.origin;
          to.select.value = routeDraft.destination;
        }
        update();
      }, load);
    }
    load();
  }

  function routeField(title, places) {
    const wrapper = node("div", undefined, "win-campus-endpoint");
    const { wrapper: label, select } = field(title, [["", "选择" + title]]);
    const searchLabel = node("label", "查找" + title);
    const search = node("input");
    search.type = "search";
    search.placeholder = "地点、简称或区域";
    searchLabel.append(search);
    const entranceStatus = node("p", "", "win-campus-status");
    const entrance = node("button", "选择" + title + "入口", "line-button desktop-route-entrance");
    entrance.type = "button";
    entrance.setAttribute("aria-controls", "desktopCampusEntrancePicker");
    entrance.setAttribute("aria-expanded", "false");
    const entranceRow = node("div", undefined, "win-campus-endpoint-entrance");
    entranceRow.append(entranceStatus, entrance);
    wrapper.append(searchLabel, label, entranceRow);

    function refresh() {
      const current = select.value;
      const words = search.value.trim().toLowerCase().split(/\s+/);
      select.querySelectorAll("option:not(:first-child)").forEach(option => option.remove());
      for (const place of places) {
        const terms = [place.name, ...(place.aliases ?? []), place.zone].join(" ").toLowerCase();
        if (place.place_id === current || words.every(word => terms.includes(word))) {
          const alias = place.aliases?.[0];
          const option = node("option", alias && alias !== place.name ? `${place.name} · ${alias}` : place.name);
          option.value = place.place_id;
          select.append(option);
        }
      }
      select.value = current;
    }

    search.addEventListener("input", refresh);
    refresh();
    return { title, wrapper, select, entrance, entranceStatus, resetSearch: () => { search.value = ""; refresh(); } };
  }

  function routeEntrancePicker(panel, role, place, signal, actions) {
    const title = node("h3", "选择" + role + "入口");
    title.id = "desktopCampusEntranceTitle";
    panel.setAttribute("aria-labelledby", title.id);
    const form = node("form", undefined, "win-campus-filters");
    const label = node("label", "入口关键词");
    const input = node("input");
    input.type = "search";
    input.maxLength = 120;
    input.placeholder = "例如：北门（留空按地点名称搜索）";
    label.append(input);
    const find = node("button", "搜索入口", "line-button");
    find.type = "submit";
    form.append(label, find);
    const status = statusText("");
    const options = node("div", undefined, "win-campus-entrance-options");
    const map = node("div", undefined, "win-campus-entrance-map");
    const more = button("加载更多", () => void search(page + 1));
    const matches = node("div", undefined, "win-campus-entrance-matches");
    matches.append(options, more);
    const previews = node("div", undefined, "win-campus-entrance-results");
    previews.append(matches, map);
    const footer = node("div", undefined, "win-campus-route-actions");
    const cancel = button("取消", actions.close);
    const confirm = button("确认入口", () => void save(), "primary-action");
    footer.append(cancel, confirm);
    panel.replaceChildren(title, node("p", place.name, "win-campus-status"), form, status, previews, footer);
    let selected, searchRequest, mapRequest;
    let candidates = [];
    let page = 0;
    let hasMore = false;
    let busy = false;
    let saving = false;
    const path = "/api/v1/campus-data/places/" + encodeURIComponent(place.place_id);
    const live = () => !signal.aborted && panel.isConnected;

    function announce(message, error = false) {
      status.textContent = message;
      status.classList.toggle("win-campus-error", error);
    }

    function controls() {
      find.disabled = busy || saving;
      input.disabled = saving;
      more.hidden = !hasMore;
      more.disabled = busy || saving;
      cancel.disabled = saving;
      confirm.disabled = !selected || busy || saving;
      for (const control of options.querySelectorAll("button")) control.disabled = busy || saving;
    }

    function clearPreview() {
      selected = null;
      mapRequest?.abort();
      map.replaceChildren();
    }

    function resetSearch() {
      searchRequest?.abort();
      clearPreview();
      candidates = [];
      options.replaceChildren();
      busy = false;
      hasMore = false;
    }

    function renderCandidates() {
      options.replaceChildren(...candidates.map(option => {
        const control = button("预览", () => {
          if (Date.now() >= option.expiresAt) {
            resetSearch();
            announce("候选已过期，请重新搜索。", true);
            controls();
            find.focus();
            return;
          }
          clearPreview();
          selected = option;
          options.querySelector('[aria-pressed="true"]')?.setAttribute("aria-pressed", "false");
          control.setAttribute("aria-pressed", "true");
          mapRequest = new AbortController();
          drawMap(map, {
            origin: { place_id: place.place_id, location: option.candidate.location },
            destination: null, route: null, preview: true,
          }, AbortSignal.any([signal, mapRequest.signal]));
          announce("已选 · " + option.candidate.name);
          controls();
        }, "line-button win-campus-entrance-preview");
        control.setAttribute("aria-label", "预览 " + option.candidate.name);
        control.setAttribute("aria-pressed", "false");
        return row(option.candidate.name, option.candidate.address || "地址未提供，请核对地图。", control);
      }));
    }

    async function search(nextPage) {
      if (busy || saving) return;
      if (nextPage === 0) resetSearch();
      else {
        clearPreview();
        options.querySelector('[aria-pressed="true"]')?.setAttribute("aria-pressed", "false");
      }
      searchRequest = new AbortController();
      const pending = AbortSignal.any([signal, searchRequest.signal]);
      const params = new URLSearchParams({ page: String(nextPage) });
      const query = input.value.trim();
      if (query) params.set("query", query);
      busy = true;
      controls();
      announce("正在搜索入口…");
      try {
        const result = await windows().api(path + "/candidates?" + params, { signal: pending, cache: "no-store" });
        if (!live() || pending.aborted) return;
        const expiresAt = Date.parse(result.expires_at);
        if (result.place_id !== place.place_id || result.page !== nextPage || !Array.isArray(result.candidates) ||
          !Number.isFinite(expiresAt)) throw new Error("Invalid entrance candidates");
        const next = result.candidates.filter(candidate => typeof candidate?.name === "string" &&
          typeof candidate.selection_token === "string" && !!candidate.selection_token && validPoint(candidate.location));
        candidates.push(...next.map(candidate => ({ candidate, expiresAt })));
        page = nextPage;
        hasMore = result.has_more === true && page < 4;
        renderCandidates();
        announce(next.length ? "" : "本页没有匹配入口，可换个关键词再搜索。");
      } catch (error) {
        if (live() && !pending.aborted) announce(windows().campusPlaceError(error), true);
      } finally {
        if (live() && !pending.aborted) {
          busy = false;
          controls();
        }
      }
    }

    async function save() {
      if (!selected || saving || busy) return;
      if (Date.now() >= selected.expiresAt) {
        resetSearch();
        announce("候选已过期，请重新搜索。", true);
        controls();
        find.focus();
        return;
      }
      saving = true;
      actions.setSaving(true);
      controls();
      announce("正在保存入口…");
      let selection;
      try {
        const result = await windows().api(path + "/selection", {
          signal, cache: "no-store", method: "PUT", headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ selection_token: selected.candidate.selection_token }),
        });
        if (!live()) return;
        if (result?.place_id !== place.place_id || typeof result.name !== "string" || !validPoint(result.location)) {
          throw new Error("Invalid entrance selection");
        }
        selection = result;
      } catch (error) {
        if (!live()) return;
        if (error.code === "MAP_SELECTION_INVALID") resetSearch();
        announce(windows().campusPlaceError(error, true), true);
      } finally {
        if (live()) {
          saving = false;
          actions.setSaving(false);
          controls();
        }
      }
      if (live() && selection) actions.save(selection);
    }

    form.addEventListener("submit", event => {
      event.preventDefault();
      void search(0);
    });
    input.addEventListener("input", () => {
      if (saving) return;
      resetSearch();
      announce("");
      controls();
    });
    input.focus();
    void search(0);
  }

  function drawMap(target, mapState, signal) {
    const viewport = node("div");
    target.append(viewport);
    const expected = new URL(mapDocument, location.origin).href;
    signal.addEventListener("abort", () => viewport.replaceChildren(), { once: true });
    mount();

    function mount() {
      if (signal.aborted || !viewport.isConnected) return;
      const frame = node("iframe", undefined, "win-campus-map");
      frame.title = mapState.preview ? "校园入口地图预览" : "校园步行路线地图";
      frame.src = mapDocument;
      frame.setAttribute("allow", "geolocation 'none'");
      frame.referrerPolicy = "strict-origin-when-cross-origin";
      frame.addEventListener("load", async () => {
        try {
          if (frame.contentWindow.location.href !== expected) throw new Error("invalid map");
          const bridge = frame.contentWindow.CampusFlowMap;
          if (typeof bridge?.setConfig !== "function" || typeof bridge.setState !== "function") throw new Error("invalid map");
          const options = { signal, cache: "no-store" };
          let config;
          try { config = await windows().api("/api/v1/me/baidu-maps/config", options); }
          catch (error) {
            if (error.status !== 404 || signal.aborted) throw error;
            config = await windows().api("/api/v1/maps/baidu/config", options);
          }
          if (signal.aborted || !frame.isConnected) return;
          const browserAk = typeof config?.browser_ak === "string" ? config.browser_ak.trim() : "";
          if (config?.configured !== true || !browserAk) {
            viewport.replaceChildren(statusText(mapState.preview ? "地图预览未配置，请核对入口名称和地址。" :
              "地图浏览器密钥未配置，仍可查看步行步骤。", true));
            if (!mapState.preview) viewport.append(button("打开地图配置", () => windows().open("settings")));
            return;
          }
          bridge.setConfig({ configured: true, browser_ak: browserAk,
            route_configured: config.route_configured === true,
            campus_query: config.campus_query, city: config.city });
          bridge.setState({ ...mapState, active: true });
        } catch {
          if (!signal.aborted && frame.isConnected) viewport.replaceChildren(
            statusText(mapState.preview ? "地图暂时不可用，请核对入口名称和地址。" :
              "地图暂时不可用，仍可查看步行步骤。", true), button("重试加载地图", mount));
        }
      }, { once: true });
      viewport.replaceChildren(frame);
    }
  }

  function weather(host, signal) {
    const card = section("今日天气", button("刷新预报", load));
    const results = node("div", undefined, "win-campus-results");
    let expirationTimer;
    signal.addEventListener("abort", () => clearTimeout(expirationTimer), { once: true });
    card.append(results);
    host.append(card);

    function load() {
      if (results.getAttribute("aria-busy") === "true") return;
      clearTimeout(expirationTimer);
      const date = dateKey.format();
      void run(signal, results, () => windows().api(`/api/v1/weather?${new URLSearchParams({ date })}`, { signal, cache: "no-store" }), data => {
        if (data?.date !== date || typeof data.available !== "boolean") {
          throw new Error("预报日期无法核对，请刷新后重试。");
        }
        const evidence = Array.isArray(data.evidence) ? data.evidence.filter(item => typeof item?.label === "string") : [];
        const now = Date.now();
        const fresh = evidence.find(item => {
          const updated = Date.parse(item.updated_at);
          const expires = Date.parse(item.expires_at);
          return item.kind === "remote" && item.status === "fresh" && updated <= now && expires > now;
        });
        const expiration = fresh && formatDate(fresh.expires_at);
        const location = [data.location_label, date].filter(Boolean).join(" · ");
        results.replaceChildren();
        if (data.available && fresh && dateKey.format() === date && typeof data.condition === "string" && data.condition.trim()) {
          const temperature = [data.temperature_min_c, data.temperature_max_c].map(value => Number.isFinite(value) ? `${value} °C` : "—").join(" 至 ");
          const rain = Number.isFinite(data.precipitation_probability) ? `${data.precipitation_probability}%` : "未知";
          const forecast = node("div", undefined, "win-campus-metric");
          forecast.append(node("p", location), node("strong", data.condition), node("p", `${temperature} · 降水概率 ${rain}`));
          const validity = statusText(`预报有效至 ${expiration}（北京时间）`);
          results.append(forecast, validity);
          expirationTimer = setTimeout(() => {
            forecast.replaceWith(statusText(location));
            validity.textContent = "暂无当前有效预报，请刷新后核对。";
          }, Math.min(Date.parse(fresh.expires_at) - now, 2_147_483_647));
        } else {
          const failed = evidence.some(item => item.status === "error");
          const stale = evidence.some(item => item.status === "stale") || data.available;
          const message = failed ? "预报读取失败，请稍后刷新。" : stale ? "暂无当前有效预报，请刷新后核对。" : "暂无可用预报。";
          results.append(statusText(message, failed), statusText(location));
        }
        addSource(results, { evidence });
      }, load);
    }

    load();
  }

  function knowledge(host, signal) {
    const card = section("校园办事指南");
    const form = node("form", undefined, "win-campus-filters");
    const label = node("label", "查询公开资料");
    const query = node("input");
    query.type = "search";
    query.required = true;
    query.placeholder = "例如：校外怎样访问图书馆数据库？";
    const submit = node("button", "查询", "primary-action");
    submit.type = "submit";
    const results = node("div", undefined, "win-campus-results");
    const owner = scope;
    let revision = 0;
    let sourceController;
    const current = (attempt) => !signal.aborted && card.isConnected && key() === owner && revision === attempt;
    const topic = (title, excerpt) => {
      const block = node("div", undefined, "win-campus-knowledge-topic");
      block.append(node("h3", title), node("p", excerpt));
      return block;
    };

    async function readSource(item, target, control, attempt) {
      sourceController?.abort();
      const controller = new AbortController();
      sourceController = controller;
      const pending = AbortSignal.any([signal, controller.signal]);
      target.replaceChildren(statusText("正在读取出处…"));
      try {
        const detail = await windows().api(`/api/v1/knowledge/sources/${encodeURIComponent(item.source_id)}`, { signal: pending });
        if (!current(attempt) || pending.aborted) return;
        if (detail?.source_id !== item.source_id || typeof detail.excerpt !== "string") throw new Error("Invalid source");
        target.replaceChildren(topic(detail.section, detail.excerpt), statusText(`资料范围 · ${detail.school} ${detail.campus} · ${detail.reviewed_at} 核对`));
        if (window.campusFlowDesktop?.openKnowledgeSource && typeof detail.url === "string") {
          const link = button("在浏览器打开官方原文", async () => {
            const opened = await window.campusFlowDesktop.openKnowledgeSource(detail.url).catch(() => false);
            if (!opened && current(attempt) && link.isConnected) windows().toast("无法打开该资料链接。", "error");
          });
          target.append(link);
        }
      } catch {
        if (current(attempt) && !pending.aborted) target.replaceChildren(statusText("出处暂未读取，请稍后重试。", true));
      } finally { control.disabled = false; }
    }

    form.addEventListener("submit", async (event) => {
      event.preventDefault();
      const value = query.value.trim();
      const attempt = ++revision;
      sourceController?.abort();
      if (!value || [...value].length > 200) { results.replaceChildren(statusText("请输入 1–200 字的问题。", true)); return; }
      submit.disabled = true;
      results.replaceChildren(statusText("正在查询…"));
      try {
        const data = await windows().api(`/api/v1/knowledge/search?${new URLSearchParams({ q: value })}`, { signal });
        if (!current(attempt)) return;
        if (!["found", "missing", "unsupported"].includes(data?.status) || !Array.isArray(data.hits) ||
            data.hits.length > 3 || data.hits.some(item => !/^hdu-[a-z0-9-]{1,80}$/.test(item?.source_id ?? ""))) throw new Error("Invalid results");
        if (data.status !== "found" || !data.hits.length) { results.replaceChildren(statusText(data.message)); return; }
        results.replaceChildren(...data.hits.map(item => {
          const group = node("article", undefined, "win-campus-group");
          const detail = node("div", undefined, "win-campus-knowledge-detail");
          const control = button("查看摘录与出处", () => {
            control.disabled = true;
            void readSource(item, detail, control, attempt);
          });
          group.append(topic(item.title, item.summary), control, detail);
          return group;
        }));
      } catch { if (current(attempt)) results.replaceChildren(statusText("暂时无法查询校园资料，请检查连接后重试。", true)); }
      finally { if (current(attempt)) submit.disabled = false; }
    });
    label.append(query);
    form.append(label, submit);
    card.append(form, statusText("资料收录杭电下沙校区部分官方指南。实时信息请查看对应校园服务。"), results);
    host.append(card);
  }

  function render() {
    cancel();
    if (routeDraft && routeDraft.owner !== windows()?.user()?.user_id) routeDraft = null;
    scope = key();
    if (!scope) {
      root.replaceChildren();
      return;
    }
    request = new AbortController();
    const tools = node("div", undefined, "win-campus-tabs");
    tools.setAttribute("aria-label", "校园服务分类");
    for (const [id, label] of services) {
      const item = button(label, () => {
        if (id !== active) {
          active = id;
          render();
          root.querySelector('[aria-pressed="true"]')?.focus();
        }
      });
      item.setAttribute("aria-pressed", String(id === active));
      tools.append(item);
    }
    const head = node("header", undefined, "win-campus-heading");
    head.append(node("h1", "校园服务"), button("校园资料与连接", manage));
    const host = node("div", undefined, "win-campus-content");
    root.replaceChildren(head, tools, host);
    if (active === "classrooms") classrooms(host, request.signal);
    else if (active === "electricity") electricity(host, request.signal);
    else if (active === "route") route(host, request.signal);
    else if (active === "weather") weather(host, request.signal);
    else if (active === "knowledge") knowledge(host, request.signal);
    else accountServices(host, request.signal, active === "library");
  }

  const visibility = new MutationObserver(() => {
    if (key() !== scope) render();
  });
  for (const element of [appView, surface]) visibility.observe(element, { attributes: true, attributeFilter: ["hidden"] });
  window.addEventListener("pagehide", cancel);
  render();
})();
