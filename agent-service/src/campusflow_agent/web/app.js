const $ = (selector) => document.querySelector(selector);
const $$ = (selector) => document.querySelectorAll(selector);

const elements = {
  authView: $("#authView"),
  onboardingView: $("#onboardingView"),
  appView: $("#appView"),
  settingsView: $("#settingsView"),
  authTitle: $("#authTitle"),
  authSubtitle: $("#authSubtitle"),
  loginForm: $("#loginForm"),
  registerForm: $("#registerForm"),
  setupProgress: $("#setupProgress"),
  setupKeyHint: $("#setupKeyHint"),
  schoolInput: $("#schoolInput"),
  campusInput: $("#campusInput"),
  semesterInput: $("#semesterInput"),
  timetableFile: $("#timetableFile"),
  timetablePreview: $("#timetablePreview"),
  parseTimetableButton: $("#parseTimetableButton"),
  timetableStatus: $("#timetableStatus"),
  timetableReview: $("#timetableReview"),
  timetableSummary: $("#timetableSummary"),
  timetableTable: $("#timetableTable"),
  mapFile: $("#mapFile"),
  mapPreview: $("#mapPreview"),
  parseMapButton: $("#parseMapButton"),
  mapStatus: $("#mapStatus"),
  mapReview: $("#mapReview"),
  campusMapName: $("#campusMapName"),
  placeCount: $("#placeCount"),
  placeCloud: $("#placeCloud"),
  setupBackButton: $("#setupBackButton"),
  setupNextButton: $("#setupNextButton"),
  setupLogoutButton: $("#setupLogoutButton"),
  credentialCard: $("#credentialCard"),
  credentialHint: $("#credentialHint"),
  sessionId: $("#sessionId"),
  newSessionButton: $("#newSessionButton"),
  modelBadge: $("#modelBadge"),
  messages: $("#messages"),
  emptyState: $("#emptyState"),
  composer: $("#composer"),
  messageInput: $("#messageInput"),
  sendButton: $("#sendButton"),
  traceList: $("#traceList"),
  systemState: $("#systemState"),
  userInitial: $("#userInitial"),
  userName: $("#userName"),
  contextLine: $("#contextLine"),
  logoutButton: $("#logoutButton"),
  userChip: $("#userChip"),
  historyButton: $("#historyButton"),
  agentHistoryButton: $("#agentHistoryButton"),
  historyDrawer: $("#historyDrawer"),
  historyCloseButton: $("#historyCloseButton"),
  drawerScrim: $("#drawerScrim"),
  historySearch: $("#historySearch"),
  historyList: $("#historyList"),
  todayGreeting: $("#todayGreeting"),
  todayDate: $("#todayDate"),
  todayCourseCount: $("#todayCourseCount"),
  todayCourseList: $("#todayCourseList"),
  nextCourseTitle: $("#nextCourseTitle"),
  nextCourseMeta: $("#nextCourseMeta"),
  todayPlaceCount: $("#todayPlaceCount"),
  todayHistoryCount: $("#todayHistoryCount"),
  todaySuggestion: $("#todaySuggestion"),
  planList: $("#planList"),
  planGoals: $("#planGoals"),
  planProgress: $("#planProgress"),
  planProgressBar: $("#planProgressBar"),
  planTaskCount: $("#planTaskCount"),
  planDueToday: $("#planDueToday"),
  planCompleted: $("#planCompleted"),
  quickTaskForm: $("#quickTaskForm"),
  quickTaskTitle: $("#quickTaskTitle"),
  quickTaskTime: $("#quickTaskTime"),
  quickTaskReminder: $("#quickTaskReminder"),
  settingsBackButton: $("#settingsBackButton"),
  settingsInitial: $("#settingsInitial"),
  settingsName: $("#settingsName"),
  settingsEmail: $("#settingsEmail"),
  settingsForm: $("#settingsForm"),
  settingsDisplayName: $("#settingsDisplayName"),
  settingsEmailInput: $("#settingsEmailInput"),
  settingsSchool: $("#settingsSchool"),
  settingsCampus: $("#settingsCampus"),
  settingsSemester: $("#settingsSemester"),
  settingsApiKey: $("#settingsApiKey"),
  settingsKeyState: $("#settingsKeyState"),
  adminTabButton: $("#adminTabButton"),
  settingsCourseCount: $("#settingsCourseCount"),
  settingsPlaceCount: $("#settingsPlaceCount"),
  settingsSemesterCard: $("#settingsSemesterCard"),
  settingsCourseList: $("#settingsCourseList"),
  settingsPlaceList: $("#settingsPlaceList"),
  editOnboardingButton: $("#editOnboardingButton"),
  adminUserCount: $("#adminUserCount"),
  adminUserRows: $("#adminUserRows"),
  toast: $("#toast"),
};

const state = {
  user: null,
  setupStep: 1,
  timetableImage: "",
  mapImage: "",
  timetable: null,
  campusMap: null,
  sessionId: createSessionId(),
  sending: false,
  hasTraces: false,
  settingsContext: null,
  appTab: "today",
  sessions: [],
  planning: null,
  taskFilter: "all",
};

function createSessionId() {
  const id = globalThis.crypto?.randomUUID?.() ?? `${Date.now()}-${Math.random()}`;
  return `web-${id}`;
}

async function responseError(response) {
  try {
    const payload = await response.json();
    if (Array.isArray(payload.detail)) {
      return payload.detail.map((item) => item.msg).join("；");
    }
    if (payload.detail && typeof payload.detail === "object") {
      const conflicts = payload.detail.conflicts?.join("；");
      return conflicts || payload.detail.message || `请求失败（${response.status}）`;
    }
    return payload.detail || `请求失败（${response.status}）`;
  } catch {
    return `请求失败（${response.status}）`;
  }
}

async function api(path, options = {}) {
  const response = await fetch(path, options);
  if (!response.ok) throw new Error(await responseError(response));
  if (response.status === 204) return null;
  return response.json();
}

