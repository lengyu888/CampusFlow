(() => {
  const app = window.CampusFlowWindows;
  if (!app) return;

  const focus = document.getElementById("windowsFocusRoot");
  const review = document.getElementById("windowsReviewRoot");
  const request = (path, options = {}) => app.api(path, { ...options, signal: AbortSignal.timeout(7000) });
  const post = (path, payload) => request(path, {
    method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(payload),
  });
  const button = (title, action, primary = false) => {
    const node = document.createElement("button");
    node.className = `wf-button${primary ? " primary" : ""}`;
    node.type = "button";
    node.textContent = title;
    node.addEventListener("click", action);
    return node;
  };
  const dateKey = () => new Intl.DateTimeFormat("sv-SE", { timeZone: "Asia/Shanghai" }).format(new Date());
  const when = (value) => new Intl.DateTimeFormat("zh-CN", { dateStyle: "medium", timeStyle: "short", timeZone: "Asia/Shanghai" }).format(new Date(value));
  const userId = () => app.user()?.user_id ?? null;
  const key = (kind, owner = userId()) => `campusflow.windows.${kind}:${owner}`;
  const duration = (ms = 0) => {
    const seconds = Math.floor(ms / 1000);
    return `${Math.floor(seconds / 60)} 分 ${seconds % 60} 秒`;
  };
  const getSaved = (storageKey) => {
    try { return JSON.parse(localStorage.getItem(storageKey)); } catch { return null; }
  };
  const deviceKey = "campusflow.windows.focus-device";
  let device;
  try {
    device = localStorage.getItem(deviceKey) ?? app.uuid();
    localStorage.setItem(deviceKey, device);
  } catch { device = null; }
  let tab = "";
  let owner = null;
  let ownerEpoch = 0;
  let record = null;
  let live = null;
  let localLive = null;
  let localRecords = [];
  let localReady = false;
  let localStorageError = "";
  let selectedTask = null;
  let taskOptions = [];
  let serverHistory = [];
  let historyCursor = null;
  let historyToken = null;
  let historyBusy = false;
  let completionTask = null;
  let syncBusy = false;
  let pending = false;
  let reviewPeriod = "day";
  let reviewDate = dateKey();
  let focusLoad = 0;
  let reviewLoad = 0;

  focus.innerHTML = `<div class="wf-page"><header class="wf-head"><h1>专注</h1><div data-focus-refresh></div></header>
    <section class="wf-card" data-focus-start><h2>开始专注</h2><div class="wf-controls">
      <label>待办<select class="wf-input" data-focus-task></select></label>
      <label>目标分钟（可选）<input class="wf-input" type="number" min="1" max="240" placeholder="正向计时" data-focus-target></label>
      <label>记录方式<select class="wf-input" data-focus-mode><option value="online">联网记录</option><option value="offline">仅在本机记录</option></select></label>
      <div data-focus-start-action></div></div><p data-focus-mode-help hidden>恢复连接后可手动同步本机记录。</p></section>
    <section class="wf-card" data-focus-active hidden><h2 data-focus-title></h2><div class="wf-timer" data-focus-timer></div><p data-focus-state></p><div class="wf-controls" data-focus-actions></div></section>
    <p class="wf-status" data-focus-status role="status"></p>
    <section class="wf-card" data-focus-completion hidden><h2>任务做完了吗？</h2><div data-focus-completion-action></div></section>
    <section class="wf-card" data-focus-local hidden><h2>本机记录</h2><div class="wf-list" data-focus-local-list></div><div class="wf-controls" data-focus-sync-actions></div></section>
    <section class="wf-card"><h2>已同步记录</h2><div class="wf-list" data-focus-list></div><div data-focus-more hidden></div></section></div>`;
  review.innerHTML = `<div class="wf-page"><header class="wf-head"><h1>回顾</h1><div data-review-refresh></div></header>
    <section class="wf-card"><div class="wf-controls"><label>范围<select class="wf-input" data-review-period><option value="day">一天</option><option value="week">一周</option></select></label>
    <label>日期<input class="wf-input" type="date" data-review-date></label></div><p data-review-window></p><div class="wf-stat-grid" data-review-totals></div></section>
    <p class="wf-status" data-review-status role="status"></p><section class="wf-card"><h2>统计明细</h2><div class="wf-list" data-review-details></div></section>
    <section class="wf-card"><h2>回顾笔记</h2><textarea class="wf-input wf-note" maxlength="1500" aria-label="回顾笔记" placeholder="记下今天的收获，仅保存在这台电脑。" data-review-note></textarea><div data-review-save></div></section></div>`;

  const f = (name) => focus.querySelector(`[data-focus-${name}]`);
  const r = (name) => review.querySelector(`[data-review-${name}]`);
  const sameOwner = (value, epoch = ownerEpoch) => value && userId() === value && epoch === ownerEpoch;
  const sameSegment = (value, active = record) => value && active?.record_id === value.recordId && active.segment_id === value.segmentId;
  const localActive = () => localRecords.find((item) => item.state !== "ended");
  const displayedRecord = () => localActive() ?? record;
  const asTime = (value) => new Date(value).toISOString();
  const now = () => ({ wall: Date.now(), mono: Math.round(performance.now()) });

  function makeAnchor(recordId, payload) {
    const clock = now();
    return { recordId, segmentId: payload.operation_id, clockId: payload.clock_session_id, intervalId: app.uuid(),
      started: clock.wall, lastWall: clock.wall, lastMono: clock.mono, elapsed: 0, checkpoint: clock.mono };
  }

  function makePayload(kind, active, wall) {
    const payload = { kind, operation_id: app.uuid(), expected_revision: kind === "start" ? 0 : active.revision,
      device_id: device, occurred_at: asTime(wall) };
    if (["start", "resume"].includes(kind)) payload.clock_session_id = app.uuid();
    if (["pause", "end"].includes(kind)) {
      const own = active.state === "running" && active.current_device_id === device;
      Object.assign(payload, { segment_id: own ? active.segment_id : null, clock_session_id: own ? active.clock_session_id : null,
        intervals: [], unknown_gaps: [] });
      if (kind === "end") payload.reason = active.state === "running" && !own ? "remote_end" : "local_end";
    }
    return payload;
  }

  function projectLocal(active, payload, anchor) {
    const { kind, expected_revision: revision } = payload;
    const state = anchor ? "running" : kind === "end" ? "ended" : "paused";
    return { ...active, state, revision: revision + 1, anchor: checkpoint(anchor), segment_id: anchor?.segmentId ?? null,
      clock_session_id: anchor?.clockId ?? null,
      confirmed_elapsed_ms: active.confirmed_elapsed_ms + (payload.intervals ?? []).reduce((sum, item) => sum + item.elapsed_ms, 0),
      operations: [...active.operations, { payload, dispatch: "queued" }] };
  }

  function sample(anchor, clock) {
    const delta = clock.mono - anchor.lastMono;
    if (delta > 10000 || anchor.elapsed + delta > 86400000) return "sample_gap";
    if (delta < 0 || Math.abs(clock.wall - anchor.lastWall - delta) > 2000 ||
        Math.abs(clock.wall - anchor.started - (anchor.elapsed + delta)) > 2000) return "clock_changed";
    anchor.elapsed += delta;
    anchor.lastMono = clock.mono;
    anchor.lastWall = clock.wall;
    return null;
  }

  function checkpoint(anchor) {
    if (!anchor) return null;
    const { recordId, segmentId, clockId, intervalId, started, lastWall, elapsed } = anchor;
    return { recordId, segmentId, clockId, intervalId, started, lastWall, elapsed };
  }

  function closedFragments(anchor, reason, observedEnd) {
    if (!anchor) return { intervals: [], unknown_gaps: [] };
    const intervals = anchor.elapsed > 0 ? [{ interval_id: anchor.intervalId, segment_id: anchor.segmentId,
      clock_session_id: anchor.clockId, sequence: 1, started_at: asTime(anchor.started),
      ended_at: asTime(anchor.started + anchor.elapsed), elapsed_ms: anchor.elapsed }] : [];
    const unknown_gaps = reason ? [{ gap_id: app.uuid(), segment_id: anchor.segmentId, reason,
      observed_start_at: asTime(anchor.lastWall), observed_end_at: asTime(observedEnd) }] : [];
    return { intervals, unknown_gaps };
  }

  function paintTimer() {
    const active = displayedRecord();
    if (!active || active.state === "ended") return;
    const anchor = active.local ? localLive : live;
    const elapsed = active.confirmed_elapsed_ms + (sameSegment(anchor, active) ? anchor.elapsed : 0);
    f("timer").textContent = duration(elapsed);
    const state = f("state");
    if (active.state === "running" && sameSegment(anchor, active) && active.target_ms && elapsed >= active.target_ms) {
      state.textContent = `${active.local ? "仅本机 · " : ""}已达目标，计时继续。`;
    }
  }

  function checkReceipt(response, scope, recordId, payload) {
    const receipt = response?.receipt;
    const statuses = { start: "running", resume: "running", pause: "paused", end: "ended", delete: "deleted" };
    const intervals = payload.intervals ?? [];
    const gaps = payload.unknown_gaps ?? [];
    const remoteEnd = payload.kind === "end" && payload.reason === "remote_end";
    if (response?.user_id !== scope || response.record_id !== recordId || response.operation_id !== payload.operation_id ||
        response.kind !== payload.kind || receipt?.before_revision !== payload.expected_revision ||
        receipt.after_revision !== payload.expected_revision + 1 || receipt.after_state !== statuses[payload.kind] ||
        !Array.isArray(receipt.accepted_interval_ids) || receipt.accepted_interval_ids.length !== intervals.length ||
        intervals.some(item => !receipt.accepted_interval_ids.includes(item.interval_id)) ||
        !Array.isArray(receipt.accepted_gap_ids) || (!remoteEnd && receipt.accepted_gap_ids.length !== gaps.length) ||
        gaps.some(item => !receipt.accepted_gap_ids.includes(item.gap_id)) ||
        receipt.added_elapsed_ms !== intervals.reduce((total, item) => total + item.elapsed_ms, 0)) {
      throw new Error("服务器返回的专注回执无法核对。请刷新确认状态。");
    }
    return response;
  }

  function row(title, meta) {
    const node = document.createElement("div");
    node.className = "wf-row";
    const copy = document.createElement("div");
    const name = document.createElement("strong");
    const detail = document.createElement("small");
    name.textContent = title;
    detail.textContent = meta;
    copy.append(name, detail);
    node.append(copy);
    return node;
  }

  function paintFocus() {
    const current = displayedRecord();
    const active = current && current.state !== "ended";
    const ownsSegment = current?.current_device_id === device;
    f("start").hidden = Boolean(active);
    f("active").hidden = !active;
    f("start-action").querySelector("button").disabled = !device || pending || syncBusy ||
      (f("mode").value === "offline" && !localReady) || (f("mode").value === "online" && Boolean(getSaved(key("focus-operation"))));
    f("completion").hidden = !completionTask || Boolean(active) || !app.completeFocusTask;
    paintLocalList();
    if (!active) return;
    const name = current.local ? taskTitle(current.task_id) : current.task_title;
    const anchor = current.local ? localLive : live;
    f("title").textContent = name ?? "关联任务不可用";
    const mode = current.local ? "仅本机 · " : "";
    f("state").textContent = mode + (current.state === "paused" ? "已暂停" : sameSegment(anchor, current) ?
      `计时中${current.target_ms ? ` · 目标 ${current.target_ms / 60000} 分钟` : ""}` :
      ownsSegment ? "计时曾中断，未核实的时长不计入。" : "正在另一台设备计时。");
    const actions = [];
    if (current.state === "paused") actions.push(button("继续", () => operate("resume"), true));
    if (current.state === "running" && ownsSegment) actions.push(button("暂停", () => operate("pause"), true));
    actions.push(button(ownsSegment || current.state === "paused" ? "结束" : "结束另一台设备的专注", () => operate("end")));
    for (const action of actions) action.disabled = pending || syncBusy || !device ||
      (!current.local && Boolean(getSaved(key("focus-operation"))));
    f("actions").replaceChildren(...actions);
    paintTimer();
  }

  function updateTaskOptions(tasks = []) {
    const previous = selectedTask?.id ?? f("task").value;
    const byId = new Map(tasks.filter(item => item?.status === "pending" && typeof item.task_id === "string" &&
      item.task_id.length > 0 && item.task_id.length <= 128 && typeof item.title === "string").map(item => [item.task_id, item]));
    if (selectedTask && !byId.has(selectedTask.id)) {
      byId.set(selectedTask.id, { task_id: selectedTask.id, title: selectedTask.title });
    }
    taskOptions = [...byId.values()];
    f("task").replaceChildren(new Option(taskOptions.length ? "请选择待办" : "暂无未完成待办", ""),
      ...taskOptions.map(item => new Option(item.title, item.task_id)));
    if (byId.has(previous)) f("task").value = previous;
  }

  function taskTitle(taskId) {
    return taskOptions.find(item => item.task_id === taskId)?.title ?? serverHistory.find(item => item.task_id === taskId)?.task_title;
  }

  app.focusTask = (id, title) => {
    if (!userId() || typeof id !== "string" || !id || id.length > 128 || typeof title !== "string") return;
    selectedTask = { id, title };
    app.open("focus");
    if (!f("start").hidden) f("task").focus();
  };

  function paintLocalList() {
    const section = f("local");
    const actions = [];
    const first = localRecords.find(item => item.operations.length)?.operations[0];
    const outstanding = getSaved(key("focus-operation"));
    const entries = localRecords.map(item => {
      const action = item.operations[0];
      const blocked = action?.dispatch === "conflict";
      const status = blocked ? "同步冲突" : action?.dispatch === "unknown" ? "待核对" : item.operations.length ? "待同步" : "已同步";
      const entry = row(taskTitle(item.task_id) ?? "本机专注", `${when(item.started_at)} · ${duration(item.confirmed_elapsed_ms)} · ${status}`);
      if (item.state === "ended" || blocked) {
        const remove = button("清除本机副本", () => {
          if (!window.confirm("清除这条记录在本机的副本？服务端已保存的记录会继续保留。")) return;
          try { saveLocal(localRecords.filter(other => other !== item)); }
          catch (error) { f("status").textContent = error.message; }
          if (localLive?.recordId === item.record_id) localLive = null;
          paintFocus();
        });
        // An unverified send may have reached the server. Keep its receipt accessible.
        remove.disabled = pending || syncBusy || item.operations.some(item => item.dispatch === "unknown");
        entry.append(remove);
      }
      if (blocked && action.message) {
        const message = document.createElement("p");
        message.className = "wf-focus-conflict";
        message.textContent = action.message;
        entry.append(message);
      }
      return entry;
    });
    section.hidden = !(entries.length || outstanding || localStorageError);
    if (localStorageError) entries.unshift(row("本机记录不可用", localStorageError));
    f("local-list").replaceChildren(...entries);
    if (outstanding?.dispatch === "not_found") actions.push(button("重试原联网操作", () => checkFocus(true), true));
    else if (outstanding) actions.push(button("核对联网操作", () => checkFocus()));
    else if (first?.dispatch === "unknown") actions.push(button("核对本机同步结果", () => syncLocal("check"), true));
    else if (first?.dispatch === "not_found") actions.push(button("重试原同步操作", () => syncLocal("retry"), true));
    else if (first?.dispatch === "queued") actions.push(button("同步本机记录", () => syncLocal("send"), true));
    for (const action of actions) action.disabled = pending || syncBusy || localActive()?.state === "running";
    f("sync-actions").replaceChildren(...actions);
  }

  function saveLocal(items) {
    try {
      const value = JSON.stringify({ version: 1, records: items });
      if (value.length > 4000000) throw new Error("capacity");
      localStorage.setItem(key("focus-local"), value);
      localRecords = items;
      localStorageError = "";
    } catch {
      localStorageError = "未能写入本机。请检查可用空间后重试。";
      throw new Error(localStorageError);
    }
  }

  function recoverLocal() {
    if (localReady || !device) return;
    try {
      const raw = localStorage.getItem(key("focus-local"));
      if (raw) {
        const saved = JSON.parse(raw);
        if (saved?.version !== 1 || !Array.isArray(saved.records) || saved.records.length > 20 ||
            saved.records.some(item => !item.local || !item.record_id || !["running", "paused", "ended"].includes(item.state) ||
              !Array.isArray(item.operations) || (item.state === "running" && !sameSegment(item.anchor, item)))) {
          throw new Error("invalid cache");
        }
        localRecords = saved.records;
      }
      const current = localActive();
      if (current?.state === "running") {
        const payload = makePayload("pause", current, Date.now());
        Object.assign(payload, closedFragments(current.anchor, "process_interrupted", Date.now()));
        saveLocal(localRecords.map(item => item === current ? projectLocal(current, payload, null) : item));
        f("status").textContent = "上次计时中断，已保留最近保存的片段。";
      }
      localReady = true;
      localStorageError = "";
    } catch {
      localRecords = [];
      localStorageError = "无法读取本机记录。已有数据已保留，请关闭页面后重试。";
    }
  }

  function paintHistory(scope, epoch) {
    f("list").replaceChildren(...(serverHistory.length ? serverHistory.map(item => {
      const entry = row(item.task_title ?? "关联任务不可用", `${when(item.started_at)} · ${duration(item.confirmed_elapsed_ms)}`);
      const detailButton = button("查看详情", async () => {
        const open = entry.querySelector(".wf-focus-detail");
        if (open) { open.remove(); detailButton.textContent = "查看详情"; detailButton.setAttribute("aria-expanded", "false"); return; }
        detailButton.disabled = true;
        try {
          const detail = await request(`/api/v1/focus-records/${item.record_id}`);
          if (!sameOwner(scope, epoch) || !entry.isConnected) return;
          if (detail.user_id !== scope || detail.record?.record_id !== item.record_id) throw new Error("无法核对专注详情。");
          const description = document.createElement("div");
          description.className = "wf-focus-detail";
          renderFragments(description, detail);
          const remove = button("删除记录", () => {
            if (!sameOwner(scope, epoch) || pending || syncBusy || !device || localActive()?.state === "running" ||
                getSaved(key("focus-operation", scope)) || !window.confirm("删除这条已同步专注记录？")) return;
            const payload = makePayload("delete", detail.record, Date.now());
            void submitOnline(scope, epoch, { recordId: detail.record.record_id, payload }, true);
          });
          description.append(remove);
          entry.append(description);
          detailButton.textContent = "收起详情";
          detailButton.setAttribute("aria-expanded", "true");
        } catch (error) { if (sameOwner(scope, epoch)) app.toast(error.message, "error"); }
        finally { detailButton.disabled = false; }
      });
      detailButton.setAttribute("aria-expanded", "false");
      entry.append(detailButton);
      return entry;
    }) : [row("暂无已同步记录", "完成专注并同步后，可在这里查看。")]));
    f("more").hidden = !historyCursor;
    f("more").querySelector("button").disabled = historyBusy;
  }

  function renderFragments(container, detail) {
    const labels = { process_interrupted: "计时进程中断", clock_changed: "系统时钟变化", sample_gap: "计时采样中断",
      remote_end: "由另一台设备结束", storage_failed: "本机保存中断" };
    const all = [
      ...detail.intervals.map(item => [duration(item.elapsed_ms), `${when(item.started_at)} 至 ${when(item.ended_at)}`]),
      ...detail.unknown_gaps.map(item => [labels[item.reason] ?? "未核实的区间", `${when(item.observed_start_at)} · 不计时长`]),
    ];
    const list = document.createElement("div");
    const controls = document.createElement("div");
    controls.className = "wf-controls";
    let page = 0;
    const paint = () => {
      list.replaceChildren(...all.slice(page * 20, (page + 1) * 20).map(([title, meta]) => row(title, meta)));
      previous.disabled = page === 0;
      next.disabled = (page + 1) * 20 >= all.length;
    };
    const previous = button("上一页", () => { page--; paint(); });
    const next = button("下一页", () => { page++; paint(); });
    controls.append(previous, next);
    const count = document.createElement("p");
    count.textContent = `${detail.intervals.length} 段已确认 · ${detail.unknown_gaps.length} 段未计入`;
    container.append(count, list);
    if (all.length > 20) container.append(controls);
    paint();
  }

  async function loadMoreHistory() {
    const scope = userId();
    const epoch = ownerEpoch;
    const revision = focusLoad;
    if (!scope || historyBusy || pending || syncBusy || !historyCursor || !historyToken) return;
    historyBusy = true;
    f("more").querySelector("button").disabled = true;
    try {
      const page = await request(`/api/v1/focus-records?${new URLSearchParams({ limit: "20", cursor: historyCursor, snapshot_token: historyToken })}`);
      if (!sameOwner(scope, epoch) || revision !== focusLoad) return;
      if (page.user_id !== scope || page.snapshot_token !== historyToken) throw new Error("无法核对列表快照。");
      serverHistory.push(...page.records);
      historyCursor = page.next_cursor;
    } catch (error) {
      if (!sameOwner(scope, epoch) || revision !== focusLoad) return;
      f("status").textContent = error.message;
      if (error.code === "FOCUS_SNAPSHOT_STALE") await loadFocus({ keepStatus: true });
    } finally {
      if (sameOwner(scope, epoch)) { historyBusy = false; paintHistory(scope, epoch); }
    }
  }

  async function loadFocus({ keepStatus = false } = {}) {
    const scope = userId();
    if (!scope) return;
    const epoch = ownerEpoch;
    const revision = ++focusLoad;
    const [active, history, planning] = await Promise.allSettled([
      request("/api/v1/focus-records/active"), request("/api/v1/focus-records?limit=20"), request("/api/v1/planning"),
    ]);
    if (!sameOwner(scope, epoch) || revision !== focusLoad) return;
    if (active.status === "fulfilled" && active.value.user_id === scope) {
      record = active.value.record;
      if (!sameSegment(live)) live = null;
    }
    if (history.status === "fulfilled" && history.value.user_id === scope) {
      serverHistory = history.value.records;
      historyCursor = history.value.next_cursor;
      historyToken = history.value.snapshot_token;
      paintHistory(scope, epoch);
    }
    if (planning.status === "fulfilled") updateTaskOptions(planning.value.tasks);
    if (!keepStatus) f("status").textContent = active.status === "rejected" || history.status === "rejected" ?
      "暂时无法读取服务器记录。仍可选择仅在本机记录。" : "";
    paintFocus();
  }

  function recordStart(payload, task, target) {
    Object.assign(payload, { task_id: task, target_ms: target ? target * 60000 : null });
  }

  function operateLocal(kind, current, reason) {
    if (!localReady) return;
    const queued = localRecords.reduce((total, item) => total + item.operations.length, 0);
    if ((kind === "start" && localRecords.length >= 20) || (["start", "resume"].includes(kind) && queued >= 98)) {
      throw new Error("本机记录已满。请先处理待同步记录。");
    }
    const clock = now();
    const payload = makePayload(kind, current, clock.wall);
    if (kind === "start") recordStart(payload, f("task").value, Number(f("target").value || 0));
    const active = current ?? { local: true, record_id: app.uuid(), current_device_id: device,
      task_id: payload.task_id, target_ms: payload.target_ms, started_at: payload.occurred_at,
      operations: [], confirmed_elapsed_ms: 0 };
    const newSegment = ["start", "resume"].includes(kind);
    const anchor = newSegment ? makeAnchor(active.record_id, payload) : null;
    if (!newSegment && sameSegment(localLive, active)) {
      const gap = reason || sample(localLive, clock);
      Object.assign(payload, closedFragments(localLive, gap, clock.wall));
    }
    const item = projectLocal(active, payload, anchor);
    saveLocal(current ? localRecords.map(record => current === record ? item : record) : [...localRecords, item]);
    localLive = anchor;
    if (kind === "end") completionTask = active.task_id;
    f("status").textContent = reason ? "计时已暂停，未核实的时长未计入。" : kind === "end" ? "本机记录已保存，可在恢复连接后同步。" : "";
  }

  const saveOnline = (scope, value) => localStorage.setItem(key("focus-operation", scope), JSON.stringify(value));
  const getReceipt = (payload) => request(`/api/v1/focus-operations/${payload.operation_id}`);
  const sendOperation = (recordId, payload) => post(`/api/v1/focus-records/${recordId}/operations`, payload);
  const isMissingOperation = (error) => error.status === 404 && error.code === "FOCUS_OPERATION_NOT_FOUND";
  const isDefinitive = (error) => error.status >= 400 && error.status < 500 && ![401, 403, 408, 429].includes(error.status);

  async function syncLocal(mode) {
    const scope = userId();
    const epoch = ownerEpoch;
    if (!scope || syncBusy || pending || !localReady || localActive()?.state === "running" || getSaved(key("focus-operation", scope))) return;
    syncBusy = true;
    paintFocus();
    try {
      while (sameOwner(scope, epoch)) {
        const item = localRecords.find(record => record.operations.length);
        const operation = item?.operations[0];
        if (!operation) break;
        const expected = { send: "queued", check: "unknown", retry: "not_found" }[mode];
        if (operation.dispatch !== expected) break;
        if (mode !== "check") {
          // If delivery is interrupted, the persisted original ID is query-only on next launch.
          saveLocal(localRecords.map(record => record === item ? { ...item,
            operations: [{ ...operation, dispatch: "unknown" }, ...item.operations.slice(1)] } : record));
        }
        try {
          const response = mode === "check" ? await getReceipt(operation.payload) : await sendOperation(item.record_id, operation.payload);
          if (!sameOwner(scope, epoch)) return;
          checkReceipt(response, scope, item.record_id, operation.payload);
          // The pending save replaces the in-memory record; use the latest copy for receipt application.
          const current = localRecords.find(record => record.record_id === item.record_id);
          const operations = current.operations.slice(1);
          saveLocal(localRecords.flatMap(record => record !== current ? [record] :
            !operations.length && record.state === "ended" ? [] : [{ ...record, operations }]));
          f("status").textContent = "已核对同步结果。";
        } catch (error) {
          if (!sameOwner(scope, epoch)) return;
          const current = localRecords.find(record => record.record_id === item.record_id);
          if ((mode === "check" && isMissingOperation(error)) || (mode !== "check" && isDefinitive(error))) {
            const dispatch = mode === "check" ? "not_found" : "conflict";
            saveLocal(localRecords.map(record => record === current ? { ...record,
              operations: [{ ...operation, dispatch, message: error.message }, ...record.operations.slice(1)] } : record));
            f("status").textContent = dispatch === "conflict" ? "同步有冲突，原记录保留在本机。" : "未找到回执。可重试原同步操作。";
          } else {
            f("status").textContent = "同步结果尚未核实。请恢复连接后核对。";
          }
          break;
        }
        if (mode !== "send") break;
      }
    } catch (error) {
      if (sameOwner(scope, epoch)) f("status").textContent = error.message;
    } finally {
      if (sameOwner(scope, epoch)) {
        syncBusy = false;
        paintFocus();
        await loadFocus({ keepStatus: true });
      }
    }
  }

  async function operate(kind, reason = null) {
    const scope = userId();
    const epoch = ownerEpoch;
    if (!scope || !device || pending || syncBusy) return;
    const active = displayedRecord();
    const task = f("task").value;
    const target = Number(f("target").value || 0);
    if (kind === "start" ? active && active.state !== "ended" : !active || active.state === "ended") return;
    if (kind === "resume" && active.state !== "paused") return;
    if (kind === "pause" && (active.state !== "running" || active.current_device_id !== device)) return;
    if (kind === "start" && (!task || !f("target").checkValidity())) {
      f("status").textContent = "请选择待办。目标时长可以留空，或填写 1–240 分钟。";
      return;
    }
    if (kind === "end" && !window.confirm("结束这次专注并保存已确认的计时？")) return;
    if (active?.local || (kind === "start" && f("mode").value === "offline")) {
      try { operateLocal(kind, kind === "start" ? null : active, reason); }
      catch (error) { f("status").textContent = error.message; }
      paintFocus();
      return;
    }
    if (getSaved(key("focus-operation", scope))) {
      f("status").textContent = "上一项操作尚未核实，请先核对保存结果。";
      return;
    }
    const recordId = kind === "start" ? app.uuid() : active.record_id;
    const clock = now();
    const payload = makePayload(kind, active, clock.wall);
    if (kind === "start") recordStart(payload, task, target);
    if (payload.segment_id) {
      const saved = getSaved(key("focus-segment", scope));
      if (sameSegment(live, active)) {
        const gap = reason || sample(live, clock);
        Object.assign(payload, closedFragments(live, gap, clock.wall));
      } else if (sameSegment(saved, active) && saved.intervalId) {
        Object.assign(payload, closedFragments(saved, "process_interrupted", clock.wall));
      } else {
        const at = saved?.segmentId === active.segment_id && saved.at ? saved.at : payload.occurred_at;
        payload.unknown_gaps = [{ gap_id: app.uuid(), segment_id: payload.segment_id,
          reason: "process_interrupted", observed_start_at: at, observed_end_at: payload.occurred_at }];
      }
    }
    await submitOnline(scope, epoch, { recordId, payload }, true);
  }

  async function submitOnline(scope, epoch, cached, send) {
    const { recordId, payload } = cached;
    const taskId = record?.record_id === recordId ? record.task_id : null;
    pending = true;
    ++focusLoad;
    paintFocus();
    try {
      if (send) saveOnline(scope, { ...cached, dispatch: "unknown" });
      const response = send ? await sendOperation(recordId, payload) : await getReceipt(payload);
      if (!sameOwner(scope, epoch)) return;
      checkReceipt(response, scope, recordId, payload);
      if (["start", "resume"].includes(payload.kind)) {
        // A receipt alone does not prove another device has not already ended the record.
        const current = await request("/api/v1/focus-records/active");
        if (!sameOwner(scope, epoch)) return;
        if (current.user_id !== scope) throw new Error("无法核对当前专注记录。");
        record = current.record;
        if (!document.hidden && record?.record_id === recordId && record.revision === response.receipt.after_revision &&
            record.state === "running" && record.current_device_id === device && record.segment_id === payload.operation_id &&
            record.clock_session_id === payload.clock_session_id) {
          const newAnchor = makeAnchor(recordId, payload);
          localStorage.setItem(key("focus-segment", scope), JSON.stringify(checkpoint(newAnchor)));
          live = newAnchor;
        }
      } else {
        live = null;
        localStorage.removeItem(key("focus-segment", scope));
        if (record?.record_id === recordId) {
          record = { ...record, state: response.receipt.after_state, revision: response.receipt.after_revision,
            confirmed_elapsed_ms: record.confirmed_elapsed_ms + response.receipt.added_elapsed_ms };
        }
      }
      localStorage.removeItem(key("focus-operation", scope));
      if (payload.kind === "end") completionTask = taskId;
      f("status").textContent = payload.kind === "end" ? "已保存，可在回顾中查看。" : payload.kind === "delete" ? "已删除专注记录。" : "";
    } catch (error) {
      if (!sameOwner(scope, epoch)) return;
      if (!send && isMissingOperation(error)) saveOnline(scope, { ...cached, dispatch: "not_found" });
      if (send && isDefinitive(error)) localStorage.removeItem(key("focus-operation", scope));
      f("status").textContent = !send && isMissingOperation(error) ? "未找到回执。可重试原联网操作。" : error.message;
    } finally {
      if (sameOwner(scope, epoch)) {
        pending = false;
        paintFocus();
        await loadFocus({ keepStatus: true });
      }
    }
  }

  async function checkFocus(retry = false) {
    const scope = userId();
    if (!scope || pending || syncBusy || localActive()?.state === "running") return;
    const cached = getSaved(key("focus-operation", scope));
    if (cached && (!retry || cached.dispatch === "not_found")) {
      await submitOnline(scope, ownerEpoch, cached, retry);
      return;
    }
    await loadFocus();
  }

  async function loadReview() {
    const scope = userId();
    if (!scope || !reviewDate) return;
    const epoch = ownerEpoch;
    const sequence = ++reviewLoad;
    r("status").textContent = "正在读取统计…";
    r("totals").replaceChildren();
    r("details").replaceChildren();
    r("window").textContent = "";
    r("note").value = getSaved(key(`review-${reviewPeriod}-${reviewDate}`, scope)) ?? "";
    try {
      const stats = await request(`/api/v1/reviews?${new URLSearchParams({ period: reviewPeriod, anchor: reviewDate })}`);
      if (!sameOwner(scope, epoch) || sequence !== reviewLoad) return;
      const items = [["已确认专注", duration(stats.totals.confirmed_elapsed_ms)],
        ["期间完成", `${stats.totals.current_completed_count} 项`], ["当前待安排", `${stats.totals.current_unscheduled_count} 项`]];
      r("totals").replaceChildren(...items.map(([label, value]) => {
        const node = document.createElement("div");
        node.className = "wf-stat";
        const title = document.createElement("span");
        const number = document.createElement("strong");
        title.textContent = label;
        number.textContent = value;
        node.append(title, number);
        return node;
      }));
      r("window").textContent = `${when(stats.period_start)} 至 ${when(stats.period_end)} · 北京时间`;
      const rows = [...stats.completed_tasks.map(item => row(item.title, "已完成")),
        ...stats.focus_intervals.map(item => row(item.task_title ?? "专注记录", duration(item.allocated_elapsed_ms))),
        ...stats.unscheduled_tasks.map(item => row(item.title, "待安排"))];
      if (stats.totals.unknown_gap_count) rows.push(row("未确认的计时片段", `${stats.totals.unknown_gap_count} 段未计入统计`));
      if (!rows.length) rows.push(row("这段时间暂无统计记录", "可调整日期范围。"));
      r("details").replaceChildren(...rows);
      r("status").textContent = "";
    } catch (error) { if (sameOwner(scope, epoch) && sequence === reviewLoad) r("status").textContent = error.message; }
  }

  function sampleFocus() {
    if (!userId() || pending || syncBusy) return;
    const active = displayedRecord();
    const anchor = active?.local ? localLive : live;
    if (!sameSegment(anchor, active)) return;
    const clock = now();
    const reason = sample(anchor, clock);
    if (reason || document.hidden) {
      void operate("pause", reason);
      return;
    }
    if (clock.mono - anchor.checkpoint >= 5000) {
      try {
        if (active.local) saveLocal(localRecords.map(item => item === active ? { ...item, anchor: checkpoint(anchor) } : item));
        else localStorage.setItem(key("focus-segment"), JSON.stringify(checkpoint(anchor)));
        anchor.checkpoint = clock.mono;
      } catch {
        void operate("pause", "storage_failed");
      }
    }
    if (tab === "focus") paintTimer();
  }

  f("refresh").append(button("刷新与核对", () => checkFocus()));
  f("start-action").append(button("开始专注", () => operate("start"), true));
  f("more").append(button("加载更多记录", loadMoreHistory));
  const complete = button("标记任务完成", async () => {
    const scope = userId();
    const epoch = ownerEpoch;
    const task = completionTask;
    if (!scope || !task || complete.disabled) return;
    complete.disabled = true;
    try { await app.completeFocusTask(task, complete); }
    finally { if (sameOwner(scope, epoch)) complete.disabled = false; }
  });
  f("completion-action").append(complete);
  f("mode").addEventListener("change", () => {
    f("mode-help").hidden = f("mode").value !== "offline";
    paintFocus();
  });
  f("task").addEventListener("change", () => { selectedTask = null; });
  r("refresh").append(button("刷新", loadReview));
  r("period").addEventListener("change", () => { reviewPeriod = r("period").value; void loadReview(); });
  r("date").value = reviewDate;
  r("date").addEventListener("change", () => { reviewDate = r("date").value; void loadReview(); });
  r("save").append(button("保存笔记", () => {
    if (!userId() || !reviewDate) return;
    localStorage.setItem(key(`review-${reviewPeriod}-${reviewDate}`), JSON.stringify(r("note").value));
    app.toast("笔记已保存到这台电脑。");
  }, true));
  document.addEventListener("campusflow:desktop-view", (event) => {
    tab = event.detail.tab;
    if (owner !== event.detail.userId) {
      owner = event.detail.userId;
      ++ownerEpoch;
      ++reviewLoad;
      ++focusLoad;
      record = null;
      live = null;
      localLive = null;
      localRecords = [];
      localReady = false;
      localStorageError = "";
      selectedTask = null;
      taskOptions = [];
      serverHistory = [];
      historyCursor = null;
      historyToken = null;
      historyBusy = false;
      completionTask = null;
      complete.disabled = false;
      pending = false;
      syncBusy = false;
      f("list").replaceChildren();
      f("task").replaceChildren();
      f("mode").value = "online";
      f("mode-help").hidden = true;
      f("target").value = "";
      f("status").textContent = "";
      r("note").value = "";
    }
    if (tab === "focus") {
      const savedStatus = f("status").textContent;
      recoverLocal();
      const preloaded = app.focusTasks?.();
      if (preloaded?.length || !taskOptions.length || selectedTask) updateTaskOptions(preloaded?.length ? preloaded :
        taskOptions.map(item => ({ ...item, status: "pending" })));
      paintFocus();
      if (getSaved(key("focus-operation"))) void checkFocus();
      else void loadFocus({ keepStatus: f("status").textContent !== savedStatus });
    }
    if (tab === "review") void loadReview();
  });
  setInterval(sampleFocus, 1000);
  document.addEventListener("visibilitychange", () => {
    if (!document.hidden) return;
    const active = displayedRecord();
    if (active?.state === "running" && sameSegment(active.local ? localLive : live, active)) void operate("pause");
  });
})();
