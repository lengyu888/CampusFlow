(() => {
  const app = window.CampusFlowWindows;
  const root = document.getElementById("windowsPlanningRoot");
  if (!app || !root) return;

  const heading = document.createElement("h2");
  heading.textContent = "安排与冲突";
  const toolbar = document.createElement("div");
  toolbar.className = "wf-controls";
  const feedback = document.createElement("p");
  feedback.className = "wf-status";
  feedback.setAttribute("role", "status");
  const conflicts = document.createElement("div");
  conflicts.className = "wf-list";
  const editor = document.createElement("div");
  const items = document.createElement("div");
  items.className = "wf-list";
  root.classList.add("wf-card");
  root.append(heading, toolbar, feedback, conflicts, editor, items);

  const timeFormat = new Intl.DateTimeFormat("zh-CN", { dateStyle: "medium", timeStyle: "short", timeZone: "Asia/Shanghai" });
  const time = (value) => value ? timeFormat.format(new Date(value)) : "未定";
  const pathFor = (id) => `/api/v1/actions/${encodeURIComponent(id)}`;
  const replanPath = (id) => `/api/v1/planning/replans/${encodeURIComponent(id)}`;
  const post = (path, value = {}) => app.api(path, {
    method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(value),
  });
  const inputTime = (value) => value ? new Date(Date.parse(value) + 8 * 3600000).toISOString().slice(0, 16) : "";
  const isoTime = (value) => value ? `${value}:00+08:00` : null;
  let owner = null;
  let tab = "";
  let activePreview = null;
  let busy = false;
  let viewRevision = 0;
  let readRevision = 0;

  function element(tag, value = "", className = "") {
    const node = document.createElement(tag);
    node.textContent = value;
    if (className) node.className = className;
    return node;
  }

  function button(title, action, primary = false) {
    const node = element("button", title, `wf-button${primary ? " primary" : ""}`);
    node.type = "button";
    node.addEventListener("click", action);
    return node;
  }

  const reminderStatus = element("p", "", "wf-status");
  reminderStatus.setAttribute("role", "status");
  const reminderToggle = button("后台提醒", toggleBackgroundReminders);
  reminderToggle.hidden = !app.reminders;

  function showReminderPreference() {
    if (!app.reminders) return;
    const enabled = app.reminders.enabled();
    reminderToggle.setAttribute("aria-pressed", String(enabled));
    reminderToggle.textContent = enabled ? "后台提醒已开启" : "开启后台提醒";
  }

  async function toggleBackgroundReminders() {
    const user = owner;
    const revision = viewRevision;
    const enabled = !app.reminders.enabled();
    reminderToggle.disabled = true;
    reminderStatus.textContent = "";
    try {
      const saved = await app.reminders.set(enabled);
      if (live(revision, user)) reminderStatus.textContent = saved
        ? enabled ? "关闭窗口后在 Windows 通知区域继续提醒。" : "后台提醒已关闭。"
        : "暂时无法更新后台提醒，请重试。";
    } catch (error) {
      if (live(revision, user)) reminderStatus.textContent = error.message;
    } finally {
      reminderToggle.disabled = false;
      showReminderPreference();
    }
  }

  function field(form, name, label, value, options = {}) {
    const block = element("label", label);
    const input = element("input", "", "wf-input");
    input.name = name;
    input.type = options.type ?? "text";
    if (input.type === "checkbox") input.checked = value;
    else input.value = value ?? "";
    if (options.maxLength) input.maxLength = options.maxLength;
    if (options.required) input.required = true;
    if (options.min !== undefined) input.min = options.min;
    if (options.max !== undefined) input.max = options.max;
    block.append(input);
    form.append(block);
    return input;
  }

  function live(revision, user = owner) {
    return user && app.user()?.user_id === user && tab === "plans" && revision === viewRevision;
  }

  function clearEditor() {
    activePreview = null;
    feedback.textContent = "";
    editor.replaceChildren();
  }

  function extractTaskTime(text, now = Date.now()) {
    const times = [...text.matchAll(/(?<!\d)([01]?\d|2[0-3]):([0-5]\d)(?!\d)/g)];
    const dates = [...text.matchAll(/\b\d{4}-\d{2}-\d{2}\b|今天|明天|后天/g)];
    const lengths = [...text.matchAll(/([1-9]\d{0,3})\s*(分钟|小时)/g)];
    if (times.length !== 1 || dates.length !== 1 || lengths.length !== 1) return null;
    const offset = ["今天", "明天", "后天"].indexOf(dates[0][0]);
    const date = offset < 0 ? dates[0][0] : shanghai.format(now + offset * 86400000);
    const time = `${times[0][1].padStart(2, "0")}:${times[0][2]}`;
    const start = Date.parse(`${date}T${time}:00+08:00`);
    const minutes = Number(lengths[0][1]) * (lengths[0][2] === "小时" ? 60 : 1);
    if (!Number.isFinite(start) || shanghai.format(start) !== date || minutes > 1440) return null;
    return [inputTime(new Date(start).toISOString()), inputTime(new Date(start + minutes * 60000).toISOString())];
  }

  function row(label, detail, controls = []) {
    const container = element("div", "", "wf-row");
    const copy = element("div");
    const actions = element("div", "", "wf-controls");
    copy.append(element("strong", label), element("small", detail));
    actions.append(...controls);
    container.append(copy, actions);
    return container;
  }

  function showForm(item, kind) {
    if (busy) return;
    clearEditor();
    const form = element("form", "", "wf-controls");
    const title = field(form, "title", "标题", item?.title, { required: true, maxLength: 120 });
    if (kind === "task") {
      const start = field(form, "start", "开始（北京时间）", inputTime(item?.start_at), { type: "datetime-local" });
      const end = field(form, "end", "结束（北京时间）", inputTime(item?.end_at), { type: "datetime-local" });
      if (!item?.task_id) {
        const extract = button("从标题提取时间", () => {
          const times = extractTaskTime(title.value);
          if (!times) { feedback.textContent = "请写明日期、24 小时时刻和时长，例如「明天 20:00 复习 60 分钟」。"; return; }
          [start.value, end.value] = times;
          feedback.textContent = "已填入开始与结束时间，请核对。";
        });
        form.append(extract);
      }
      field(form, "location", "地点", item?.location, { maxLength: 120 });
      field(form, "reminder", "提前提醒（分钟）", item?.reminder_minutes, { type: "number", min: 0, max: 10080 });
      field(form, "during", "允许在课内安排", Boolean(item?.allow_during_course), { type: "checkbox" });
    } else {
      field(form, "summary", "计划说明", item.summary, { maxLength: 500 });
      field(form, "target", "目标日期", item.target_date, { type: "date" });
    }
    const submit = element("button", "生成预览", "wf-button primary");
    submit.type = "submit";
    form.append(submit, button("取消编辑", clearEditor));
    form.addEventListener("submit", (event) => {
      event.preventDefault();
      const values = new FormData(form);
      const taskTitle = title.value.trim();
      if (!taskTitle) { feedback.textContent = "请输入标题。"; return; }
      let request;
      if (kind === "task") {
        const task = { title: taskTitle, start_at: isoTime(values.get("start")), end_at: isoTime(values.get("end")),
          reminder_minutes: values.get("reminder") === "" ? null : Number(values.get("reminder")),
          location: String(values.get("location")).trim() || null, allow_during_course: values.has("during") };
        request = item?.task_id ? { operation: "update_task", task_id: item.task_id, task } : { operation: "create_task", task };
      } else request = { operation: "update_plan", plan_id: item.plan_id,
        plan: { title: taskTitle, summary: String(values.get("summary")).trim(), target_date: values.get("target") || null } };
      void preview(request, item);
    });
    editor.append(element("h3", item?.task_id || item?.plan_id ? `编辑${kind === "task" ? "待办" : "计划"}` : "添加待办"), form);
    title.focus();
  }

  async function preview(request, first) {
    if (busy) return;
    const revision = viewRevision;
    const user = owner;
    busy = true;
    feedback.textContent = "正在生成预览…";
    try {
      const result = await post("/api/v1/planning/actions", request);
      if (!live(revision, user)) return;
      if (first?.task_version != null && result.before_task?.task_version !== first.task_version) {
        feedback.textContent = "待办已在别处修改。请刷新后重新编辑。";
        return;
      }
      if (first?.plan_id && !first.task_id && ["title", "summary", "target_date"].some((name) => result.before_plan?.[name] !== first[name])) {
        feedback.textContent = "计划已在别处修改。请刷新后重新编辑。";
        return;
      }
      activePreview = { type: "action", result };
      feedback.textContent = "";
      paintPreview();
    } catch (error) { if (live(revision, user)) feedback.textContent = error.message; }
    finally { busy = false; }
  }

  async function previewReplan() {
    if (busy) return;
    const revision = viewRevision;
    const user = owner;
    busy = true;
    feedback.textContent = "正在寻找可用时间…";
    try {
      const result = await post("/api/v1/planning/replans");
      if (!live(revision, user)) return;
      activePreview = { type: "replan", result };
      feedback.textContent = "";
      paintPreview();
    } catch (error) { if (live(revision, user)) feedback.textContent = error.message; }
    finally { busy = false; }
  }

  function paintPreview() {
    const { type, result } = activePreview;
    const courseReviews = type === "action" ? result.course_reviews ?? [] : [];
    const acks = [];
    const panel = element("section", "", "wf-card");
    const group = element("div", "", "wf-controls");
    let blocked = result.status !== "pending";
    panel.append(element("h3", type === "replan" ? "改期预览" : `${{ create: "新建", update: "修改", delete: "删除" }[result.action]}预览`));
    if (type === "replan") {
      for (const change of result.changes) panel.append(row(change.title,
        `${time(change.old_start_at)} – ${time(change.old_end_at)} → ${time(change.new_start_at)} – ${time(change.new_end_at)}`));
      for (const item of result.unresolved) panel.append(row(item.title, item.reason));
      blocked ||= !result.changes.length;
      if (!result.changes.length) panel.append(element("p", "没有可确认的改期方案。"));
    } else {
      const after = result.payload?.task ?? result.payload?.plan;
      const before = result.before_task ?? result.before_plan;
      if (before) panel.append(row(`原安排：${before.title}`, before.task_id ? `${time(before.start_at)} – ${time(before.end_at)}` : before.summary));
      if (after) panel.append(row(result.title, after.title && "start_at" in after ?
        [`${time(after.start_at)} – ${time(after.end_at)}`, after.location, after.reminder_minutes != null && `提前 ${after.reminder_minutes} 分钟提醒`].filter(Boolean).join(" · ") :
        [after.summary, after.target_date].filter(Boolean).join(" · ")));
      if (result.action === "delete") panel.append(element("p", result.kind === "plan" ? "确认后删除这项计划，关联任务会保留为独立待办。" : "确认后删除该待办。"));
      for (const message of [...(result.warnings ?? []), ...(result.conflicts ?? [])]) panel.append(element("p", message));
      blocked ||= result.contract_version < 2 || Boolean(result.conflicts?.length) || courseReviews.some((review) => review.state === "blocked");
      for (const review of courseReviews) {
        for (const overlap of review.overlaps ?? []) panel.append(row(overlap.course.title,
          `${overlap.course.date} ${overlap.course.start_time}–${overlap.course.end_time}`));
        if (review.requires_acknowledgement) {
          const checkbox = field(panel, `ack-${review.candidate_id}`, "接受这次课内安排", false, { type: "checkbox" });
          acks.push({ checkbox, candidate_id: review.candidate_id, review_digest: review.review_digest });
        }
      }
    }
    const confirm = button("确认保存", () => void confirmPreview(acks), true);
    const sync = () => { confirm.disabled = blocked || acks.some(({ checkbox }) => !checkbox.checked); };
    for (const { checkbox } of acks) checkbox.addEventListener("change", sync);
    sync();
    group.append(confirm, button("核对保存结果", () => void refreshPreview()), button("关闭预览", clearEditor));
    panel.append(group);
    editor.replaceChildren(panel);
  }

  async function refreshPreview() {
    if (!activePreview || busy) return;
    const snapshot = activePreview;
    const revision = viewRevision;
    const user = owner;
    busy = true;
    try {
      const status = await app.api(snapshot.type === "action" ? pathFor(snapshot.result.proposal_id) : replanPath(snapshot.result.replan_id));
      if (!live(revision, user) || activePreview !== snapshot) return;
      activePreview = { type: snapshot.type, result: status };
      paintPreview();
      feedback.textContent = status.status === "confirmed" ? "已确认保存。" : status.status === "pending" ? "当前仍待确认。" : "当前预览已关闭，请重新生成。";
      if (status.status === "confirmed") app.open("plans");
    } catch (error) { if (live(revision, user)) feedback.textContent = error.message; }
    finally { busy = false; }
  }

  async function confirmPreview(acks) {
    const snapshot = activePreview;
    if (busy || snapshot?.result.status !== "pending" || acks.some(({ checkbox }) => !checkbox.checked)) return;
    const revision = viewRevision;
    const user = owner;
    busy = true;
    const { type, result } = snapshot;
    const route = type === "action" ? pathFor(result.proposal_id) : replanPath(result.replan_id);
    try {
      const body = type === "action" ? { course_acknowledgements: acks.map(({ candidate_id, review_digest }) => ({ candidate_id, review_digest })) } : {};
      const response = await post(`${route}/confirm`, body);
      if (!live(revision, user) || activePreview !== snapshot) return;
      if (type === "action" ? response.action?.status !== "confirmed" || !response.receipt : response.status !== "confirmed") {
        feedback.textContent = "尚未取得保存结果，请点击核对保存结果。";
        return;
      }
      clearEditor();
      app.toast(type === "action" ? "安排已保存。" : "改期已保存。");
      app.open("plans");
    } catch (error) {
      if (live(revision, user) && activePreview === snapshot) {
        feedback.textContent = `${error.message} 可先核对保存结果。`;
        editor.querySelector("button.primary").disabled = true;
      }
    } finally { busy = false; }
  }

  function paintConflicts(result) {
    const rows = [];
    for (const item of result.conflicts ?? []) rows.push(row(item.title, `课程冲突 · ${item.courses.map(course => course.title).join("、")}`));
    for (const item of result.course_overlap_reviews ?? []) rows.push(row(item.title, `待校对课内安排 · ${item.courses.map(course => course.title).join("、")}`));
    for (const item of result.unchecked ?? []) rows.push(row(item.title, item.reason));
    if (result.accepted_course_overlaps?.length) rows.push(element("p", `${result.accepted_course_overlaps.length} 项已确认课内安排。`));
    conflicts.replaceChildren(...(rows.length ? rows : [element("p", "暂无待处理的课程冲突。")]));
  }

  function paintItems(result) {
    const plans = result.plans ?? [];
    const tasks = result.tasks ?? [];
    const rows = [];
    for (const item of tasks) rows.push(row(item.title, item.start_at ? `${time(item.start_at)} · ${item.status === "completed" ? "已完成" : "未完成"}` : "未定时间", [
      button("编辑待办", () => showForm(item, "task")), button("删除待办", () => void preview({ operation: "delete_task", task_id: item.task_id }, item)),
    ]));
    for (const item of plans) rows.push(row(item.title, item.target_date ?? "目标计划", [
      button("编辑计划", () => showForm(item, "plan")), button("删除计划", () => void preview({ operation: "delete_plan", plan_id: item.plan_id }, item)),
    ]));
    const summary = element("summary", "编辑待办和目标计划");
    const list = element("details", "", "wf-details");
    if (items.firstElementChild?.open) list.open = true;
    list.append(summary, ...(rows.length ? rows : [element("p", "暂无待办或目标计划。")]));
    items.replaceChildren(list);
  }

  async function refresh() {
    const revision = viewRevision;
    const user = owner;
    const read = ++readRevision;
    if (!user || tab !== "plans") return;
    const requests = await Promise.allSettled([app.api("/api/v1/planning/conflicts"), app.api("/api/v1/planning")]);
    if (!live(revision, user) || read !== readRevision) return;
    if (requests[0].status === "fulfilled") paintConflicts(requests[0].value);
    else conflicts.replaceChildren(element("p", requests[0].reason.message));
    if (requests[1].status === "fulfilled") paintItems(requests[1].value);
    else items.replaceChildren(element("p", requests[1].reason.message));
  }

  toolbar.append(button("预览自动改期", previewReplan), button("刷新", refresh), reminderToggle);
  document.getElementById("windowsPlanAdd").addEventListener("click", () => showForm(null, "task"));
  app.newTaskDraft = (task) => {
    app.open("plans");
    showForm(task, "task");
  };
  toolbar.after(reminderStatus);
  document.addEventListener("campusflow:desktop-view", (event) => {
    const current = event.detail.userId;
    if (current !== owner || event.detail.tab !== tab) {
      viewRevision++;
      clearEditor();
    }
    if (current !== owner) { items.replaceChildren(); conflicts.replaceChildren(); reminderStatus.textContent = ""; }
    owner = current;
    tab = event.detail.tab;
    if (tab === "plans") { showReminderPreference(); void refresh(); }
  });

  const study = document.getElementById("windowsStudyWindow");
  const studyStatus = document.getElementById("windowsStudyStatus");
  const capture = document.getElementById("windowsStudyCapture");
  const buffer = document.getElementById("windowsStudyBuffer");
  const shanghai = new Intl.DateTimeFormat("sv-SE", { timeZone: "Asia/Shanghai" });
  let gapRead = 0;

  async function findStudyWindow(create = false) {
    const check = ++gapRead;
    const user = app.user()?.user_id;
    capture.disabled = true;
    if (!study.open || !user || tab !== "today") return;
    studyStatus.textContent = "正在核对课表和待办…";
    try {
      const [schedule, planning] = await Promise.all([
        app.api("/api/v1/me/timetable", { cache: "no-store" }), app.api("/api/v1/planning", { cache: "no-store" }),
      ]);
      if (check !== gapRead || user !== app.user()?.user_id || tab !== "today" || !study.open) return;
      if (!Array.isArray(schedule.entries) || !Array.isArray(planning.tasks)) throw new Error("课表和待办尚未完整核对。");
      const now = Date.now();
      if (!schedule.evidence?.some(source => source.status === "fresh" && Date.parse(source.updated_at) <= now &&
        (source.expires_at == null || Date.parse(source.expires_at) > now))) {
        throw new Error("请先更新课表，再查找空档。");
      }
      const today = shanghai.format(now);
      const dayStart = Date.parse(`${today}T00:00:00+08:00`);
      const dayEnd = dayStart + 86400000;
      const occupied = schedule.entries.filter(course => course.date === today).map(course => [
        Date.parse(`${today}T${course.start_time}:00+08:00`), Date.parse(`${today}T${course.end_time}:00+08:00`),
      ]);
      let untimed = 0;
      for (const task of planning.tasks.filter(item => item.status === "pending")) {
        if (!task.start_at || /^\d{4}-\d{2}-\d{2}$/.test(task.start_at)) {
          if (!task.start_at || task.start_at === today) untimed += 1;
          continue;
        }
        const start = Date.parse(task.start_at);
        if (start >= dayEnd) continue;
        const end = task.end_at ? Date.parse(task.end_at) : NaN;
        if (end > dayStart || !Number.isFinite(end)) occupied.push([start, end]);
      }
      if (occupied.some(([start, end]) => !Number.isFinite(start) || !Number.isFinite(end) || end <= start)) {
        throw new Error("有课程或待办缺少有效起止时间，请先核对安排。");
      }
      const reserve = Number(buffer.value) * 60000;
      const duration = 25 * 60000;
      let start = Math.ceil(now / 60000) * 60000;
      let end = dayEnd;
      for (const [busyStart, busyEnd] of occupied.sort((left, right) => left[0] - right[0])) {
        end = Math.min(dayEnd, busyStart - reserve);
        if (end - start >= duration) break;
        start = Math.max(start, busyEnd + reserve);
        end = dayEnd;
      }
      if (end - start < duration) { studyStatus.textContent = "今天没有足够的 25 分钟空档。"; return; }
      const shanghaiTime = (at) => inputTime(new Date(at).toISOString()).slice(11);
      studyStatus.textContent = `今日 ${shanghaiTime(start)}–${end === dayEnd ? "24:00" : shanghaiTime(end)}。${untimed ? `另有 ${untimed} 项未定时待办未纳入计算。` : ""}`;
      capture.disabled = false;
      if (create) app.newTaskDraft({ title: "复习", start_at: new Date(start).toISOString(), end_at: new Date(start + duration).toISOString() });
    } catch (error) {
      if (check === gapRead && user === app.user()?.user_id && tab === "today") studyStatus.textContent = error.message || "暂时无法核对。";
    }
  }

  study.addEventListener("toggle", () => void findStudyWindow());
  buffer.addEventListener("change", () => void findStudyWindow());
  capture.addEventListener("click", () => void findStudyWindow(true));
  document.addEventListener("campusflow:desktop-view", () => void findStudyWindow());
})();