function showToast(message, kind = "info") {
  elements.toast.textContent = message;
  elements.toast.classList.toggle("error", kind === "error");
  elements.toast.classList.add("show");
  clearTimeout(showToast.timer);
  showToast.timer = setTimeout(() => elements.toast.classList.remove("show"), 3000);
}

function showOnly(view) {
  elements.authView.hidden = view !== "auth";
  elements.onboardingView.hidden = view !== "onboarding";
  elements.appView.hidden = view !== "app";
  elements.settingsView.hidden = view !== "settings";
  document.body.style.overflow = ["app", "settings"].includes(view) ? "hidden" : "auto";
}

function setButtonBusy(button, busy, label) {
  button.disabled = busy;
  const span = button.querySelector(".action-label") ?? button.querySelector("span");
  if (span) {
    if (!button.dataset.originalLabel) button.dataset.originalLabel = span.textContent;
    span.textContent = busy ? label : button.dataset.originalLabel;
  }
}

function switchAuth(mode) {
  const register = mode === "register";
  elements.loginForm.hidden = register;
  elements.registerForm.hidden = !register;
  elements.authTitle.textContent = register ? "创建你的校园空间" : "登录你的校园空间";
  elements.authSubtitle.textContent = register
    ? "三步连接学校、课表和校园地图。"
    : "继续使用你的课表、校区信息和 Agent 记忆。";
  $$('[data-auth-tab]').forEach((button) => {
    button.classList.toggle("active", button.dataset.authTab === mode);
  });
}

async function submitAuth(form, endpoint) {
  const button = form.querySelector("button[type='submit']");
  const body = Object.fromEntries(new FormData(form));
  setButtonBusy(button, true, "正在建立连接…");
  try {
    const payload = await api(endpoint, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    state.user = payload.user;
    if (state.user.onboarding_complete) showApp();
    else showOnboarding();
  } catch (error) {
    showToast(error.message, "error");
  } finally {
    setButtonBusy(button, false, "");
  }
}

async function logout() {
  try {
    await api("/api/v1/auth/logout", { method: "POST" });
  } catch {
    // The local UI should still clear its volatile state if the session already expired.
  }
  state.user = null;
  state.timetable = null;
  state.campusMap = null;
  state.timetableImage = "";
  state.mapImage = "";
  elements.settingsApiKey.value = "";
  resetSession(false);
  state.appTab = "today";
  elements.loginForm.reset();
  elements.registerForm.reset();
  switchAuth("login");
  showOnly("auth");
}

function showOnboarding() {
  state.setupStep = 1;
  elements.schoolInput.value = state.user?.school ?? elements.schoolInput.value;
  elements.campusInput.value = state.user?.campus ?? elements.campusInput.value;
  elements.semesterInput.value = state.user?.semester ?? elements.semesterInput.value;
  elements.setupKeyHint.textContent = state.user?.api_key_hint
    ? `账户凭据 ${state.user.api_key_hint}`
    : "加密保存在你的账户中";
  showOnly("onboarding");
  renderSetupStep();
}

function renderSetupStep() {
  $$('[data-setup-step]').forEach((panel) => {
    panel.hidden = Number(panel.dataset.setupStep) !== state.setupStep;
  });
  $$('[data-step-indicator]').forEach((indicator) => {
    const step = Number(indicator.dataset.stepIndicator);
    indicator.classList.toggle("active", step === state.setupStep);
    indicator.classList.toggle("done", step < state.setupStep);
  });
  elements.setupProgress.style.width = `${state.setupStep * 33.333}%`;
  elements.setupBackButton.disabled = state.setupStep === 1;
  const labels = {
    1: "继续：导入课表",
    2: "继续：导入地图",
    3: "确认并进入 CampusFlow",
  };
  elements.setupNextButton.querySelector(".action-label").textContent = labels[state.setupStep];
}

function validateSetupStep() {
  if (state.setupStep === 1) {
    if (!elements.schoolInput.value.trim() || !elements.campusInput.value.trim() || !elements.semesterInput.value.trim()) {
      throw new Error("请完整填写学校、校区和学期。");
    }
  }
  if (state.setupStep === 2 && !state.timetable?.entries?.length) {
    throw new Error("请先上传、解析并确认课表。");
  }
  if (state.setupStep === 3 && !state.campusMap?.places?.length) {
    throw new Error("请先上传并确认校园地图地点。");
  }
}

async function advanceSetup() {
  try {
    validateSetupStep();
    if (state.setupStep < 3) {
      state.setupStep += 1;
      renderSetupStep();
      return;
    }
    await completeOnboarding();
  } catch (error) {
    showToast(error.message, "error");
  }
}

function readImage(file) {
  return new Promise((resolve, reject) => {
    if (!file || !["image/png", "image/jpeg", "image/webp", "image/gif"].includes(file.type)) {
      reject(new Error("请选择 PNG、JPEG、GIF 或 WebP 图片。"));
      return;
    }
    if (file.size > 16 * 1024 * 1024) {
      reject(new Error("图片不得超过 16 MiB。"));
      return;
    }
    const reader = new FileReader();
    reader.onload = () => resolve(reader.result);
    reader.onerror = () => reject(new Error("图片读取失败。"));
    reader.readAsDataURL(file);
  });
}

async function handleImageFile(file, kind) {
  try {
    const dataUrl = await readImage(file);
    const preview = kind === "timetable" ? elements.timetablePreview : elements.mapPreview;
    preview.replaceChildren();
    const image = document.createElement("img");
    image.src = dataUrl;
    image.alt = kind === "timetable" ? "待解析课表" : "待解析校园地图";
    preview.append(image);
    if (kind === "timetable") {
      state.timetableImage = dataUrl;
      state.timetable = null;
      elements.parseTimetableButton.disabled = false;
      setParseStatus(elements.timetableStatus, "图片已载入，等待解析", "");
      elements.timetableReview.hidden = true;
    } else {
      state.mapImage = dataUrl;
      state.campusMap = null;
      elements.parseMapButton.disabled = false;
      setParseStatus(elements.mapStatus, "图片已载入，等待解析", "");
      elements.mapReview.hidden = true;
    }
  } catch (error) {
    showToast(error.message, "error");
  }
}

function setParseStatus(element, text, kind) {
  element.textContent = text;
  element.className = `parse-status${kind ? ` ${kind}` : ""}`;
}

async function parseImage(kind) {
  const isTimetable = kind === "timetable";
  const imageData = isTimetable ? state.timetableImage : state.mapImage;
  const button = isTimetable ? elements.parseTimetableButton : elements.parseMapButton;
  const statusElement = isTimetable ? elements.timetableStatus : elements.mapStatus;
  if (!imageData) return;

  setButtonBusy(button, true, "Flash 正在识别…");
  setParseStatus(statusElement, "正在读取图片并生成结构化数据，通常需要 20–60 秒…", "working");
  try {
    const payload = await api(`/api/v1/onboarding/parse-${isTimetable ? "timetable" : "map"}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ image_data: imageData }),
    });
    if (isTimetable) {
      state.timetable = payload;
      renderTimetable();
      setParseStatus(statusElement, `识别完成：${payload.entries.length} 条课程，请检查后继续。`, "success");
    } else {
      state.campusMap = payload;
      renderCampusMap();
      setParseStatus(statusElement, `数据包已生成：${payload.places.length} 个地点，请检查后继续。`, "success");
    }
  } catch (error) {
    setParseStatus(statusElement, error.message, "error");
    showToast(error.message, "error");
  } finally {
    setButtonBusy(button, false, "");
    button.disabled = false;
  }
}

function courseInput(entry, field, type = "text") {
  const input = document.createElement("input");
  input.type = type;
  input.value = entry[field] ?? "";
  input.title = field;
  input.addEventListener("change", () => {
    entry[field] = input.value;
  });
  return input;
}

function renderTimetable() {
  elements.timetableTable.replaceChildren();
  const entries = state.timetable?.entries ?? [];
  elements.timetableSummary.textContent = `${entries.length} 条课程记录`;
  elements.timetableReview.hidden = false;
  entries.forEach((entry, index) => {
    const row = document.createElement("div");
    row.className = "course-row";
    row.append(
      courseInput(entry, "date", "date"),
      courseInput(entry, "title"),
      courseInput(entry, "start_time", "time"),
      courseInput(entry, "end_time", "time"),
      courseInput(entry, "location"),
      courseInput(entry, "teacher"),
    );
    const remove = document.createElement("button");
    remove.type = "button";
    remove.textContent = "×";
    remove.setAttribute("aria-label", `删除 ${entry.title}`);
    remove.addEventListener("click", () => {
      state.timetable.entries.splice(index, 1);
      renderTimetable();
    });
    row.append(remove);
    elements.timetableTable.append(row);
  });
}

function renderCampusMap() {
  const places = state.campusMap?.places ?? [];
  elements.campusMapName.textContent = state.campusMap?.campus_name || "未命名校区";
  elements.placeCount.textContent = `${places.length} 个地点`;
  elements.placeCloud.replaceChildren();
  elements.mapReview.hidden = false;
  places.forEach((place, index) => {
    const tag = document.createElement("div");
    tag.className = "place-tag";
    const name = document.createElement("span");
    name.textContent = place.name;
    const category = document.createElement("small");
    category.textContent = place.category;
    const remove = document.createElement("button");
    remove.type = "button";
    remove.textContent = "×";
    remove.setAttribute("aria-label", `删除 ${place.name}`);
    remove.addEventListener("click", () => {
      state.campusMap.places.splice(index, 1);
      renderCampusMap();
    });
    tag.append(name, category, remove);
    elements.placeCloud.append(tag);
  });
}

async function completeOnboarding() {
  setButtonBusy(elements.setupNextButton, true, "正在创建校园空间…");
  try {
    const payload = await api("/api/v1/onboarding", {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        school: elements.schoolInput.value.trim(),
        campus: elements.campusInput.value.trim(),
        semester: elements.semesterInput.value.trim(),
        timetable: state.timetable.entries,
        campus_map: state.campusMap,
      }),
    });
    state.user = payload.user;
    state.settingsContext = { timetable: state.timetable.entries, campus_map: state.campusMap };
    showToast(`已连接 ${payload.timetable_count} 条课程和 ${payload.campus_place_count} 个地点`);
    showApp();
  } finally {
    setButtonBusy(elements.setupNextButton, false, "");
  }
}

function showApp() {
  showOnly("app");
  elements.userName.textContent = state.user.display_name;
  elements.userInitial.textContent = state.user.display_name.slice(0, 1).toUpperCase();
  elements.contextLine.textContent = `已连接：${state.user.school} · ${state.user.campus} · ${state.user.semester}。AI 凭据由账户安全托管。`;
  elements.credentialHint.textContent = state.user.api_key_hint
    ? `已配置 ${state.user.api_key_hint} · 点击管理`
    : "未配置 · 点击管理";
  setSessionId();
  switchAppTab(state.appTab);
}

function switchAppTab(tab) {
  state.appTab = tab;
  $$('[data-app-tab]').forEach((button) => {
    button.classList.toggle("active", button.dataset.appTab === tab);
  });
  $$('[data-app-surface]').forEach((surface) => {
    surface.hidden = surface.dataset.appSurface !== tab;
  });
  if (tab === "today") loadTodayDashboard();
  if (tab === "plans") loadPlans();
  if (tab === "agent") elements.messageInput.focus();
}

function openAgentWithPrompt(prompt = "") {
  switchAppTab("agent");
  if (prompt) {
    elements.messageInput.value = prompt;
    resizeComposer();
  }
  elements.messageInput.focus();
}

function formatCampusDate(date) {
  return new Intl.DateTimeFormat("zh-CN", {
    month: "long",
    day: "numeric",
    weekday: "long",
  }).format(date);
}

async function loadTodayDashboard() {
  const now = new Date();
  const hour = now.getHours();
  elements.todayGreeting.textContent = `${hour < 11 ? "早上" : hour < 18 ? "下午" : "晚上"}好，${state.user.display_name}`;
  elements.todayDate.textContent = `${formatCampusDate(now)} · ${state.user.campus ?? "校园"}`;
  try {
    const [context, sessions] = await Promise.all([
      state.settingsContext ?? api("/api/v1/me/context"),
      api("/api/v1/sessions"),
    ]);
    state.settingsContext = context;
    state.sessions = sessions;
    const localDate = `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, "0")}-${String(now.getDate()).padStart(2, "0")}`;
    const courses = (context.timetable ?? []).filter((item) => item.date === localDate);
    const upcoming = (context.timetable ?? [])
      .filter((item) => item.date >= localDate)
      .sort((left, right) => `${left.date} ${left.start_time}`.localeCompare(`${right.date} ${right.start_time}`));
    elements.todayCourseCount.textContent = `${courses.length} 节课`;
    elements.todayPlaceCount.textContent = context.campus_map?.places?.length ?? 0;
    elements.todayHistoryCount.textContent = sessions.length;
    elements.todayCourseList.replaceChildren();
    if (courses.length) {
      courses.forEach((course, index) => {
        const item = document.createElement("article");
        item.innerHTML = `<time>${course.start_time}<small>${course.end_time}</small></time><i></i><div><span>0${index + 1} / COURSE</span><h3></h3><p></p></div>`;
        item.querySelector("h3").textContent = course.title;
        item.querySelector("p").textContent = `${course.location || "地点待定"}${course.teacher ? ` · ${course.teacher}` : ""}`;
        elements.todayCourseList.append(item);
      });
      elements.todaySuggestion.textContent = `今天有 ${courses.length} 节课。建议在最后一节课后留出 30 分钟整理笔记，再开始新的学习任务。`;
    } else {
      const emptyDay = contextListItem("今天没有排课", "可以安排一段 90–120 分钟的深度学习时间");
      emptyDay.className = "day-empty";
      elements.todayCourseList.append(emptyDay);
      elements.todaySuggestion.textContent = "今天是无课日。可以从最近课程中选择一个薄弱主题，安排一次完整的复习闭环。";
    }
    const next = upcoming[0];
    elements.nextCourseTitle.textContent = next?.title ?? "近期没有课程";
    elements.nextCourseMeta.textContent = next
      ? `${next.date} · ${next.start_time} · ${next.location || "地点待定"}`
      : "适合安排自主学习或完善本周计划。";
  } catch (error) {
    showToast(error.message, "error");
  }
}

async function loadPlans() {
  elements.planList.innerHTML = '<div class="plan-empty">正在读取执行计划…</div>';
  elements.planGoals.innerHTML = '<div class="goal-empty">正在载入目标…</div>';
  try {
    const payload = await api("/api/v1/planning");
    state.planning = payload;
    elements.planProgress.textContent = `${payload.progress}%`;
    elements.planProgressBar.style.width = `${payload.progress}%`;
    elements.planTaskCount.textContent = payload.total_tasks;
    elements.planDueToday.textContent = payload.due_today;
    elements.planCompleted.textContent = payload.completed_tasks;
    renderPlanningTasks();
    renderPlanGoals(payload.plans);
  } catch (error) {
    elements.planList.innerHTML = '<div class="plan-empty">读取失败，请稍后重试。</div>';
    elements.planGoals.innerHTML = '<div class="goal-empty">目标载入失败</div>';
    showToast(error.message, "error");
  }
}

function taskTimeLabel(task) {
  if (!task.start_at) return "暂未安排时间";
  const start = new Date(task.start_at);
  const day = start.toLocaleDateString("zh-CN", { month: "numeric", day: "numeric", weekday: "short" });
  const time = start.toLocaleTimeString("zh-CN", { hour: "2-digit", minute: "2-digit" });
  const reminder = task.reminder_minutes != null ? ` · 提前 ${task.reminder_minutes} 分钟提醒` : "";
  return `${day} ${time}${reminder}`;
}

function renderPlanningTasks() {
  const tasks = state.planning?.tasks ?? [];
  const filtered = tasks.filter((task) => state.taskFilter === "all" || task.status === state.taskFilter);
  elements.planList.replaceChildren();
  if (!filtered.length) {
    elements.planList.innerHTML = '<div class="plan-empty"><b>当前筛选下没有待办</b><span>可以快速添加，或让 Agent 根据目标生成完整计划。</span></div>';
    return;
  }
  filtered.forEach((task) => {
    const item = document.createElement("article");
    item.className = `task-item ${task.status}`;
    const check = document.createElement("button");
    check.type = "button";
    check.className = "task-check";
    check.setAttribute("aria-label", task.status === "completed" ? "恢复待办" : "完成待办");
    check.textContent = task.status === "completed" ? "✓" : "";
    check.addEventListener("click", () => setTaskCompleted(task, task.status !== "completed", check));
    const content = document.createElement("div");
    const title = document.createElement("b");
    title.textContent = task.title;
    const meta = document.createElement("span");
    meta.textContent = `${taskTimeLabel(task)}${task.location ? ` · ${task.location}` : ""}`;
    content.append(title, meta);
    const remove = document.createElement("button");
    remove.type = "button";
    remove.className = "task-remove";
    remove.textContent = "删除";
    remove.addEventListener("click", () => removeTask(task, remove));
    item.append(check, content, remove);
    elements.planList.append(item);
  });
}

function renderPlanGoals(plans) {
  elements.planGoals.replaceChildren();
  if (!plans.length) {
    elements.planGoals.innerHTML = '<div class="goal-empty"><b>还没有长期目标</b><span>让 Agent 创建包含里程碑和时间块的计划。</span></div>';
    return;
  }
  plans.forEach((plan) => {
    const card = document.createElement("article");
    card.className = "goal-card";
    const heading = document.createElement("div");
    const title = document.createElement("b");
    title.textContent = plan.title;
    const progress = document.createElement("strong");
    progress.textContent = `${plan.progress}%`;
    heading.append(title, progress);
    const summary = document.createElement("p");
    summary.textContent = plan.summary || `${plan.completed_count}/${plan.task_count} 个执行项已完成`;
    const bar = document.createElement("i");
    const fill = document.createElement("span");
    fill.style.width = `${plan.progress}%`;
    bar.append(fill);
    const milestones = document.createElement("ul");
    plan.milestones.forEach((milestone) => {
      const row = document.createElement("li");
      row.textContent = `${milestone.completed_count === milestone.task_count && milestone.task_count ? "✓" : "○"} ${milestone.title}`;
      milestones.append(row);
    });
    card.append(heading, summary, bar, milestones);
    elements.planGoals.append(card);
  });
}

async function setTaskCompleted(task, completed, button) {
  button.disabled = true;
  try {
    await api(`/api/v1/tasks/${encodeURIComponent(task.task_id)}`, {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ completed }),
    });
    await loadPlans();
    showToast(completed ? "待办已完成" : "待办已恢复");
  } catch (error) {
    button.disabled = false;
    showToast(error.message, "error");
  }
}

async function removeTask(task, button) {
  button.disabled = true;
  try {
    await api(`/api/v1/tasks/${encodeURIComponent(task.task_id)}`, { method: "DELETE" });
    await loadPlans();
    showToast("待办已删除");
  } catch (error) {
    button.disabled = false;
    showToast(error.message, "error");
  }
}

async function createQuickTask(event) {
  event.preventDefault();
  const title = elements.quickTaskTitle.value.trim();
  if (!title) return;
  const button = elements.quickTaskForm.querySelector('button[type="submit"]');
  button.disabled = true;
  try {
    const time = elements.quickTaskTime.value;
    await api("/api/v1/tasks", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        title,
        start_at: time || null,
        end_at: null,
        reminder_minutes: elements.quickTaskReminder.value ? Number(elements.quickTaskReminder.value) : null,
      }),
    });
    elements.quickTaskForm.reset();
    await loadPlans();
    showToast("待办已添加");
  } catch (error) {
    showToast(error.message, "error");
  } finally {
    button.disabled = false;
  }
}

function selectedModel() {
  return $('input[name="model"]:checked').value;
}

function modelLabel(model = selectedModel()) {
  return model === "deepseek-flash" ? "FLASH" : "V4 PRO";
}

function setSessionId() {
  elements.sessionId.textContent = state.sessionId;
  elements.sessionId.title = state.sessionId;
}

function setServiceState(online, label) {
  elements.systemState.classList.toggle("online", online);
  elements.systemState.classList.toggle("offline", !online);
  elements.systemState.lastElementChild.textContent = label;
}

function clearEmptyState() {
  elements.emptyState?.remove();
}

function scrollMessages() {
  elements.messages.scrollTop = elements.messages.scrollHeight;
}

function appendMessage(role, content, options = {}) {
  clearEmptyState();
  const article = document.createElement("article");
  article.className = `message ${role}${options.loading ? " loading" : ""}`;
  const meta = document.createElement("div");
  meta.className = "meta";
  meta.textContent = role === "user" ? `${state.user?.display_name ?? "YOU"} / 任务输入` : `AGENT / ${modelLabel()}`;
  const bubble = document.createElement("div");
  bubble.className = "bubble";
  if (options.loading) {
    const typing = document.createElement("span");
    typing.className = "typing";
    for (let index = 0; index < 3; index += 1) typing.append(document.createElement("span"));
    bubble.append(typing);
  } else {
    bubble.textContent = content;
  }
  article.append(meta, bubble);
  elements.messages.append(article);
  scrollMessages();
  return article;
}

function ensureTraceArea() {
  if (!state.hasTraces) {
    elements.traceList.replaceChildren();
    state.hasTraces = true;
  }
}

function safeJson(value) {
  try {
    return JSON.stringify(value, null, 2);
  } catch {
    return String(value);
  }
}

function renderToolTrace(trace) {
  ensureTraceArea();
  const card = document.createElement("details");
  card.className = "trace-card";
  const summary = document.createElement("summary");
  const kind = document.createElement("span");
  kind.className = "trace-kind";
  kind.textContent = "TOOL";
  const name = document.createElement("span");
  name.textContent = trace.tool_name;
  summary.append(kind, name);
  const details = document.createElement("pre");
  details.textContent = safeJson({ arguments: trace.arguments, result: trace.result, tool_call_id: trace.tool_call_id });
  card.append(summary, details);
  elements.traceList.prepend(card);
}

function actionDescription(action) {
  const lines = [];
  if (action.kind === "plan") {
    const milestones = action.payload?.milestones ?? [];
    const taskCount = milestones.reduce((total, milestone) => total + (milestone.tasks?.length ?? 0), 0);
    lines.push(`${milestones.length} 个里程碑 · ${taskCount} 个执行项`);
    if (action.payload?.target_date) lines.push(`目标日期：${action.payload.target_date}`);
  }
  if (action.start_at) lines.push(`开始：${new Date(action.start_at).toLocaleString("zh-CN")}`);
  if (action.end_at) lines.push(`结束：${new Date(action.end_at).toLocaleString("zh-CN")}`);
  if (action.reminder_minutes != null) lines.push(`提醒：提前 ${action.reminder_minutes} 分钟`);
  if (action.reason) lines.push(`原因：${action.reason}`);
  if (action.conflicts?.length) lines.push(`⚠ ${action.conflicts.join("；")}`);
  return lines.join("\n") || "确认后写入演示事务存储。";
}

function renderPendingAction(action) {
  ensureTraceArea();
  const card = document.createElement("section");
  card.className = "action-card";
  const label = document.createElement("div");
  label.className = "action-label";
  label.textContent = `PENDING / ${action.kind === "plan" ? "PLAN" : action.action.toUpperCase()}`;
  const title = document.createElement("h3");
  title.textContent = action.title;
  const description = document.createElement("p");
  description.textContent = actionDescription(action);
  const button = document.createElement("button");
  button.type = "button";
  button.textContent = "确认执行此操作";
  button.addEventListener("click", () => confirmAction(action.proposal_id, card, button, label));
  card.append(label, title, description, button);
  elements.traceList.prepend(card);
}

async function confirmAction(proposalId, card, button, label) {
  button.disabled = true;
  button.textContent = "正在确认…";
  try {
    const payload = await api(`/api/v1/actions/${encodeURIComponent(proposalId)}/confirm`, { method: "POST" });
    card.classList.add("confirmed");
    label.textContent = "CONFIRMED / 已写入";
    button.textContent = "已确认";
    showToast(payload.message || "操作已确认");
    await loadPlans();
  } catch (error) {
    button.disabled = false;
    button.textContent = "重新确认";
    showToast(error.message, "error");
  }
}

async function sendMessage(message) {
  if (!message || state.sending) return;
  state.sending = true;
  elements.sendButton.disabled = true;
  elements.messageInput.disabled = true;
  appendMessage("user", message);
  const loading = appendMessage("assistant", "", { loading: true });
  try {
    const payload = await api("/api/v1/chat", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        session_id: state.sessionId,
        model: selectedModel(),
        message,
      }),
    });
    loading.remove();
    appendMessage("assistant", payload.message);
    payload.tool_traces.forEach(renderToolTrace);
    payload.pending_actions.forEach(renderPendingAction);
    try {
      state.sessions = await api("/api/v1/sessions");
      elements.todayHistoryCount.textContent = state.sessions.length;
    } catch {
      // The completed answer remains usable if refreshing session metadata fails.
    }
    setServiceState(true, "Agent 服务在线");
  } catch (error) {
    loading.remove();
    appendMessage("assistant", `本次任务未完成：${error.message}`);
    showToast(error.message, "error");
  } finally {
    state.sending = false;
    elements.sendButton.disabled = false;
    elements.messageInput.disabled = false;
    elements.messageInput.value = "";
    resizeComposer();
    elements.messageInput.focus();
  }
}

function resizeComposer() {
  elements.messageInput.style.height = "auto";
  elements.messageInput.style.height = `${Math.min(elements.messageInput.scrollHeight, 140)}px`;
}

function resetSession(notify = true) {
  state.sessionId = createSessionId();
  state.hasTraces = false;
  setSessionId();
  elements.messages.innerHTML = '<div class="empty-state" id="emptyState"><div class="orb"><span></span><span></span><span></span></div><p class="eyebrow">NEW CONTEXT</p><h3>新会话已就绪</h3><p>个人课表和校园数据继续可用，对话上下文与执行轨迹已经清空。</p></div>';
  elements.emptyState = $("#emptyState");
  elements.traceList.innerHTML = '<div class="trace-empty">尚无工具调用<br /><span>新会话不会继承上一轮对话</span></div>';
  closeHistory();
  switchAppTab("agent");
  if (notify) showToast("已创建独立会话");
}

function openHistory() {
  elements.historyDrawer.hidden = false;
  elements.drawerScrim.hidden = false;
  elements.historySearch.value = "";
  loadHistory();
  setTimeout(() => elements.historySearch.focus(), 0);
}

function closeHistory() {
  elements.historyDrawer.hidden = true;
  elements.drawerScrim.hidden = true;
}

function sessionTime(value) {
  const date = new Date(value);
  const today = new Date();
  if (date.toDateString() === today.toDateString()) {
    return date.toLocaleTimeString("zh-CN", { hour: "2-digit", minute: "2-digit" });
  }
  return date.toLocaleDateString("zh-CN", { month: "numeric", day: "numeric" });
}

function renderHistorySessions(sessions) {
  elements.historyList.replaceChildren();
  if (!sessions.length) {
    elements.historyList.innerHTML = '<div class="history-empty"><b>还没有匹配的会话</b><span>开始一次 Agent 对话后，会自动保存在这里。</span></div>';
    return;
  }
  sessions.forEach((session) => {
    const card = document.createElement("article");
    card.className = `history-card${session.session_id === state.sessionId ? " active" : ""}`;
    const open = document.createElement("button");
    open.type = "button";
    open.className = "history-open";
    const heading = document.createElement("span");
    const title = document.createElement("b");
    const time = document.createElement("time");
    title.textContent = session.title;
    time.textContent = sessionTime(session.updated_at);
    heading.append(title, time);
    const preview = document.createElement("p");
    preview.textContent = session.last_message;
    const meta = document.createElement("small");
    meta.textContent = `${session.message_count} 条消息 · ${session.model_name === "deepseek-flash" ? "FLASH" : "V4 PRO"}`;
    open.append(heading, preview, meta);
    open.addEventListener("click", () => openSession(session.session_id));
    const rename = document.createElement("button");
    rename.type = "button";
    rename.className = "history-rename";
    rename.textContent = "改名";
    rename.addEventListener("click", () => showRenameSession(session, card));
    card.append(open, rename);
    elements.historyList.append(card);
  });
}

async function loadHistory(query = "") {
  elements.historyList.innerHTML = '<div class="history-empty">正在载入会话…</div>';
  try {
    const suffix = query ? `?query=${encodeURIComponent(query)}` : "";
    state.sessions = await api(`/api/v1/sessions${suffix}`);
    elements.todayHistoryCount.textContent = state.sessions.length;
    renderHistorySessions(state.sessions);
  } catch (error) {
    elements.historyList.innerHTML = '<div class="history-empty">载入失败</div>';
    showToast(error.message, "error");
  }
}

async function openSession(sessionId) {
  try {
    const history = await api(`/api/v1/sessions/${encodeURIComponent(sessionId)}/history`);
    const session = state.sessions.find((item) => item.session_id === sessionId);
    state.sessionId = sessionId;
    state.hasTraces = false;
    if (session?.model_name) {
      const modelInput = $(`input[name="model"][value="${session.model_name}"]`);
      if (modelInput) modelInput.checked = true;
      elements.modelBadge.textContent = modelLabel(session.model_name);
    }
    setSessionId();
    elements.messages.replaceChildren();
    history.forEach((message) => appendMessage(message.role, message.content));
    elements.traceList.innerHTML = '<div class="trace-empty">已恢复对话文本<br /><span>新的工具调用会继续显示在这里</span></div>';
    closeHistory();
    switchAppTab("agent");
    showToast(`已恢复 ${history.length} 条消息`);
  } catch (error) {
    showToast(error.message, "error");
  }
}

function showRenameSession(session, card) {
  const form = document.createElement("form");
  form.className = "history-rename-form";
  const input = document.createElement("input");
  input.maxLength = 80;
  input.value = session.title;
  input.setAttribute("aria-label", "新的会话名称");
  const save = document.createElement("button");
  save.type = "submit";
  save.textContent = "保存";
  const cancel = document.createElement("button");
  cancel.type = "button";
  cancel.textContent = "取消";
  cancel.addEventListener("click", () => renderHistorySessions(state.sessions));
  form.append(input, save, cancel);
  form.addEventListener("submit", (event) => {
    event.preventDefault();
    renameSession(session, input.value.trim());
  });
  card.replaceChildren(form);
  input.focus();
  input.select();
}

async function renameSession(session, title) {
  if (!title || title === session.title) {
    renderHistorySessions(state.sessions);
    return;
  }
  try {
    await api(`/api/v1/sessions/${encodeURIComponent(session.session_id)}`, {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ title }),
    });
    await loadHistory(elements.historySearch.value.trim());
    showToast("会话名称已更新");
  } catch (error) {
    showToast(error.message, "error");
  }
}

function fillSettingsProfile() {
  const user = state.user;
  elements.settingsInitial.textContent = user.display_name.slice(0, 1).toUpperCase();
  elements.settingsName.textContent = user.display_name;
  elements.settingsEmail.textContent = user.email;
  elements.settingsDisplayName.value = user.display_name;
  elements.settingsEmailInput.value = user.email;
  elements.settingsSchool.value = user.school ?? "";
  elements.settingsCampus.value = user.campus ?? "";
  elements.settingsSemester.value = user.semester ?? "";
  elements.settingsApiKey.value = "";
  elements.settingsKeyState.textContent = user.api_key_configured
    ? `已安全连接 ${user.api_key_hint ?? ""}`
    : "尚未配置";
  elements.adminTabButton.hidden = user.role !== "admin";
}

function switchSettingsTab(tab) {
  $$('[data-settings-tab]').forEach((button) => {
    button.classList.toggle("active", button.dataset.settingsTab === tab);
  });
  $$('[data-settings-panel]').forEach((panel) => {
    panel.hidden = panel.dataset.settingsPanel !== tab;
  });
  if (tab === "data") loadSettingsContext();
  if (tab === "admin") loadAdminUsers();
}

function openSettings() {
  fillSettingsProfile();
  switchSettingsTab("profile");
  showOnly("settings");
}

function contextListItem(primary, secondary) {
  const item = document.createElement("article");
  const title = document.createElement("b");
  const detail = document.createElement("span");
  title.textContent = primary;
  detail.textContent = secondary;
  item.append(title, detail);
  return item;
}

async function loadSettingsContext(force = false) {
  if (!state.settingsContext || force) {
    try {
      state.settingsContext = await api("/api/v1/me/context");
    } catch (error) {
      showToast(error.message, "error");
      return;
    }
  }
  const courses = state.settingsContext.timetable ?? [];
  const places = state.settingsContext.campus_map?.places ?? [];
  elements.settingsCourseCount.textContent = courses.length;
  elements.settingsPlaceCount.textContent = places.length;
  elements.settingsSemesterCard.textContent = state.user.semester ?? "未设置";
  elements.settingsCourseList.replaceChildren();
  elements.settingsPlaceList.replaceChildren();
  courses.slice(0, 8).forEach((course) => {
    elements.settingsCourseList.append(contextListItem(
      course.title,
      `${course.date} · ${course.start_time}–${course.end_time} · ${course.location || "地点待定"}`,
    ));
  });
  places.slice(0, 10).forEach((place) => {
    elements.settingsPlaceList.append(contextListItem(
      place.name,
      `${place.category || "其他"}${place.zone ? ` · ${place.zone}` : ""}`,
    ));
  });
  if (!courses.length) elements.settingsCourseList.append(contextListItem("暂无课表", "请重新配置学习数据"));
  if (!places.length) elements.settingsPlaceList.append(contextListItem("暂无地点", "请重新配置校园地图"));
}

function adminStatus(text, kind) {
  const badge = document.createElement("span");
  badge.className = `table-badge ${kind}`;
  badge.textContent = text;
  return badge;
}

async function loadAdminUsers() {
  elements.adminUserRows.innerHTML = '<tr><td colspan="6" class="table-loading">正在读取账户目录…</td></tr>';
  try {
    const users = await api("/api/v1/admin/users");
    elements.adminUserCount.textContent = users.length;
    elements.adminUserRows.replaceChildren();
    users.forEach((user) => {
      const row = document.createElement("tr");
      const identity = document.createElement("td");
      identity.append(contextListItem(user.display_name, user.email));
      const role = document.createElement("td");
      role.append(adminStatus(user.role === "admin" ? "管理员" : "用户", user.role));
      const campus = document.createElement("td");
      campus.textContent = [user.school, user.campus].filter(Boolean).join(" · ") || "未配置";
      const data = document.createElement("td");
      data.textContent = `${user.timetable_count} 课 / ${user.campus_place_count} 地点`;
      const credential = document.createElement("td");
      credential.append(adminStatus(user.api_key_configured ? "已配置" : "未配置", user.api_key_configured ? "ready" : "empty"));
      const created = document.createElement("td");
      created.textContent = new Date(user.created_at).toLocaleDateString("zh-CN");
      row.append(identity, role, campus, data, credential, created);
      elements.adminUserRows.append(row);
    });
  } catch (error) {
    elements.adminUserRows.innerHTML = '<tr><td colspan="6" class="table-loading">加载失败</td></tr>';
    showToast(error.message, "error");
  }
}

async function saveSettings(event) {
  event.preventDefault();
  const button = elements.settingsForm.querySelector("button[type='submit']");
  const payload = {
    display_name: elements.settingsDisplayName.value.trim(),
    school: elements.settingsSchool.value.trim() || null,
    campus: elements.settingsCampus.value.trim() || null,
    semester: elements.settingsSemester.value.trim() || null,
  };
  const newApiKey = elements.settingsApiKey.value.trim();
  if (newApiKey) payload.api_key = newApiKey;
  setButtonBusy(button, true, "正在加密保存…");
  try {
    state.user = await api("/api/v1/me/settings", {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });
    fillSettingsProfile();
    showToast("账户配置已更新");
  } catch (error) {
    showToast(error.message, "error");
  } finally {
    setButtonBusy(button, false, "");
  }
}

async function editLearningData() {
  await loadSettingsContext(true);
  state.timetable = state.settingsContext?.timetable?.length
    ? { entries: structuredClone(state.settingsContext.timetable) }
    : null;
  state.campusMap = state.settingsContext?.campus_map?.places?.length
    ? structuredClone(state.settingsContext.campus_map)
    : null;
  if (state.timetable) renderTimetable();
  if (state.campusMap) renderCampusMap();
  showOnboarding();
}

async function checkHealth() {
  try {
    const payload = await api("/health");
    setServiceState(true, `服务在线 · ${payload.supported_models?.length ?? 0} 个模型`);
  } catch {
    setServiceState(false, "服务连接失败");
  }
}

async function initialize() {
  checkHealth();
  try {
    state.user = await api("/api/v1/me");
    if (state.user.onboarding_complete) showApp();
    else showOnboarding();
  } catch {
    showOnly("auth");
    switchAuth("login");
  }
}

$$('[data-auth-tab]').forEach((button) => button.addEventListener("click", () => switchAuth(button.dataset.authTab)));
elements.loginForm.addEventListener("submit", (event) => { event.preventDefault(); submitAuth(elements.loginForm, "/api/v1/auth/login"); });
elements.registerForm.addEventListener("submit", (event) => { event.preventDefault(); submitAuth(elements.registerForm, "/api/v1/auth/register"); });
elements.setupLogoutButton.addEventListener("click", logout);
elements.logoutButton.addEventListener("click", logout);
elements.userChip.addEventListener("click", openSettings);
elements.credentialCard.addEventListener("click", openSettings);
elements.settingsBackButton.addEventListener("click", showApp);
elements.historyButton.addEventListener("click", openHistory);
elements.agentHistoryButton.addEventListener("click", openHistory);
elements.historyCloseButton.addEventListener("click", closeHistory);
elements.drawerScrim.addEventListener("click", closeHistory);
elements.historySearch.addEventListener("input", () => {
  clearTimeout(elements.historySearch.searchTimer);
  elements.historySearch.searchTimer = setTimeout(() => loadHistory(elements.historySearch.value.trim()), 180);
});
elements.settingsForm.addEventListener("submit", saveSettings);
elements.quickTaskForm.addEventListener("submit", createQuickTask);
$$('[data-task-filter]').forEach((button) => button.addEventListener("click", () => {
  state.taskFilter = button.dataset.taskFilter;
  $$('[data-task-filter]').forEach((item) => item.classList.toggle("active", item === button));
  renderPlanningTasks();
}));
elements.editOnboardingButton.addEventListener("click", editLearningData);
$$('[data-settings-tab]').forEach((button) => button.addEventListener("click", () => switchSettingsTab(button.dataset.settingsTab)));
elements.setupBackButton.addEventListener("click", () => { if (state.setupStep > 1) { state.setupStep -= 1; renderSetupStep(); } });
elements.setupNextButton.addEventListener("click", advanceSetup);
elements.timetableFile.addEventListener("change", () => handleImageFile(elements.timetableFile.files[0], "timetable"));
elements.mapFile.addEventListener("change", () => handleImageFile(elements.mapFile.files[0], "map"));
elements.parseTimetableButton.addEventListener("click", () => parseImage("timetable"));
elements.parseMapButton.addEventListener("click", () => parseImage("map"));
elements.composer.addEventListener("submit", (event) => { event.preventDefault(); sendMessage(elements.messageInput.value.trim()); });
elements.messageInput.addEventListener("input", resizeComposer);
elements.messageInput.addEventListener("keydown", (event) => {
  if (event.key === "Enter" && !event.shiftKey) { event.preventDefault(); elements.composer.requestSubmit(); }
});
$$('input[name="model"]').forEach((radio) => radio.addEventListener("change", () => {
  elements.modelBadge.textContent = modelLabel();
  showToast(`已切换至 ${modelLabel()}`);
}));
$$('[data-prompt]').forEach((button) => button.addEventListener("click", () => {
  elements.messageInput.value = button.dataset.prompt;
  resizeComposer();
  elements.messageInput.focus();
}));
elements.newSessionButton.addEventListener("click", resetSession);
$$('[data-app-tab]').forEach((button) => button.addEventListener("click", () => switchAppTab(button.dataset.appTab)));
$$('[data-app-action="settings"]').forEach((button) => button.addEventListener("click", openSettings));
$$('[data-open-agent]').forEach((button) => button.addEventListener("click", () => openAgentWithPrompt(button.dataset.prompt)));

initialize();
