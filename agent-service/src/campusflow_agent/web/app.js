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
  setupSubscriptionForm: $("#setupSubscriptionForm"),
  setupSubscriptionUrl: $("#setupSubscriptionUrl"),
  setupSubscriptionButton: $("#setupSubscriptionButton"),
  setupSubscriptionStatus: $("#setupSubscriptionStatus"),
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
  agentControlButton: $("#agentControlButton"),
  agentControlDialog: $("#agentControlDialog"),
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
  skillSearch: $("#skillSearch"),
  skillCategory: $("#skillCategory"),
  skillInstalledCount: $("#skillInstalledCount"),
  skillEnabledCount: $("#skillEnabledCount"),
  skillGrid: $("#skillGrid"),
  skillAuditList: $("#skillAuditList"),
  skillDrawer: $("#skillDrawer"),
  skillScrim: $("#skillScrim"),
  skillDrawerClose: $("#skillDrawerClose"),
  skillDrawerCategory: $("#skillDrawerCategory"),
  skillDrawerVersion: $("#skillDrawerVersion"),
  skillDrawerSymbol: $("#skillDrawerSymbol"),
  skillDrawerName: $("#skillDrawerName"),
  skillDrawerAuthor: $("#skillDrawerAuthor"),
  skillDrawerDescription: $("#skillDrawerDescription"),
  skillDrawerCapabilities: $("#skillDrawerCapabilities"),
  skillDrawerPermissions: $("#skillDrawerPermissions"),
  skillInstallNote: $("#skillInstallNote"),
  skillInstallButton: $("#skillInstallButton"),
  skillToggleButton: $("#skillToggleButton"),
  skillUpgradeButton: $("#skillUpgradeButton"),
  skillUninstallButton: $("#skillUninstallButton"),
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
  baiduMapSettingsForm: $("#baiduMapSettingsForm"),
  baiduBrowserAk: $("#baiduBrowserAk"),
  baiduServerAk: $("#baiduServerAk"),
  baiduBrowserStatus: $("#baiduBrowserStatus"),
  baiduServerStatus: $("#baiduServerStatus"),
  baiduMapSettingsStatus: $("#baiduMapSettingsStatus"),
  clearBaiduBrowserAk: $("#clearBaiduBrowserAk"),
  clearBaiduServerAk: $("#clearBaiduServerAk"),
  saveBaiduMapSettings: $("#saveBaiduMapSettings"),
  hduHelpConnectionState: $("#hduHelpConnectionState"),
  hduHelpResourceList: $("#hduHelpResourceList"),
  hduHelpPatForm: $("#hduHelpPatForm"),
  hduHelpPatInput: $("#hduHelpPatInput"),
  connectHduHelpButton: $("#connectHduHelpButton"),
  viewHduHelpDataButton: $("#viewHduHelpDataButton"),
  syncHduHelpButton: $("#syncHduHelpButton"),
  disconnectHduHelpButton: $("#disconnectHduHelpButton"),
  hduHelpDataPanel: $("#hduHelpDataPanel"),
  hduHelpDataSummary: $("#hduHelpDataSummary"),
  hduHelpDataSections: $("#hduHelpDataSections"),
  hduHelpPromptList: $("#hduHelpPromptList"),
  adminTabButton: $("#adminTabButton"),
  settingsCourseCount: $("#settingsCourseCount"),
  settingsPlaceCount: $("#settingsPlaceCount"),
  settingsSemesterCard: $("#settingsSemesterCard"),
  settingsCourseList: $("#settingsCourseList"),
  settingsPlaceList: $("#settingsPlaceList"),
  scheduleSubscriptionForm: $("#scheduleSubscriptionForm"),
  scheduleSubscriptionUrl: $("#scheduleSubscriptionUrl"),
  scheduleSubscriptionState: $("#scheduleSubscriptionState"),
  syncSubscriptionButton: $("#syncSubscriptionButton"),
  disconnectSubscriptionButton: $("#disconnectSubscriptionButton"),
  campusPackageName: $("#campusPackageName"),
  campusPackageVersion: $("#campusPackageVersion"),
  campusPackageDescription: $("#campusPackageDescription"),
  campusPackagePlaceCount: $("#campusPackagePlaceCount"),
  campusPackageNoticeCount: $("#campusPackageNoticeCount"),
  campusPackageCorrectionCount: $("#campusPackageCorrectionCount"),
  campusNoticeList: $("#campusNoticeList"),
  campusCorrectionForm: $("#campusCorrectionForm"),
  correctionTargetType: $("#correctionTargetType"),
  correctionTargetId: $("#correctionTargetId"),
  correctionField: $("#correctionField"),
  correctionValue: $("#correctionValue"),
  correctionReason: $("#correctionReason"),
  campusCorrectionList: $("#campusCorrectionList"),
  campusPlaceSelect: $("#campusPlaceSelect"),
  campusPlaceQuery: $("#campusPlaceQuery"),
  campusPlaceSearchForm: $("#campusPlaceSearchForm"),
  campusPlaceSearchButton: $("#campusPlaceSearchButton"),
  campusPlaceSavedSelection: $("#campusPlaceSavedSelection"),
  campusPlaceReselectButton: $("#campusPlaceReselectButton"),
  campusPlaceSelectionStatus: $("#campusPlaceSelectionStatus"),
  campusPlaceCandidates: $("#campusPlaceCandidates"),
  campusPlaceMoreButton: $("#campusPlaceMoreButton"),
  campusPlacePreview: $("#campusPlacePreview"),
  campusPlaceConfirmButton: $("#campusPlaceConfirmButton"),
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
  settingsContext: null,
  appTab: "today",
  sessions: [],
  historyReadRevision: 0,
  planning: null,
  taskFilter: "all",
  skills: [],
  selectedSkill: null,
  scheduleSubscriptionUrl: "",
  scheduleSubscription: null,
  campusData: null,
  settingsTab: "profile",
  hduHelp: null,
};

function createSessionId() {
  const id = globalThis.crypto?.randomUUID?.() ?? `${Date.now()}-${Math.random()}`;
  return `web-${id}`;
}

async function responseError(response) {
  try {
    const payload = await response.json();
    const selectionMessage = {
      MAP_PLACE_SELECTION_REQUIRED: "请到设置 → 学习数据 → 校园地点确认，检索并确认起点和终点入口后重新规划。",
      MAP_SELECTION_EXPIRED: "候选已过期，请重新检索并确认地点。",
      MAP_SELECTION_INVALID: "候选已失效，请重新检索并确认地点。",
    }[payload.detail?.code ?? payload.code];
    if (selectionMessage) return selectionMessage;
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
  if (!response.ok) {
    const error = new Error(await responseError(response));
    error.status = response.status;
    throw error;
  }
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
  if (view !== "app") {
    closeReplyDetails();
    if (elements.agentControlDialog?.open) elements.agentControlDialog.close();
  }
  elements.authView.hidden = view !== "auth";
  elements.onboardingView.hidden = view !== "onboarding";
  elements.appView.hidden = view !== "app";
  elements.settingsView.hidden = view !== "settings";
  document.body.style.overflow = ["app", "settings"].includes(view) ? "hidden" : "auto";
  syncCampusRouteMaps();
  syncCampusPlaceSelection();
  syncBaiduMapSettings();
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
  if (endpoint === "/api/v1/auth/register") {
    const key = typeof body.api_key === "string" ? body.api_key.trim() : "";
    if (key) body.api_key = key;
    else delete body.api_key;
  }
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
  state.scheduleSubscriptionUrl = "";
  state.scheduleSubscription = null;
  elements.setupSubscriptionForm.reset();
  elements.scheduleSubscriptionForm.reset();
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

async function previewScheduleSubscription(event) {
  event.preventDefault();
  const url = elements.setupSubscriptionUrl.value.trim();
  if (!url) return;
  setButtonBusy(elements.setupSubscriptionButton, true, "正在读取…");
  elements.setupSubscriptionStatus.textContent = "正在安全读取 HDUHelp iCalendar…";
  elements.setupSubscriptionStatus.className = "working";
  try {
    const payload = await api("/api/v1/schedule-subscriptions/preview", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ url }),
    });
    state.scheduleSubscriptionUrl = url;
    state.timetable = {
      entries: payload.entries,
      warnings: payload.warnings,
    };
    elements.setupSubscriptionUrl.value = "";
    renderTimetable();
    elements.setupSubscriptionStatus.textContent = `已读取 ${payload.event_count} 条课程，完成首次配置后将加密保存订阅。`;
    elements.setupSubscriptionStatus.className = "success";
    showToast(`已读取 ${payload.calendar_name}`);
  } catch (error) {
    elements.setupSubscriptionStatus.textContent = error.message;
    elements.setupSubscriptionStatus.className = "error";
    showToast(error.message, "error");
  } finally {
    setButtonBusy(elements.setupSubscriptionButton, false, "");
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
    if (state.scheduleSubscriptionUrl) {
      try {
        const synced = await api("/api/v1/schedule-subscriptions", {
          method: "PUT",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ url: state.scheduleSubscriptionUrl }),
        });
        state.settingsContext = await api("/api/v1/me/context");
        state.scheduleSubscription = synced.status;
        showToast(`订阅已连接，共同步 ${synced.imported_count} 条课程`);
      } catch (error) {
        showToast(`基础资料已保存，但订阅连接失败：${error.message}`, "error");
      } finally {
        state.scheduleSubscriptionUrl = "";
      }
    } else {
      showToast(`已连接 ${payload.timetable_count} 条课程和 ${payload.campus_place_count} 个地点`);
    }
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
  if (tab !== "agent") closeReplyDetails();
  state.appTab = tab;
  syncCampusRouteMaps();
  syncCampusPlaceSelection();
  $$('[data-app-tab]').forEach((button) => {
    button.classList.toggle("active", button.dataset.appTab === tab);
  });
  $$('[data-app-surface]').forEach((surface) => {
    surface.hidden = surface.dataset.appSurface !== tab;
  });
  if (tab === "today") loadTodayDashboard();
  if (tab === "plans") loadPlans();
  if (tab === "skills") loadSkills();
  if (tab === "agent") elements.messageInput.focus();
}

function openAgentWithPrompt(prompt = "") {
  if (!elements.settingsView.hidden) {
    showApp();
  }
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

function taskStatusKey(owner, taskId) {
  return `campusflow.task-status:${encodeURIComponent(owner)}:${encodeURIComponent(taskId)}`;
}

function taskStatusOwner(intent) {
  return state.user?.user_id === intent.owner;
}

function taskStatusRecord(owner, task, completed) {
  const key = taskStatusKey(owner, task.task_id);
  const existing = localStorage.getItem(key);
  if (existing) {
    const intent = JSON.parse(existing);
    if (intent.owner !== owner || intent.task_id !== task.task_id || !intent.request?.operation_id) {
      throw new Error("本地状态操作记录无法核对，请勿重复操作。");
    }
    return { intent, existing: true };
  }
  if (!Number.isSafeInteger(task.task_version) || task.task_version < 1) {
    throw new Error("未取得最新任务版本，请刷新规划后再操作。");
  }
  if (!completed && !task.completion_operation_id) {
    throw new Error("此任务未保留可核验的完成回执，无法安全恢复。");
  }
  if (!globalThis.crypto?.randomUUID) throw new Error("当前浏览器不支持安全操作标识，请升级浏览器。");
  const request = { operation_id: crypto.randomUUID(), kind: completed ? "complete" : "restore",
    expected_revision: task.task_version };
  if (!completed) request.source_operation_id = task.completion_operation_id;
  const intent = { owner, task_id: task.task_id, request };
  // Persist only identifiers, before HTTP. A lost response must never create a new intent.
  localStorage.setItem(key, JSON.stringify(intent));
  return { intent, existing: false };
}

async function taskStatusResult(intent, operation) {
  if (!taskStatusOwner(intent)) return;
  if (operation.operation_id !== intent.request.operation_id || operation.task_id !== intent.task_id ||
      operation.user_id !== intent.owner || operation.kind !== intent.request.kind ||
      operation.expected_revision !== intent.request.expected_revision ||
      (operation.source_operation_id ?? null) !== (intent.request.source_operation_id ?? null)) {
    throw new Error("状态回执与原操作不一致，未显示成功，请保留操作标识核对。");
  }
  if (operation.state === "applied") {
    const expected = intent.request.kind === "complete" ? "completed" : "pending";
    if (operation.receipt?.operation_id !== operation.operation_id ||
        operation.receipt?.task_id !== intent.task_id || operation.receipt?.after_status !== expected) {
      throw new Error("操作回执缺少完成凭据，尚未核实结果。");
    }
    localStorage.removeItem(taskStatusKey(intent.owner, intent.task_id));
    document.querySelector("#taskStatusDialog")?.remove();
    await loadPlans();
    if (taskStatusOwner(intent)) showToast(expected === "completed" ? "待办已完成" : "待办已恢复");
    return;
  }
  if (operation.state === "cancelled") {
    localStorage.removeItem(taskStatusKey(intent.owner, intent.task_id));
    document.querySelector("#taskStatusDialog")?.remove();
    showToast("恢复预览已取消，任务保持原状态。");
    return;
  }
  if (operation.state !== "pending" || intent.request.kind !== "restore" || !operation.preview ||
      operation.preview.task?.task_id !== intent.task_id) {
    throw new Error("无法读取本次恢复预览，请查询原操作回执。");
  }
  renderTaskStatusDialog(intent, operation);
}

function renderTaskStatusDialog(intent, operation = null, failure = "") {
  if (!taskStatusOwner(intent)) return;
  document.querySelector("#taskStatusDialog")?.remove();
  const dialog = document.createElement("dialog");
  dialog.id = "taskStatusDialog";
  dialog.className = "action-card";
  dialog.setAttribute("aria-labelledby", "taskStatusTitle");
  Object.assign(dialog.style, { width: "min(30rem, calc(100vw - 2rem))", maxHeight: "80dvh",
    overflowY: "auto", padding: "1.5rem", borderRadius: "1.25rem", boxSizing: "border-box",
    background: "var(--cf-surface, white)", color: "var(--cf-ink, #29352f)" });
  const title = document.createElement("h2"); title.id = "taskStatusTitle";
  title.textContent = operation ? "核对恢复待办" : "操作结果未核实";
  const identity = document.createElement("p");
  identity.textContent = `操作标识：${intent.request.operation_id}`;
  Object.assign(identity.style, { overflowWrap: "anywhere", color: "var(--cf-muted, #626e65)", fontSize: "12px" });
  dialog.append(title, identity);
  const addLine = text => { const line = document.createElement("p"); line.textContent = text;
    Object.assign(line.style, { color: "var(--cf-ink, #29352f)", fontSize: "14px", lineHeight: "1.6" }); dialog.append(line); };
  const controls = document.createElement("div"); controls.className = "action-buttons";
  const button = (label, action) => {
    const element = document.createElement("button"); element.type = "button"; element.textContent = label;
    Object.assign(element.style, { minHeight: "44px", fontSize: "14px", color: "white",
      background: "var(--cf-accent, #416454)" });
    element.addEventListener("click", async () => {
      if (!taskStatusOwner(intent)) { dialog.remove(); return; }
      controls.querySelectorAll("button").forEach(item => { item.disabled = true; });
      try { await taskStatusResult(intent, await action()); }
      catch (error) { renderTaskStatusDialog(intent, null, error.message); }
    });
    controls.append(element); return element;
  };
  if (operation) {
    const preview = operation.preview, review = preview.course_review;
    addLine(preview.task.title);
    addLine(`${taskTimeLabel(preview.task)}${preview.task.location ? ` · ${preview.task.location}` : ""}`);
    addLine("已完成 → 未完成。仅改变完成状态，不会重建任务、自动改期或补发过去的提醒。");
    for (const warning of preview.warnings ?? []) addLine(warning);
    for (const conflict of preview.conflicts ?? []) addLine(`阻止恢复：${conflict}`);
    for (const overlap of review?.overlaps ?? []) {
      addLine(`课程重叠：${overlap.course?.title ?? "课程"} · ${overlap.overlap_start_at} 至 ${overlap.overlap_end_at}`);
    }
    let acknowledgement = null;
    const blocked = !review || !["none", "accepted", "needs_review", "unchecked"].includes(review.state) ||
      (preview.conflicts ?? []).length > 0;
    if (blocked) addLine("当前存在冲突或未完成的课程核对，请先处理，不能直接恢复。");
    const confirm = button("确认恢复为未完成", () => api(
      `/api/v1/task-status-operations/${encodeURIComponent(intent.request.operation_id)}/confirm`, {
        method: "POST", headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ acknowledgements: acknowledgement?.checked ? [{
          candidate_id: review.candidate_id, review_digest: review.review_digest,
        }] : [] }),
      }));
    confirm.dataset.taskStatusConfirm = "";
    if (review?.requires_acknowledgement) {
      const label = document.createElement("label"); acknowledgement = document.createElement("input");
      acknowledgement.type = "checkbox"; acknowledgement.dataset.taskStatusAck = "";
      label.append(acknowledgement, document.createTextNode("我已核对以上课程重叠，同意按当前原时间恢复。"));
      dialog.append(label);
      acknowledgement.addEventListener("change", () => { confirm.disabled = blocked || !acknowledgement.checked; });
    }
    confirm.disabled = blocked || Boolean(review?.requires_acknowledgement);
    button("取消恢复", () => api(`/api/v1/task-status-operations/${encodeURIComponent(intent.request.operation_id)}/cancel`, {
      method: "POST", headers: { "Content-Type": "application/json" }, body: "{}",
    }));
  } else {
    addLine(failure || "网络响应未能核实。请查询原回执，不要重复创建操作。");
    addLine("只会查询同一个操作标识；未取得有效回执不会显示操作成功。");
  }
  button("查询原操作回执", () => api(`/api/v1/task-status-operations/${encodeURIComponent(intent.request.operation_id)}`));
  const close = document.createElement("button"); close.type = "button"; close.textContent = "暂时关闭";
  Object.assign(close.style, { minHeight: "44px", fontSize: "14px", color: "var(--cf-ink, #29352f)",
    background: "var(--cf-surface-soft, #f1f2eb)" });
  close.addEventListener("click", () => dialog.remove()); controls.append(close);
  dialog.append(controls); document.body.append(dialog); dialog.showModal();
}

async function setTaskCompleted(task, completed, button) {
  button.disabled = true;
  let intent;
  try {
    const owner = state.user?.user_id;
    if (!owner) throw new Error("请先登录后再操作。");
    const record = taskStatusRecord(owner, task, completed); intent = record.intent;
    let operation;
    try {
      operation = record.existing
        ? await api(`/api/v1/task-status-operations/${encodeURIComponent(intent.request.operation_id)}`)
        : await api(`/api/v1/tasks/${encodeURIComponent(task.task_id)}/status-operations`, {
          method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(intent.request),
        });
    } catch (error) {
      // A definitive rejected creation has no committed operation. Transport failures remain unresolved.
      if (!record.existing && error.status >= 400 && error.status < 500 && ![408, 429].includes(error.status)) {
        localStorage.removeItem(taskStatusKey(owner, task.task_id)); intent = null;
      }
      throw error;
    }
    await taskStatusResult(intent, operation);
  } catch (error) {
    if (intent) renderTaskStatusDialog(intent, null, error.message);
    else showToast(error.message, "error");
  } finally {
    button.disabled = false;
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

function skillSymbol(skill) {
  const symbols = {
    "timetable-planner": "课",
    "campus-navigator": "图",
    "ddl-guardian": "时",
    "study-reviewer": "复",
  };
  return symbols[skill.skill_id] ?? "CF";
}

function filteredSkills() {
  const query = elements.skillSearch.value.trim().toLowerCase();
  const category = elements.skillCategory.value;
  return state.skills.filter((skill) => {
    const haystack = [skill.name, skill.description, ...skill.capabilities].join(" ").toLowerCase();
    return (!query || haystack.includes(query)) && (!category || skill.category === category);
  });
}

function renderSkillLibrary() {
  elements.skillInstalledCount.textContent = state.skills.filter((skill) => skill.installed).length;
  elements.skillEnabledCount.textContent = state.skills.filter((skill) => skill.enabled).length;
  elements.skillGrid.replaceChildren();
  const skills = filteredSkills();
  if (!skills.length) {
    elements.skillGrid.innerHTML = '<div class="skill-library-empty"><b>没有匹配的 Skill</b><span>换一个关键词或分类试试。</span></div>';
    return;
  }
  skills.forEach((skill, index) => {
    const card = document.createElement("article");
    card.className = `skill-card${skill.installed ? " installed" : ""}${skill.enabled ? " enabled" : ""}`;
    const top = document.createElement("div");
    top.className = "skill-card-top";
    const number = document.createElement("span");
    number.textContent = `${String(index + 1).padStart(2, "0")} · ${skill.category.toUpperCase()}`;
    const version = document.createElement("small");
    version.textContent = `v${skill.version}`;
    top.append(number, version);
    const identity = document.createElement("div");
    identity.className = "skill-card-identity";
    const symbol = document.createElement("i");
    symbol.textContent = skillSymbol(skill);
    const title = document.createElement("h2");
    title.textContent = skill.name;
    identity.append(symbol, title);
    const description = document.createElement("p");
    description.textContent = skill.description;
    const capabilities = document.createElement("div");
    capabilities.className = "skill-card-capabilities";
    skill.capabilities.slice(0, 3).forEach((capability) => {
      const badge = document.createElement("span");
      badge.textContent = capability;
      capabilities.append(badge);
    });
    const footer = document.createElement("div");
    footer.className = "skill-card-footer";
    const statusLabel = document.createElement("b");
    statusLabel.textContent = skill.enabled ? "运行中" : skill.installed ? "已停用" : "查看权限";
    const open = document.createElement("button");
    open.type = "button";
    open.textContent = skill.installed ? "管理 →" : "详情 →";
    open.addEventListener("click", () => openSkillDrawer(skill.skill_id));
    footer.append(statusLabel, open);
    card.append(top, identity, description, capabilities, footer);
    elements.skillGrid.append(card);
  });
}

const skillActionLabels = {
  install: "安装并授权",
  enable: "启用",
  disable: "停用",
  upgrade: "升级版本",
  uninstall: "卸载",
  run: "Agent 调用",
};

async function loadSkillAudit() {
  try {
    const entries = await api("/api/v1/skills/audit");
    elements.skillAuditList.replaceChildren();
    if (!entries.length) {
      elements.skillAuditList.innerHTML = '<div class="skill-library-empty">安装或运行 Skill 后，活动会显示在这里。</div>';
      return;
    }
    entries.slice(0, 8).forEach((entry) => {
      const item = document.createElement("article");
      const mark = document.createElement("i");
      mark.textContent = entry.action === "run" ? "↗" : "✓";
      const content = document.createElement("div");
      const title = document.createElement("b");
      title.textContent = `${skillActionLabels[entry.action] ?? entry.action} · ${entry.skill_name}`;
      const meta = document.createElement("span");
      meta.textContent = new Date(entry.created_at).toLocaleString("zh-CN", { month: "numeric", day: "numeric", hour: "2-digit", minute: "2-digit" });
      content.append(title, meta);
      item.append(mark, content);
      elements.skillAuditList.append(item);
    });
  } catch (error) {
    elements.skillAuditList.innerHTML = '<div class="skill-library-empty">活动记录读取失败</div>';
    showToast(error.message, "error");
  }
}

async function loadSkills() {
  elements.skillGrid.innerHTML = '<div class="skill-library-empty">正在连接官方 Skills 库…</div>';
  try {
    state.skills = await api("/api/v1/skills");
    renderSkillLibrary();
    await loadSkillAudit();
  } catch (error) {
    elements.skillGrid.innerHTML = '<div class="skill-library-empty"><b>Skills 库暂时不可用</b><span>请稍后重试。</span></div>';
    showToast(error.message, "error");
  }
}

function updateSkillInstallReady() {
  const checkboxes = [...elements.skillDrawerPermissions.querySelectorAll('input[type="checkbox"]')];
  const ready = checkboxes.length > 0 && checkboxes.every((checkbox) => checkbox.checked);
  elements.skillInstallButton.disabled = !ready;
  elements.skillInstallNote.textContent = ready ? "权限已确认，可以安全安装" : "请确认全部权限后安装";
  elements.skillInstallNote.classList.toggle("ready", ready);
}

function renderSkillDrawer(skill) {
  state.selectedSkill = skill;
  elements.skillDrawerCategory.textContent = `${skill.category} · OFFICIAL`;
  elements.skillDrawerVersion.textContent = `VERSION ${skill.version}`;
  elements.skillDrawerSymbol.textContent = skillSymbol(skill);
  elements.skillDrawerName.textContent = skill.name;
  elements.skillDrawerAuthor.textContent = `${skill.author} · 已验证发布者`;
  elements.skillDrawerDescription.textContent = skill.description;
  elements.skillDrawerCapabilities.replaceChildren();
  skill.capabilities.forEach((capability) => {
    const item = document.createElement("span");
    item.textContent = capability;
    elements.skillDrawerCapabilities.append(item);
  });
  elements.skillDrawerPermissions.replaceChildren();
  skill.permissions.forEach((permission) => {
    const label = document.createElement("label");
    label.className = `skill-permission ${permission.access}`;
    const checkbox = document.createElement("input");
    checkbox.type = "checkbox";
    checkbox.value = permission.code;
    checkbox.checked = skill.installed;
    checkbox.disabled = skill.installed;
    checkbox.addEventListener("change", updateSkillInstallReady);
    const content = document.createElement("span");
    const heading = document.createElement("b");
    heading.textContent = permission.label;
    const detail = document.createElement("small");
    detail.textContent = permission.description;
    const access = document.createElement("i");
    access.textContent = permission.access === "write" ? "提案写入" : "只读";
    content.append(heading, detail);
    label.append(checkbox, content, access);
    elements.skillDrawerPermissions.append(label);
  });
  elements.skillInstallButton.hidden = skill.installed;
  elements.skillToggleButton.hidden = !skill.installed;
  elements.skillUninstallButton.hidden = !skill.installed;
  elements.skillUpgradeButton.hidden = !skill.update_available;
  elements.skillToggleButton.textContent = skill.enabled ? "停用 Skill" : "重新启用";
  elements.skillInstallNote.hidden = skill.installed;
  if (!skill.installed) updateSkillInstallReady();
}

async function openSkillDrawer(skillId) {
  try {
    const skill = await api(`/api/v1/skills/${encodeURIComponent(skillId)}`);
    renderSkillDrawer(skill);
    elements.skillDrawer.hidden = false;
    elements.skillScrim.hidden = false;
    requestAnimationFrame(() => elements.skillDrawer.classList.add("open"));
  } catch (error) {
    showToast(error.message, "error");
  }
}

function closeSkillDrawer() {
  elements.skillDrawer.classList.remove("open");
  elements.skillDrawer.hidden = true;
  elements.skillScrim.hidden = true;
  state.selectedSkill = null;
}

async function refreshSelectedSkill(message) {
  const skillId = state.selectedSkill.skill_id;
  state.skills = await api("/api/v1/skills");
  renderSkillLibrary();
  renderSkillDrawer(await api(`/api/v1/skills/${encodeURIComponent(skillId)}`));
  await loadSkillAudit();
  showToast(message);
}

async function installSelectedSkill() {
  const skill = state.selectedSkill;
  if (!skill) return;
  const accepted = [...elements.skillDrawerPermissions.querySelectorAll('input[type="checkbox"]:checked')]
    .map((checkbox) => checkbox.value);
  elements.skillInstallButton.disabled = true;
  try {
    await api(`/api/v1/skills/${encodeURIComponent(skill.skill_id)}/install`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ accepted_permissions: accepted }),
    });
    await refreshSelectedSkill(`${skill.name} 已安装并启用`);
  } catch (error) {
    updateSkillInstallReady();
    showToast(error.message, "error");
  }
}

async function toggleSelectedSkill() {
  const skill = state.selectedSkill;
  if (!skill) return;
  elements.skillToggleButton.disabled = true;
  try {
    await api(`/api/v1/skills/${encodeURIComponent(skill.skill_id)}`, {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ enabled: !skill.enabled }),
    });
    await refreshSelectedSkill(skill.enabled ? `${skill.name} 已停用` : `${skill.name} 已启用`);
  } catch (error) {
    showToast(error.message, "error");
  } finally {
    elements.skillToggleButton.disabled = false;
  }
}

async function upgradeSelectedSkill() {
  const skill = state.selectedSkill;
  if (!skill) return;
  try {
    await api(`/api/v1/skills/${encodeURIComponent(skill.skill_id)}/upgrade`, { method: "POST" });
    await refreshSelectedSkill(`${skill.name} 已升级到最新版本`);
  } catch (error) {
    showToast(error.message, "error");
  }
}

async function uninstallSelectedSkill() {
  const skill = state.selectedSkill;
  if (!skill || !globalThis.confirm(`确定卸载“${skill.name}”吗？历史审计记录会保留。`)) return;
  try {
    await api(`/api/v1/skills/${encodeURIComponent(skill.skill_id)}`, { method: "DELETE" });
    closeSkillDrawer();
    await loadSkills();
    showToast(`${skill.name} 已卸载`);
  } catch (error) {
    showToast(error.message, "error");
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
  meta.textContent = role === "user" ? "你" : "助手";
  const bubble = document.createElement("div");
  bubble.className = "bubble";
  if (options.loading) {
    const typing = document.createElement("span");
    typing.className = "typing";
    for (let index = 0; index < 3; index += 1) typing.append(document.createElement("span"));
    bubble.append(typing);
  } else if (role === "assistant" && window.CampusFlowMarkdown) {
    window.CampusFlowMarkdown.render(bubble, content);
  } else {
    bubble.textContent = content;
  }
  article.append(meta, bubble);
  elements.messages.append(article);
  scrollMessages();
  return article;
}

function campusRouteMapAllowed() {
  const normalize = (value) => String(value ?? "").toLowerCase().replace(/\s/g, "");
  return ["杭州电子科技大学", "杭电", "hdu"].includes(normalize(state.user?.school)) &&
    ["下沙", "下沙校区", "xiasha"].includes(normalize(state.user?.campus));
}

const campusMapDocument = "/static/baidu-map.html?v=3&managed=1";
const campusRouteMaps = new Map();
const campusMapBindings = new WeakMap();
let campusMapOwner = {key: "", request: null};

function clearCampusMapConfig(owner) {
  owner.request?.controller.abort();
  owner.request = null;
}

function currentCampusMapOwner() {
  const key = state.user?.user_id
    ? JSON.stringify([globalThis.location.origin, globalThis.location.pathname, state.user.user_id]) : "";
  if (campusMapOwner.key !== key) {
    clearCampusMapConfig(campusMapOwner);
    campusMapOwner = {key, request: null};
  }
  return campusMapOwner;
}

async function fetchCampusMapConfig(owner, request) {
  const options = {cache: "no-store", signal: request.controller.signal};
  let value;
  try {
    value = await api("/api/v1/me/baidu-maps/config", options);
  } catch (error) {
    if (error.status !== 404 || currentCampusMapOwner() !== owner || owner.request !== request) throw error;
    value = await api("/api/v1/maps/baidu/config", options);
  }
  if (typeof value?.configured !== "boolean" || typeof value.route_configured !== "boolean" ||
    typeof value.campus_query !== "string" || typeof value.city !== "string" ||
    (value.configured && (typeof value.browser_ak !== "string" || !value.browser_ak.trim()))) {
    throw new Error("invalid-campus-map-config");
  }
  return {configured: value.configured, browser_ak: value.configured ? value.browser_ak : "",
    route_configured: value.route_configured, campus_query: value.campus_query, city: value.city};
}

function campusMapConfigRequest(owner) {
  if (owner.request) return owner.request;
  const request = {controller: new AbortController(), promise: null};
  owner.request = request;
  request.promise = fetchCampusMapConfig(owner, request).catch(error => {
    if (owner.request === request) owner.request = null;
    throw error;
  });
  return request;
}

function campusMapBridge(frame) {
  try {
    const child = frame.contentWindow;
    const expected = new URL(campusMapDocument, globalThis.location.origin).href;
    return child?.location.href === expected ? child.CampusFlowMap : null;
  } catch {
    return null;
  }
}

function clearManagedCampusMap(frame) {
  try { campusMapBridge(frame)?.clear(); } catch { /* A detached frame has no active map. */ }
  campusMapBindings.get(frame)?.feedback?.remove();
  campusMapBindings.delete(frame);
  frame.remove();
}

function campusMapLoadFailed(frame, binding, retry) {
  if (binding.feedback) return;
  const feedback = document.createElement("p");
  feedback.className = "campus-route-summary";
  feedback.setAttribute("role", "status");
  feedback.textContent = "暂时无法加载地图配置。";
  const button = document.createElement("button");
  button.type = "button";
  button.className = "line-button";
  button.textContent = "重试加载地图";
  button.addEventListener("click", retry);
  feedback.append(" ", button);
  binding.feedback = feedback;
  frame.hidden = true;
  frame.after(feedback);
}

function setManagedCampusMapState(frame, canActivate, mapState) {
  const bridge = campusMapBridge(frame);
  const owner = currentCampusMapOwner();
  if (!owner.key || !canActivate() || typeof bridge?.setConfig !== "function") return;
  const request = campusMapConfigRequest(owner);
  const binding = campusMapBindings.get(frame) ?? {feedback: null};
  if (binding.bridge === bridge && binding.request === request) {
    if (binding.ready) bridge.setState(mapState);
    return;
  }
  Object.assign(binding, {bridge, request, ready: false});
  campusMapBindings.set(frame, binding);
  const current = () => frame.isConnected && currentCampusMapOwner() === owner && canActivate() &&
    campusMapBindings.get(frame) === binding && binding.request === request && campusMapBridge(frame) === bridge;
  void (async () => {
    try {
      const config = await request.promise;
      if (!current() || owner.request !== request) return;
      bridge.setConfig(config);
      bridge.setState(mapState);
      binding.ready = true;
      binding.feedback?.remove();
      binding.feedback = null;
      frame.hidden = false;
    } catch {
      if (current()) campusMapLoadFailed(frame, binding, () => setManagedCampusMapState(frame, canActivate, mapState));
    } finally {
      if (binding.request === request && !binding.ready) binding.request = null;
    }
  })();
}

function syncCampusRouteMaps() {
  const owner = currentCampusMapOwner();
  for (const [frame, entry] of campusRouteMaps) {
    try {
      if (!frame.isConnected || entry.owner !== owner || !campusRouteMapAllowed()) {
        clearManagedCampusMap(frame);
        campusRouteMaps.delete(frame);
        continue;
      }
      const active = () => !document.hidden && !elements.appView.hidden && state.appTab === "agent" &&
        campusRouteMaps.get(frame) === entry && campusRouteMapAllowed();
      if (active()) setManagedCampusMapState(frame, active, {active: true,
        route: entry.route, origin: entry.route.origin, destination: entry.route.destination});
      else campusMapBridge(frame)?.setState({active: false, route: null, origin: null, destination: null});
    } catch {
      // The iframe is fixed to our same-origin static page; an unavailable bridge can retry on load.
    }
  }
}

function clearCampusRouteMaps() {
  for (const frame of campusRouteMaps.keys()) clearManagedCampusMap(frame);
  campusRouteMaps.clear();
}

document.addEventListener("visibilitychange", syncCampusRouteMaps);
window.addEventListener("pagehide", () => {
  clearCampusMapConfig(currentCampusMapOwner());
  clearCampusRouteMaps();
});

function createManagedCampusMap(title) {
  const frame = document.createElement("iframe");
  frame.className = "campus-baidu-map";
  frame.title = title;
  frame.src = campusMapDocument;
  frame.setAttribute("allow", "geolocation 'none'");
  frame.referrerPolicy = "strict-origin-when-cross-origin";
  return frame;
}

function buildCampusRouteMap(route) {
  const frame = createManagedCampusMap("百度校园步行路线地图");
  frame.loading = "lazy";
  // The renderer needs geometry and endpoint identifiers, not account selection or evidence records.
  const point = value => ({lat: value?.lat, lng: value?.lng});
  const endpoint = place => ({place_id: place.place_id, location: point(place.location)});
  campusRouteMaps.set(frame, {owner: currentCampusMapOwner(), route: {
    provider: route.provider,
    coordinate_system: route.coordinate_system,
    origin: endpoint(route.origin),
    destination: endpoint(route.destination),
    polyline: Array.isArray(route.polyline) ? route.polyline.map(point) : [],
  }});
  frame.addEventListener("load", syncCampusRouteMaps);
  return frame;
}

function rebuildCampusRouteMaps(owner) {
  for (const [frame, entry] of [...campusRouteMaps]) {
    if (frame.isConnected && entry.owner === owner && campusRouteMapAllowed()) {
      frame.before(buildCampusRouteMap(entry.route));
    }
    clearManagedCampusMap(frame);
    campusRouteMaps.delete(frame);
  }
}

function campusPlaceDisplayName(place) {
  // The campus reference list keeps the familiar campus name as its first alias.
  const shortName = Array.isArray(place.aliases) ? place.aliases[0] : undefined;
  return typeof shortName === "string" && shortName.trim() ? shortName : place.name;
}

function renderCampusRoute(route, context = null, container = elements.messages) {
  if (context && (context.owner !== state.user?.user_id || context.sessionId !== state.sessionId)) return;
  if (!route?.origin || !route.destination) return;
  const realRoute = route.provider === "baidu" && route.coordinate_system === "bd09ll";
  clearEmptyState();
  const card = document.createElement("article");
  card.className = "campus-route-card";

  const head = document.createElement("div");
  head.className = "campus-route-head";
  const titleWrap = document.createElement("div");
  const eyebrow = document.createElement("span");
  eyebrow.textContent = realRoute ? "BAIDU MAP / 步行路线" : "CAMPUS ROUTE / 历史摘要";
  const title = document.createElement("h3");
  const originName = realRoute ? campusPlaceDisplayName(route.origin) : route.origin.name;
  const destinationName = realRoute ? campusPlaceDisplayName(route.destination) : route.destination.name;
  title.textContent = `${originName} → ${destinationName}`;
  titleWrap.append(eyebrow, title);
  const mode = document.createElement("b");
  mode.textContent = "步行";
  head.append(titleWrap, mode);

  const metrics = document.createElement("div");
  metrics.className = "campus-route-metrics";
  const openNow = route.destination.open_now;
  const openingStatus = typeof openNow === "boolean" ? (openNow ? "开放记录" : "关闭记录") : "状态未知";
  [
    [`${route.total_minutes}`, "分钟"],
    [`${realRoute ? route.distance_meters ?? "—" : route.estimated_distance_meters ?? "—"}`, realRoute ? "米 / 百度预计" : "米 / 历史估算"],
    [openingStatus, route.destination.open_hours || "开放时间未提供"],
  ].forEach(([value, label]) => {
    const item = document.createElement("div");
    const strong = document.createElement("strong");
    strong.textContent = value;
    const span = document.createElement("span");
    span.textContent = label;
    item.append(strong, span);
    metrics.append(item);
  });

  const map = document.createElement("div");
  map.className = "campus-route-map";
  if (realRoute && campusRouteMapAllowed()) map.append(buildCampusRouteMap(route));
  else {
    const summary = document.createElement("p");
    summary.className = "campus-route-summary";
    summary.textContent = realRoute ? "当前账号学校或校区不支持此校园地图。" : "历史路线仅保留文本摘要，请重新规划以获取百度步行路线。";
    map.append(summary);
  }

  const steps = document.createElement("ol");
  steps.className = "campus-route-steps";
  (route.steps ?? []).forEach((step) => {
    const item = document.createElement("li");
    const number = document.createElement("i");
    number.textContent = String(step.index).padStart(2, "0");
    const copy = document.createElement("span");
    copy.textContent = step.instruction;
    const minutes = document.createElement("b");
    minutes.textContent = `${step.minutes} min`;
    item.append(number, copy, minutes);
    steps.append(item);
  });

  const note = document.createElement("p");
  note.className = "campus-route-note";
  note.textContent = realRoute ? `百度地图预计步行路线，实际通行以现场情况为准。${route.note ?? ""}` : route.note ?? "历史路线数据";
  card.append(head, metrics, map, steps, note);
  container.append(card);
  if (container === elements.messages) scrollMessages();
}

const replyToolStates = new Map([
  ["success", "已完成"], ["empty", "暂无结果"], ["error", "查询失败"],
  ["unavailable", "暂不可用"], ["pending", "待确认"], ["unverified", "未核验"], ["demo", "演示数据"],
]);
const replyEvidenceStates = new Map([
  ["fresh", "记录有效"], ["stale", "已过期"], ["unverified", "未核验"],
  ["missing", "暂无数据"], ["error", "读取失败"], ["demo", "演示数据"],
]);
const replyEvidenceTimeFormat = new Intl.DateTimeFormat("zh-CN", {
  dateStyle: "medium", timeStyle: "short", timeZone: "Asia/Shanghai",
});
let openReplyDetails = null;

function isCurrentReplyContext(context) {
  return context.owner === state.user?.user_id && context.sessionId === state.sessionId;
}

function closeReplyDetails() {
  if (openReplyDetails?.open) openReplyDetails.close();
}

function replyEvidenceTimestamp(value) {
  if (typeof value !== "string" || !/^(\d{4}-\d{2}-\d{2})T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$/.test(value)) return NaN;
  const date = value.slice(0, 10);
  const day = new Date(`${date}T00:00:00Z`);
  if (!Number.isFinite(day.valueOf()) || day.toISOString().slice(0, 10) !== date || value.slice(11, 13) === "24") return NaN;
  return Date.parse(value);
}

function replyEvidenceStatus(evidence, updated, expires, now) {
  if (evidence.kind === "demo") return "demo";
  if (evidence.status !== "fresh") return replyEvidenceStates.has(evidence.status) ? evidence.status : "unverified";
  if (!Number.isFinite(updated) || updated > now + 300000) return "unverified";
  if (evidence.expires_at != null && (!Number.isFinite(expires) || expires <= updated)) return "unverified";
  return expires <= now ? "stale" : "fresh";
}

function buildReplyTool(display) {
  const verified = typeof display?.label === "string" && display.label.trim() &&
    typeof display.summary === "string" && display.summary.trim() && replyToolStates.has(display.state);
  const item = document.createElement("li");
  const heading = document.createElement("div");
  heading.className = "reply-tool-heading";
  const name = document.createElement("h3");
  name.textContent = verified ? display.label : "工具调用";
  const status = document.createElement("span");
  status.textContent = replyToolStates.get(verified ? display.state : "unverified");
  heading.append(name, status);
  const summary = document.createElement("p");
  summary.textContent = verified ? display.summary : "服务未提供可核验的工具摘要。";
  item.append(heading, summary);
  if (verified && Array.isArray(display.evidence)) {
    const sources = document.createElement("ul");
    sources.className = "reply-tool-sources";
    sources.setAttribute("aria-label", "数据来源");
    for (const evidence of display.evidence) {
      if (typeof evidence?.label !== "string" || !evidence.label.trim()) continue;
      const source = document.createElement("li");
      const label = document.createElement("strong");
      label.textContent = evidence.label;
      const details = document.createElement("span");
      const updated = replyEvidenceTimestamp(evidence.updated_at);
      const expires = replyEvidenceTimestamp(evidence.expires_at);
      details.textContent = [
        replyEvidenceStates.get(replyEvidenceStatus(evidence, updated, expires, Date.now())),
        Number.isFinite(updated) ? `记录于 ${replyEvidenceTimeFormat.format(updated)}（上海）` : "",
      ].filter(Boolean).join(" · ");
      source.append(label);
      if (details.textContent) source.append(details);
      if (typeof evidence.note === "string" && evidence.note.trim()) {
        const note = document.createElement("p");
        note.textContent = evidence.note;
        source.append(note);
      }
      sources.append(source);
    }
    if (sources.childElementCount) item.append(sources);
  }
  return item;
}

function appendReplyDetails(message, context, tools, routes = []) {
  if (!Array.isArray(tools) || !tools.length) return;
  const button = document.createElement("button");
  button.type = "button";
  button.className = "chat-small-button reply-details-button";
  button.setAttribute("aria-haspopup", "dialog");
  const title = routes.length ? "步行路线与来源" : "工具与来源";
  button.textContent = `${title} · ${tools.length} 项`;
  button.addEventListener("click", () => {
    if (!message.isConnected || !isCurrentReplyContext(context) || openReplyDetails?.open) return;
    const dialog = document.createElement("dialog");
    dialog.className = "chat-dialog";
    dialog.setAttribute("aria-label", title);
    const header = document.createElement("div");
    header.className = "chat-dialog-heading";
    const heading = document.createElement("h2");
    heading.textContent = title;
    const close = document.createElement("button");
    close.type = "button";
    close.className = "chat-small-button";
    close.textContent = "关闭";
    close.autofocus = true;
    close.addEventListener("click", closeReplyDetails);
    header.append(heading, close);
    const content = document.createElement("div");
    content.className = "chat-dialog-content";
    const list = document.createElement("ol");
    list.className = "reply-tool-list";
    list.append(...tools.map(buildReplyTool));
    dialog.append(header, content);
    document.body.append(dialog);
    for (const route of routes) renderCampusRoute(route, context, content);
    content.append(list);
    openReplyDetails = dialog;
    dialog.addEventListener("close", () => {
      dialog.remove();
      for (const frame of dialog.querySelectorAll("iframe.campus-baidu-map")) {
        clearManagedCampusMap(frame);
        campusRouteMaps.delete(frame);
      }
      if (openReplyDetails === dialog) openReplyDetails = null;
      if (button.isConnected && isCurrentReplyContext(context)) button.focus();
    }, {once: true});
    dialog.showModal();
  });
  message.append(button);
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

function renderPendingAction(action, message) {
  const card = document.createElement("section");
  card.className = "action-card";
  const label = document.createElement("div");
  label.className = "action-label";
  label.textContent = action.kind === "plan" ? "待确认计划" : "待确认操作";
  const title = document.createElement("h3");
  title.textContent = action.title;
  const description = document.createElement("p");
  description.textContent = actionDescription(action);
  description.style.color = "var(--cf-muted, #626e65)";
  const button = document.createElement("button");
  button.type = "button";
  button.textContent = "确认执行此操作";
  Object.assign(button.style, { minHeight: "44px", fontSize: "14px", color: "white",
    background: "var(--cf-accent, #416454)" });
  button.addEventListener("click", () => confirmAction(action.proposal_id, card, button, label));
  card.append(label, title, description, button);
  message.querySelector(".bubble").append(card);
}

async function confirmAction(proposalId, card, button, label) {
  button.disabled = true;
  button.textContent = "正在确认…";
  try {
    const payload = await api(`/api/v1/actions/${encodeURIComponent(proposalId)}/confirm`, { method: "POST" });
    card.classList.add("confirmed");
    label.textContent = "已写入";
    button.textContent = "已确认";
    showToast(payload.message || "操作已确认");
    await loadPlans();
  } catch (error) {
    button.disabled = false;
    button.textContent = "重新确认";
    showToast(error.message, "error");
  }
}

function upsertSession(session) {
  const index = state.sessions.findIndex((item) => item.session_id === session.session_id);
  if (index >= 0) {
    state.sessions[index] = { ...state.sessions[index], ...session };
  } else {
    state.sessions = [session, ...state.sessions];
  }
  elements.todayHistoryCount.textContent = state.sessions.length;
  if (!elements.historyDrawer.hidden) renderHistorySessions(state.sessions);
}

async function refreshSessions() {
  try {
    state.sessions = await api("/api/v1/sessions");
    elements.todayHistoryCount.textContent = state.sessions.length;
    if (!elements.historyDrawer.hidden) renderHistorySessions(state.sessions);
  } catch {
    // 保留本地占位会话，避免进行中的对话从历史目录里消失。
  }
}

async function sendMessage(message) {
  if (!message || state.sending) return;
  const routeContext = {owner: state.user?.user_id, sessionId: state.sessionId};
  state.sending = true;
  elements.sendButton.disabled = true;
  elements.messageInput.disabled = true;
  appendMessage("user", message);
  // 提问后立即写入本地会话目录：模型思考期间打开历史也能看到本次对话。
  const pendingAt = new Date().toISOString();
  upsertSession({
    session_id: state.sessionId,
    title: message.slice(0, 18),
    model_name: selectedModel(),
    last_message: message,
    message_count: 1,
    created_at: pendingAt,
    updated_at: pendingAt,
    status: "pending",
  });
  const loading = appendMessage("assistant", "", { loading: true });
  try {
    const payload = await api("/api/v1/chat", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        session_id: routeContext.sessionId,
        model: selectedModel(),
        message,
      }),
    });
    loading.remove();
    if (!isCurrentReplyContext(routeContext)) return;
    const response = appendMessage("assistant", payload.message);
    payload.pending_actions?.forEach((action) => renderPendingAction(action, response));
    const traces = Array.isArray(payload.tool_traces) ? payload.tool_traces : [];
    const routes = traces.filter((trace) => trace?.tool_name === "plan_campus_route" && trace.result?.origin && trace.result.destination)
      .map((trace) => trace.result);
    appendReplyDetails(response, routeContext, traces.map((trace) => trace?.display), routes);
    scrollMessages();
    setServiceState(true, "Agent 服务在线");
  } catch (error) {
    loading.remove();
    if (!isCurrentReplyContext(routeContext)) return;
    appendMessage("assistant", `本次任务未完成：${error.message}`);
    showToast(error.message, "error");
  } finally {
    // 以服务端状态覆盖占位会话；此处该会话应已被标记为完成。
    if (state.user?.user_id === routeContext.owner) await refreshSessions();
    state.sending = false;
    elements.sendButton.disabled = false;
    elements.messageInput.disabled = false;
    if (isCurrentReplyContext(routeContext)) elements.messageInput.value = "";
    resizeComposer();
    if (isCurrentReplyContext(routeContext) && state.appTab === "agent") elements.messageInput.focus();
  }
}

function resizeComposer() {
  elements.messageInput.style.height = "auto";
  elements.messageInput.style.height = `${Math.min(elements.messageInput.scrollHeight, 140)}px`;
}

function resetSession(notify = true) {
  closeReplyDetails();
  clearCampusRouteMaps();
  state.sessionId = createSessionId();
  syncCampusPlaceSelection();
  setSessionId();
  elements.messages.innerHTML = '<div class="empty-state chat-empty-state" id="emptyState"><h3>开始新对话</h3><p>可以问课表、校园地点，或请助手帮你做计划。</p></div>';
  elements.emptyState = $("#emptyState");
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
  state.historyReadRevision++;
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
    const pendingLabel = session.status === "pending" ? " · 思考中…" : "";
    meta.textContent = `${session.message_count} 条消息 · ${session.model_name === "deepseek-flash" ? "FLASH" : "V4 PRO"}${pendingLabel}`;
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
  const context = {owner: state.user?.user_id, sessionId};
  const revision = ++state.historyReadRevision;
  try {
    const history = await api(`/api/v1/sessions/${encodeURIComponent(sessionId)}/history`);
    if (context.owner !== state.user?.user_id || revision !== state.historyReadRevision) return;
    closeReplyDetails();
    const session = state.sessions.find((item) => item.session_id === sessionId);
    state.sessionId = sessionId;
    syncCampusPlaceSelection();
    if (session?.model_name) {
      const modelInput = $(`input[name="model"][value="${session.model_name}"]`);
      if (modelInput) modelInput.checked = true;
      elements.modelBadge.textContent = modelLabel(session.model_name);
    }
    setSessionId();
    clearCampusRouteMaps();
    elements.messages.replaceChildren();
    for (const message of history) {
      const article = appendMessage(message.role, message.content);
      if (message.role === "assistant") appendReplyDetails(article, context, message.tools);
    }
    scrollMessages();
    closeHistory();
    switchAppTab("agent");
    showToast(`已恢复 ${history.length} 条消息`);
  } catch (error) {
    if (context.owner === state.user?.user_id && revision === state.historyReadRevision) {
      showToast(error.message, "error");
    }
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

let baiduMapSettingsView = null;
let baiduMapSettingsSave = null;

function baiduMapKeySources(payload) {
  const readSource = value => {
    if (value?.configured === false && value.source === "none") return "none";
    if (value?.configured === true && ["account", "server"].includes(value.source)) return value.source;
    throw new Error("invalid-baidu-map-key-status");
  };
  return {browser: readSource(payload?.browser), server: readSource(payload?.server)};
}

function renderBaiduMapSettings(view, message = "") {
  const busy = !!view && baiduMapSettingsSave?.owner === view.owner;
  const sources = view?.sources;
  const labels = {account: "正在使用个人配置", server: "正在使用服务器配置", none: "尚未配置"};
  elements.baiduBrowserStatus.textContent = labels[sources?.browser] ?? "";
  elements.baiduServerStatus.textContent = labels[sources?.server] ?? "";
  elements.clearBaiduBrowserAk.hidden = sources?.browser !== "account";
  elements.clearBaiduServerAk.hidden = sources?.server !== "account";
  elements.baiduBrowserAk.disabled = elements.baiduServerAk.disabled = busy || !sources;
  elements.clearBaiduBrowserAk.disabled = elements.clearBaiduServerAk.disabled = busy || !sources;
  setButtonBusy(elements.saveBaiduMapSettings, busy, "正在保存…");
  elements.saveBaiduMapSettings.disabled = busy || !sources;
  elements.baiduMapSettingsStatus.textContent = message;
}

function clearBaiduMapSettingsView() {
  baiduMapSettingsView?.controller.abort();
  baiduMapSettingsView = null;
  elements.baiduMapSettingsForm.reset();
  renderBaiduMapSettings(null);
}

async function loadBaiduMapSettings(view) {
  const pending = baiduMapSettingsSave;
  if (pending?.owner === view.owner) await pending.promise.catch(() => {});
  if (baiduMapSettingsView !== view || currentCampusMapOwner() !== view.owner) return;
  try {
    const result = await api("/api/v1/me/baidu-maps", {cache: "no-store", signal: view.controller.signal});
    if (baiduMapSettingsView !== view || currentCampusMapOwner() !== view.owner) return;
    view.sources = baiduMapKeySources(result);
    renderBaiduMapSettings(view);
  } catch (error) {
    if (baiduMapSettingsView !== view || currentCampusMapOwner() !== view.owner) return;
    renderBaiduMapSettings(view, error.status === 404 ? "此服务器暂不支持个人地图配置。" :
      "暂时无法读取地图配置，请重新打开个人配置后重试。");
  }
}

function syncBaiduMapSettings() {
  const owner = state.user?.user_id && !document.hidden && !elements.settingsView.hidden && state.settingsTab === "profile"
    ? currentCampusMapOwner() : null;
  if ((baiduMapSettingsView?.owner ?? null) === owner) return;
  clearBaiduMapSettingsView();
  if (!owner) return;
  const view = {owner, controller: new AbortController(), sources: null};
  baiduMapSettingsView = view;
  renderBaiduMapSettings(view, "正在读取地图配置…");
  void loadBaiduMapSettings(view);
}

async function updateBaiduMapSettings(payload) {
  const view = baiduMapSettingsView;
  const owner = currentCampusMapOwner();
  if (!view?.sources || view.owner !== owner || baiduMapSettingsSave?.owner === owner) return;
  if (!Object.keys(payload).length) {
    renderBaiduMapSettings(view, "请输入要更新的 AK。");
    return;
  }
  elements.baiduMapSettingsForm.reset();
  const operation = {owner, promise: api("/api/v1/me/baidu-maps", {
    method: "PUT", headers: {"Content-Type": "application/json"}, cache: "no-store", body: JSON.stringify(payload),
  })};
  baiduMapSettingsSave = operation;
  renderBaiduMapSettings(view, "正在保存地图配置…");
  let sources;
  let message;
  try {
    const result = await operation.promise;
    if (baiduMapSettingsSave !== operation || currentCampusMapOwner() !== owner) return;
    clearCampusMapConfig(owner);
    clearCampusPlaceCandidates();
    updateCampusPlaceControls();
    rebuildCampusRouteMaps(owner);
    sources = baiduMapKeySources(result);
    message = "地图配置已更新。";
  } catch {
    message = "地图配置保存失败，请重试。";
  } finally {
    if (baiduMapSettingsSave === operation) baiduMapSettingsSave = null;
    if (baiduMapSettingsView?.owner === owner && currentCampusMapOwner() === owner) {
      if (sources) baiduMapSettingsView.sources = sources;
      renderBaiduMapSettings(baiduMapSettingsView, message);
    }
  }
}

document.addEventListener("visibilitychange", syncBaiduMapSettings);
window.addEventListener("pagehide", clearBaiduMapSettingsView);

function switchSettingsTab(tab) {
  state.settingsTab = tab;
  $$('[data-settings-tab]').forEach((button) => {
    button.classList.toggle("active", button.dataset.settingsTab === tab);
  });
  $$('[data-settings-panel]').forEach((panel) => {
    panel.hidden = panel.dataset.settingsPanel !== tab;
  });
  syncCampusPlaceSelection();
  syncBaiduMapSettings();
  if (tab === "data") loadSettingsContext();
  if (tab === "admin") loadAdminUsers();
}

function openSettings() {
  window.CampusFlowTheme?.refreshControls();
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

function renderScheduleSubscriptionStatus(status) {
  state.scheduleSubscription = status;
  elements.syncSubscriptionButton.hidden = !status.configured;
  elements.disconnectSubscriptionButton.hidden = !status.configured;
  if (!status.configured) {
    elements.scheduleSubscriptionState.textContent = "连接订阅后，可随时从 HDUHelp 拉取最新课程。完整链接只会加密保存。";
    return;
  }
  const syncedAt = status.last_synced_at
    ? new Date(status.last_synced_at).toLocaleString("zh-CN", {
        month: "numeric",
        day: "numeric",
        hour: "2-digit",
        minute: "2-digit",
      })
    : "尚未同步";
  elements.scheduleSubscriptionState.textContent = `已安全连接 ${status.source_host} · ${status.event_count} 条课程 · 最近同步 ${syncedAt}`;
}

const hduHelpResourceLabels = {
  identity: "账户身份",
  person: "本人学籍",
  grades: "成绩 / GPA",
  exams: "考试安排",
  card_balance: "校园卡余额",
  library_bookings: "图书馆预约",
  library_attendance: "图书馆到馆",
  library_reading: "图书馆借阅",
  library_seat_reservations: "图书馆座位",
  sunrun_overview: "阳光长跑",
  sunrun_group: "长跑分组",
  sunrun_detail: "长跑记录",
  subscriptions: "校园提醒订阅",
};

function renderHduHelpStatus(status) {
  state.hduHelp = status;
  const connected = Boolean(status.configured);
  const expired = status.connection_state === "auth_invalid";
  elements.connectHduHelpButton.hidden = connected && !expired;
  elements.hduHelpPatForm.hidden = connected && !expired;
  elements.viewHduHelpDataButton.hidden = !connected;
  elements.syncHduHelpButton.hidden = !connected || expired;
  elements.disconnectHduHelpButton.hidden = !connected;
  elements.hduHelpResourceList.replaceChildren();
  if (!connected) {
    elements.hduHelpDataPanel.hidden = true;
    elements.hduHelpConnectionState.textContent = "填写个人访问令牌即可同步；令牌仅加密保存，不会提交杭电密码。";
    ["学籍", "成绩 / GPA", "考试", "校园卡", "图书馆预约"].forEach((label) => {
      const chip = document.createElement("span");
      chip.textContent = label;
      elements.hduHelpResourceList.append(chip);
    });
    return;
  }
  const syncedAt = status.last_synced_at
    ? new Date(status.last_synced_at).toLocaleString("zh-CN", {
        month: "numeric", day: "numeric", hour: "2-digit", minute: "2-digit",
      })
    : "尚未同步";
  const identity = status.external_name ? ` · ${status.external_name}` : "";
  const credential = status.auth_mode === "pat"
    ? `个人令牌 ${status.token_hint ?? "已配置"}`
    : "官方 OAuth";
  elements.hduHelpConnectionState.textContent =
    `${credential}${identity} · ${expired ? "授权已失效 · " : ""}最近成功同步 ${syncedAt}`;
  const resources = status.resources?.length ? status.resources : Object.keys(hduHelpResourceLabels);
  resources.forEach((resource) => {
    const chip = document.createElement("span");
    chip.textContent = hduHelpResourceLabels[resource] ?? resource;
    chip.classList.toggle("ready", status.resources?.includes(resource));
    elements.hduHelpResourceList.append(chip);
  });
  if (status.last_error) {
    const chip = document.createElement("span");
    chip.className = "warning";
    chip.textContent = expired ? "请重新连接" : "部分数据待重试";
    elements.hduHelpResourceList.append(chip);
  }
}

let hduHelpResourceRefreshing = false;

function appendHduHelpDataStatus(card, resource, dataStatus) {
  if (!dataStatus) return;
  const note = document.createElement("p");
  const updated = dataStatus.updated_at
    ? ` · 最近获取 ${new Date(dataStatus.updated_at).toLocaleString("zh-CN", {
        timeZone: "Asia/Shanghai", month: "numeric", day: "numeric", hour: "2-digit", minute: "2-digit",
      })}`
    : "";
  note.textContent = `${dataStatus.message}${updated}`;
  card.append(note);
  if (!["retry", "connect"].includes(dataStatus.action)) return;
  const action = document.createElement("button");
  action.type = "button";
  action.textContent = dataStatus.action === "connect" ? "更新授权"
    : dataStatus.issue ? "重试此项" : "刷新此项";
  action.addEventListener("click", async () => {
    if (dataStatus.action === "connect") {
      elements.hduHelpPatForm.hidden = false;
      elements.connectHduHelpButton.hidden = false;
      elements.hduHelpPatInput.focus();
      return;
    }
    if (hduHelpResourceRefreshing || elements.syncHduHelpButton.disabled) return;
    const owner = state.user;
    const connection = state.hduHelp;
    hduHelpResourceRefreshing = true;
    action.disabled = true;
    try {
      const data = await api(`/api/v1/hduhelp/resources/${encodeURIComponent(resource)}/refresh`, {
        method: "POST",
      });
      if (state.user === owner && state.hduHelp === connection) renderHduHelpData(data);
    } catch (error) {
      if (state.user === owner) showToast(error.message, "error");
    } finally {
      hduHelpResourceRefreshing = false;
      action.disabled = false;
    }
  });
  card.append(action);
}

function renderHduHelpData(payload) {
  if (payload.status) renderHduHelpStatus(payload.status);
  const sections = payload.sections ?? [];
  const resourceStatuses = payload.resource_statuses ?? {};
  const prompts = payload.suggested_prompts ?? [];
  elements.hduHelpDataSummary.textContent = sections.length
    ? `已整理 ${sections.length} 个信息分区，请按各项状态查看。`
    : "暂无可展示的数据，请查看各项状态。";
  elements.hduHelpDataSections.replaceChildren();
  sections.forEach((section) => {
    const card = document.createElement("article");
    card.className = "hduhelp-data-section";
    const header = document.createElement("div");
    const copy = document.createElement("div");
    const title = document.createElement("h4");
    const summary = document.createElement("p");
    const ready = document.createElement("span");
    title.textContent = section.title;
    summary.textContent = section.summary;
    ready.textContent = resourceStatuses[section.resource] ? "" : "已同步";
    copy.append(title, summary);
    header.append(copy, ready);
    const itemList = document.createElement("dl");
    (section.items ?? []).forEach((item) => {
      const label = document.createElement("dt");
      const value = document.createElement("dd");
      label.textContent = item.label;
      value.textContent = item.value;
      value.classList.toggle("emphasis", Boolean(item.emphasis));
      itemList.append(label, value);
    });
    card.append(header, itemList);
    appendHduHelpDataStatus(card, section.resource, resourceStatuses[section.resource]);
    elements.hduHelpDataSections.append(card);
  });
  if (payload.status?.configured) {
    const shown = new Set(sections.map((section) => section.resource));
    Object.entries(resourceStatuses).forEach(([resource, dataStatus]) => {
      if (shown.has(resource)) return;
      const card = document.createElement("article");
      card.className = "hduhelp-data-section";
      const title = document.createElement("h4");
      title.textContent = hduHelpResourceLabels[resource] ?? resource;
      card.append(title);
      appendHduHelpDataStatus(card, resource, dataStatus);
      elements.hduHelpDataSections.append(card);
    });
  }
  elements.hduHelpPromptList.replaceChildren();
  prompts.forEach((suggestion) => {
    const button = document.createElement("button");
    button.type = "button";
    button.textContent = `${suggestion.title}  ↗`;
    button.addEventListener("click", () => openAgentWithPrompt(suggestion.prompt));
    elements.hduHelpPromptList.append(button);
  });
}

async function loadHduHelpData() {
  const owner = state.user;
  const opening = elements.hduHelpDataPanel.hidden;
  if (!opening) {
    elements.hduHelpDataPanel.hidden = true;
    elements.viewHduHelpDataButton.textContent = "查看校园档案";
    return;
  }
  elements.hduHelpDataPanel.hidden = false;
  elements.viewHduHelpDataButton.textContent = "收起校园档案";
  elements.hduHelpDataSummary.textContent = "正在整理已同步的数据…";
  try {
    const data = await api("/api/v1/hduhelp/data");
    if (state.user === owner && !elements.hduHelpDataPanel.hidden) renderHduHelpData(data);
  } catch (error) {
    if (state.user !== owner || elements.hduHelpDataPanel.hidden) return;
    elements.hduHelpDataSummary.textContent = error.message;
    showToast(error.message, "error");
  }
}

async function loadHduHelpStatus() {
  const owner = state.user;
  try {
    const status = await api("/api/v1/hduhelp/status");
    if (state.user === owner) renderHduHelpStatus(status);
  } catch (error) {
    if (state.user === owner) showToast(error.message, "error");
  }
}

async function connectHduHelp() {
  setButtonBusy(elements.connectHduHelpButton, true, "正在创建授权…");
  try {
    const payload = await api("/api/v1/hduhelp/connect", { method: "POST" });
    globalThis.location.assign(payload.authorize_url);
  } catch (error) {
    showToast(error.message, "error");
    setButtonBusy(elements.connectHduHelpButton, false, "");
  }
}

async function connectHduHelpPat(event) {
  event.preventDefault();
  const pat = elements.hduHelpPatInput.value.trim();
  if (!pat) return;
  const owner = state.user;
  const button = elements.hduHelpPatForm.querySelector('button[type="submit"]');
  setButtonBusy(button, true, "正在验证…");
  try {
    const payload = await api("/api/v1/hduhelp/pat", {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ pat }),
    });
    if (state.user !== owner) return;
    elements.hduHelpPatInput.value = "";
    renderHduHelpStatus(payload.status);
    if (!elements.hduHelpDataPanel.hidden) {
      const data = await api("/api/v1/hduhelp/data");
      if (state.user !== owner) return;
      renderHduHelpData(data);
    }
    const failed = Object.keys(payload.errors ?? {}).length;
    showToast(failed
      ? `令牌已连接，${payload.synced_resources.length} 类数据成功，${failed} 类待处理`
      : `令牌已连接并同步 ${payload.synced_resources.length} 类数据`);
  } catch (error) {
    if (state.user === owner) showToast(error.message, "error");
  } finally {
    if (state.user === owner) elements.hduHelpPatInput.value = "";
    setButtonBusy(button, false, "");
  }
}

async function syncHduHelp() {
  if (hduHelpResourceRefreshing) return;
  const owner = state.user;
  elements.syncHduHelpButton.disabled = true;
  try {
    const payload = await api("/api/v1/hduhelp/sync", { method: "POST" });
    if (state.user !== owner) return;
    renderHduHelpStatus(payload.status);
    if (!elements.hduHelpDataPanel.hidden) {
      const data = await api("/api/v1/hduhelp/data");
      if (state.user !== owner) return;
      renderHduHelpData(data);
    }
    const failed = Object.keys(payload.errors ?? {}).length;
    showToast(failed ? `已同步 ${payload.synced_resources.length} 类数据，${failed} 类待重试` : `已同步 ${payload.synced_resources.length} 类校园数据`);
  } catch (error) {
    if (state.user !== owner) return;
    showToast(error.message, "error");
    await loadHduHelpStatus();
    if (state.user === owner && !elements.hduHelpDataPanel.hidden) {
      try {
        const data = await api("/api/v1/hduhelp/data");
        if (state.user === owner) renderHduHelpData(data);
      } catch {
        // Keep the existing results while the server is unreachable.
      }
    }
  } finally {
    elements.syncHduHelpButton.disabled = false;
  }
}

async function disconnectHduHelp() {
  if (!globalThis.confirm("确定断开 HDUHelp 吗？已同步的学籍、成绩和校园生活缓存也会删除。")) return;
  elements.disconnectHduHelpButton.disabled = true;
  try {
    await api("/api/v1/hduhelp/connection", { method: "DELETE" });
    renderHduHelpStatus({ configured: false, resources: [] });
    elements.viewHduHelpDataButton.textContent = "查看校园档案";
    elements.hduHelpDataSections.replaceChildren();
    elements.hduHelpPromptList.replaceChildren();
    showToast("HDUHelp 已断开，本地同步数据已删除");
  } catch (error) {
    showToast(error.message, "error");
  } finally {
    elements.disconnectHduHelpButton.disabled = false;
  }
}

async function loadScheduleSubscriptionStatus() {
  try {
    renderScheduleSubscriptionStatus(await api("/api/v1/schedule-subscriptions"));
  } catch (error) {
    showToast(error.message, "error");
  }
}

async function saveScheduleSubscription(event) {
  event.preventDefault();
  const url = elements.scheduleSubscriptionUrl.value.trim();
  if (!url) return;
  const button = elements.scheduleSubscriptionForm.querySelector('button[type="submit"]');
  setButtonBusy(button, true, "正在连接…");
  try {
    const payload = await api("/api/v1/schedule-subscriptions", {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ url }),
    });
    elements.scheduleSubscriptionForm.reset();
    renderScheduleSubscriptionStatus(payload.status);
    await loadSettingsContext(true, false);
    showToast(`课表订阅已连接，共同步 ${payload.imported_count} 条课程`);
  } catch (error) {
    showToast(error.message, "error");
  } finally {
    setButtonBusy(button, false, "");
  }
}

async function syncScheduleSubscription() {
  elements.syncSubscriptionButton.disabled = true;
  try {
    const payload = await api("/api/v1/schedule-subscriptions/sync", { method: "POST" });
    renderScheduleSubscriptionStatus(payload.status);
    await loadSettingsContext(true, false);
    showToast(`同步完成，已更新 ${payload.imported_count} 条课程`);
  } catch (error) {
    showToast(error.message, "error");
  } finally {
    elements.syncSubscriptionButton.disabled = false;
  }
}

async function disconnectScheduleSubscription() {
  if (!globalThis.confirm("确定断开课表订阅吗？已导入的课程会保留。")) return;
  elements.disconnectSubscriptionButton.disabled = true;
  try {
    await api("/api/v1/schedule-subscriptions", { method: "DELETE" });
    renderScheduleSubscriptionStatus({ configured: false });
    showToast("课表订阅已断开，当前课程数据已保留");
  } catch (error) {
    showToast(error.message, "error");
  } finally {
    elements.disconnectSubscriptionButton.disabled = false;
  }
}

function correctionStatusLabel(status) {
  return { pending: "待审核", accepted: "已采纳", rejected: "未采纳" }[status] ?? status;
}

// Candidate credentials stay in this page's memory and never enter a map bridge or storage.
const campusPlaceSelection = {version: 0, ownerKey: null, packageKey: null, controller: null,
  candidates: [], selected: null, page: -1, hasMore: false, expiresAt: 0, query: "",
  busy: false, saving: false, frame: null};
let campusDataRequestVersion = 0;

function campusPlaceOwnerKey() {
  return JSON.stringify([state.user?.user_id, state.sessionId, state.user?.school,
    state.user?.campus, globalThis.location.origin, globalThis.location.pathname]);
}

function campusPlacePackageKey() {
  return JSON.stringify([state.campusData?.package?.package_id, state.campusData?.package?.version]);
}

function campusPlacePanelActive() {
  return !!state.user && !document.hidden && !elements.settingsView.hidden && state.settingsTab === "data";
}

function clearCampusPlacePreview() {
  const current = campusPlaceSelection;
  if (current.frame) clearManagedCampusMap(current.frame);
  current.frame = null;
  elements.campusPlacePreview.replaceChildren();
  current.selected = null;
  elements.campusPlaceConfirmButton.disabled = true;
}

function clearCampusPlaceCandidates() {
  const current = campusPlaceSelection;
  current.version++;
  current.controller?.abort();
  current.controller = null;
  current.candidates = [];
  current.page = -1;
  current.hasMore = false;
  current.expiresAt = 0;
  current.busy = false;
  current.saving = false;
  clearCampusPlacePreview();
  elements.campusPlaceCandidates.replaceChildren();
  elements.campusPlaceMoreButton.hidden = true;
  elements.campusPlaceSelectionStatus.textContent = "请选择地点后检索候选。";
}

function syncCampusPlaceSelection() {
  const current = campusPlaceSelection;
  const ownerKey = campusPlaceOwnerKey();
  const packageKey = campusPlacePackageKey();
  if (current.ownerKey !== null && current.ownerKey !== ownerKey) {
    clearCampusPlaceCandidates();
    campusDataRequestVersion++;
    state.campusData = null;
    elements.campusPlaceSelect.replaceChildren();
    elements.campusPlaceQuery.value = "";
    elements.campusPlaceSavedSelection.textContent = "";
  }
  if (current.packageKey !== null && current.packageKey !== packageKey) {
    clearCampusPlaceCandidates();
    campusDataRequestVersion++;
  }
  current.ownerKey = ownerKey;
  current.packageKey = campusPlacePackageKey();
  if (!campusPlacePanelActive() || !campusRouteMapAllowed()) {
    clearCampusPlaceCandidates();
    campusDataRequestVersion++;
  }
  updateCampusPlaceControls();
}

function campusPlacePointValid(point) {
  return point && typeof point.lat === "number" && typeof point.lng === "number" &&
    Number.isFinite(point.lat) && Number.isFinite(point.lng) && Math.abs(point.lat) <= 90 && Math.abs(point.lng) <= 180;
}

function updateCampusPlaceControls() {
  const current = campusPlaceSelection;
  const place = state.campusData?.places?.find(item => item.place_id === elements.campusPlaceSelect.value);
  const allowed = campusRouteMapAllowed() && !!place && campusPlacePanelActive();
  elements.campusPlaceSearchButton.disabled = !allowed || current.busy || current.saving;
  elements.campusPlaceMoreButton.hidden = !current.hasMore;
  elements.campusPlaceMoreButton.disabled = !allowed || current.busy || current.saving;
  elements.campusPlaceConfirmButton.disabled = !allowed || !current.selected || current.busy || current.saving;
  elements.campusPlaceReselectButton.hidden = !place?.selection;
  elements.campusPlaceReselectButton.disabled = !allowed || current.busy || current.saving;
  elements.campusPlaceSavedSelection.textContent = place?.selection
    ? `已确认：${place.selection.name} · ${place.selection.address || "地址未提供"}`
    : place?.location ? "此地点已有维护者配置的入口，可直接规划；也可检索并确认自己的入口。" : "尚未确认入口，请检索候选后选择并确认。";
  if (!campusRouteMapAllowed()) elements.campusPlaceSelectionStatus.textContent = "当前学校或校区暂不支持校园地点确认。";
}

function renderCampusPlaceSelection() {
  const selectedId = elements.campusPlaceSelect.value;
  syncCampusPlaceSelection();
  elements.campusPlaceSelect.replaceChildren();
  for (const place of state.campusData?.places ?? []) {
    const option = document.createElement("option");
    option.value = place.place_id;
    option.textContent = `${campusPlaceDisplayName(place)}${place.selection ? " · 已确认" : ""}`;
    elements.campusPlaceSelect.append(option);
  }
  if ([...elements.campusPlaceSelect.options].some(option => option.value === selectedId)) {
    elements.campusPlaceSelect.value = selectedId;
  }
  updateCampusPlaceControls();
}

function campusPlaceTicketCurrent(ticket) {
  return ticket.version === campusPlaceSelection.version && ticket.ownerKey === campusPlaceOwnerKey() &&
    ticket.packageKey === campusPlacePackageKey() && ticket.placeId === elements.campusPlaceSelect.value &&
    ticket.query === elements.campusPlaceQuery.value.trim() && campusPlacePanelActive() && campusRouteMapAllowed();
}

function campusPlaceFailureMessage(error, saving = false) {
  // Never display provider URLs, credentials, or arbitrary upstream error text in this panel.
  if (error.status === 401) return "登录已失效，请重新登录后检索候选。";
  if (["候选已过期，请重新检索并确认地点。", "候选已失效，请重新检索并确认地点。"].includes(error.message)) return error.message;
  if (error.status === 503) return "校园地点服务暂不可用，请联系维护者完善配置后重试。";
  return saving ? "入口确认未完成，请重新检索候选后重试。" : "候选检索未完成，请检查网络后重新检索。";
}

function renderCampusPlaceCandidates() {
  const current = campusPlaceSelection;
  elements.campusPlaceCandidates.replaceChildren();
  for (const candidate of current.candidates) {
    const card = document.createElement("article");
    const name = document.createElement("b");
    const address = document.createElement("p");
    const preview = document.createElement("button");
    name.textContent = candidate.name;
    address.textContent = candidate.address || "地址未提供，请结合地图确认入口。";
    preview.type = "button";
    preview.className = "line-button";
    preview.dataset.campusPlacePreview = "";
    preview.textContent = "在地图预览";
    preview.setAttribute("aria-pressed", String(current.selected === candidate));
    preview.disabled = current.busy || current.saving;
    preview.addEventListener("click", () => previewCampusPlace(candidate));
    card.append(name, address, preview);
    elements.campusPlaceCandidates.append(card);
  }
  updateCampusPlaceControls();
}

function previewCampusPlace(candidate) {
  syncCampusPlaceSelection();
  const current = campusPlaceSelection;
  if (!campusPlacePanelActive() || !current.candidates.includes(candidate) || current.busy || current.saving) return;
  if (Date.now() >= current.expiresAt) {
    clearCampusPlaceCandidates();
    elements.campusPlaceSelectionStatus.textContent = "候选已过期，请重新检索并确认地点。";
    return;
  }
  clearCampusPlacePreview();
  current.selected = candidate;
  const frame = createManagedCampusMap("校园候选入口地图预览");
  current.frame = frame;
  const version = current.version;
  const owner = currentCampusMapOwner();
  frame.addEventListener("load", () => {
    const active = () => current.frame === frame && current.version === version && currentCampusMapOwner() === owner &&
      campusPlacePanelActive() && campusRouteMapAllowed();
    if (!active()) return;
    // The shared renderer receives only public marker data, never the candidate or auth object.
    const origin = {place_id: elements.campusPlaceSelect.value, name: candidate.name,
      location: {lat: candidate.location.lat, lng: candidate.location.lng}};
    setManagedCampusMapState(frame, active, {active: true, route: null, origin, destination: null});
  });
  elements.campusPlacePreview.append(frame);
  elements.campusPlaceSelectionStatus.textContent = `正在预览：${candidate.name} · ${candidate.address || "地址未提供"}。请核对地图后点击“确认此地点”。`;
  renderCampusPlaceCandidates();
}

async function searchCampusPlaceCandidates(more = false) {
  syncCampusPlaceSelection();
  const current = campusPlaceSelection;
  if (!campusPlacePanelActive() || !campusRouteMapAllowed() || !state.campusData || current.busy || current.saving) return;
  const placeId = elements.campusPlaceSelect.value;
  if (!state.campusData.places.some(place => place.place_id === placeId)) return;
  const page = more ? current.page + 1 : 0;
  if (page > 4 || (more && !current.hasMore)) return;
  const previous = more ? [...current.candidates] : [];
  const previousExpiry = current.expiresAt;
  const query = elements.campusPlaceQuery.value.trim();
  clearCampusPlaceCandidates();
  current.candidates = previous;
  current.query = query;
  current.busy = true;
  current.controller = new AbortController();
  const ticket = {version: current.version, ownerKey: campusPlaceOwnerKey(), packageKey: campusPlacePackageKey(), placeId, query};
  const params = new URLSearchParams({page: String(page)});
  if (query) params.set("query", query);
  renderCampusPlaceCandidates();
  elements.campusPlaceSelectionStatus.textContent = "正在检索当前校区的候选入口…";
  try {
    const result = await api(`/api/v1/campus-data/places/${encodeURIComponent(placeId)}/candidates?${params}`, {
      signal: current.controller.signal, cache: "no-store",
    });
    if (!campusPlaceTicketCurrent(ticket)) return;
    if (result.place_id !== placeId || result.page !== page || !Array.isArray(result.candidates) ||
      !Number.isFinite(Date.parse(result.expires_at))) throw new Error("invalid-candidates");
    const candidates = result.candidates.filter(candidate => typeof candidate.name === "string" &&
      typeof candidate.selection_token === "string" && !!candidate.selection_token && campusPlacePointValid(candidate.location));
    current.candidates = [...previous, ...candidates];
    current.page = page;
    current.hasMore = result.has_more === true && page < 4;
    current.expiresAt = previous.length ? Math.min(previousExpiry, Date.parse(result.expires_at)) : Date.parse(result.expires_at);
    current.busy = false;
    renderCampusPlaceCandidates();
    elements.campusPlaceSelectionStatus.textContent = candidates.length
      ? `已展示 ${current.candidates.length} 个候选，请逐一预览后确认。${current.hasMore ? "可加载更多候选。" : ""}${result.truncated ? "检索已达上限，可缩小检索词重新查询。" : ""}`
      : `本页没有合法校园候选。${current.hasMore ? "可加载更多候选，或修改检索词。" : "请修改检索词后重新检索。"}`;
  } catch (error) {
    if (!campusPlaceTicketCurrent(ticket)) return;
    clearCampusPlaceCandidates();
    elements.campusPlaceSelectionStatus.textContent = campusPlaceFailureMessage(error);
    updateCampusPlaceControls();
  }
}

async function confirmCampusPlaceSelection() {
  syncCampusPlaceSelection();
  const current = campusPlaceSelection;
  const candidate = current.selected;
  if (!candidate || current.busy || current.saving || !campusPlacePanelActive()) return;
  if (Date.now() >= current.expiresAt) {
    clearCampusPlaceCandidates();
    elements.campusPlaceSelectionStatus.textContent = "候选已过期，请重新检索并确认地点。";
    updateCampusPlaceControls();
    return;
  }
  const ticket = {version: current.version, ownerKey: campusPlaceOwnerKey(), packageKey: campusPlacePackageKey(),
    placeId: elements.campusPlaceSelect.value, query: elements.campusPlaceQuery.value.trim()};
  current.saving = true;
  current.controller = new AbortController();
  renderCampusPlaceCandidates();
  elements.campusPlaceSelectionStatus.textContent = "正在保存当前账号的入口选择…";
  let saved = false;
  try {
    const result = await api(`/api/v1/campus-data/places/${encodeURIComponent(ticket.placeId)}/selection`, {
      method: "PUT", headers: {"Content-Type": "application/json"},
      body: JSON.stringify({selection_token: candidate.selection_token}), signal: current.controller.signal, cache: "no-store",
    });
    if (!campusPlaceTicketCurrent(ticket)) return;
    if (result.place_id !== ticket.placeId || !campusPlacePointValid(result.location)) throw new Error("invalid-selection");
    saved = true;
    const snapshot = await api("/api/v1/campus-data", {signal: current.controller.signal, cache: "no-store"});
    if (!campusPlaceTicketCurrent(ticket)) return;
    clearCampusPlaceCandidates();
    clearCampusRouteMaps();
    renderCampusData(snapshot);
    elements.campusPlaceSelectionStatus.textContent = "入口已保存到当前账号，之后规划路线时会复用。需要更换时可重新选择。";
  } catch (error) {
    if (!campusPlaceTicketCurrent(ticket)) return;
    clearCampusPlaceCandidates();
    elements.campusPlaceSelectionStatus.textContent = saved
      ? "入口已保存，但资料刷新未完成。请重新打开学习数据确认最新入口。" : campusPlaceFailureMessage(error, true);
    updateCampusPlaceControls();
  }
}

document.addEventListener("visibilitychange", syncCampusPlaceSelection);
window.addEventListener("pagehide", () => { clearCampusPlaceCandidates(); campusDataRequestVersion++; });

function renderCampusData(payload) {
  syncCampusPlaceSelection();
  state.campusData = payload;
  const dataPackage = payload.package;
  elements.campusPackageName.textContent = `${dataPackage.school} · ${dataPackage.campus}`;
  elements.campusPackageVersion.textContent = `v${dataPackage.version}`;
  elements.campusPackageDescription.textContent = dataPackage.description;
  elements.campusPackagePlaceCount.textContent = dataPackage.place_count;
  elements.campusPackageNoticeCount.textContent = dataPackage.notice_count;
  elements.campusPackageCorrectionCount.textContent = payload.corrections.length;

  elements.campusNoticeList.replaceChildren();
  payload.notices.slice(0, 3).forEach((notice) => {
    const item = document.createElement("article");
    const meta = document.createElement("span");
    const title = document.createElement("b");
    const detail = document.createElement("p");
    meta.textContent = notice.category;
    title.textContent = notice.title;
    detail.textContent = notice.content;
    item.append(meta, title, detail);
    elements.campusNoticeList.append(item);
  });
  if (!payload.notices.length) {
    elements.campusNoticeList.append(contextListItem("暂无校园通知", "数据包当前没有有效通知"));
  }

  elements.campusCorrectionList.replaceChildren();
  payload.corrections.slice(0, 4).forEach((correction) => {
    const item = document.createElement("article");
    const copy = document.createElement("div");
    const title = document.createElement("b");
    const detail = document.createElement("span");
    const badge = document.createElement("i");
    title.textContent = `${correction.target_id} · ${correction.field}`;
    detail.textContent = correction.suggested_value;
    badge.textContent = correctionStatusLabel(correction.status);
    copy.append(title, detail);
    item.append(copy, badge);
    elements.campusCorrectionList.append(item);
  });
  renderCampusPlaceSelection();
}

async function loadCampusData() {
  const ownerKey = campusPlaceOwnerKey();
  const version = ++campusDataRequestVersion;
  try {
    const payload = await api("/api/v1/campus-data", {cache: "no-store"});
    if (version !== campusDataRequestVersion || ownerKey !== campusPlaceOwnerKey() || !campusPlacePanelActive()) return;
    renderCampusData(payload);
  } catch (error) {
    if (version !== campusDataRequestVersion || ownerKey !== campusPlaceOwnerKey() || !campusPlacePanelActive()) return;
    elements.campusPackageName.textContent = "校园数据包加载失败";
    showToast(error.message, "error");
  }
}

async function submitCampusCorrection(event) {
  event.preventDefault();
  const button = elements.campusCorrectionForm.querySelector('button[type="submit"]');
  setButtonBusy(button, true, "正在提交…");
  try {
    await api("/api/v1/campus-data/corrections", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        target_type: elements.correctionTargetType.value,
        target_id: elements.correctionTargetId.value.trim(),
        field: elements.correctionField.value.trim(),
        suggested_value: elements.correctionValue.value.trim(),
        reason: elements.correctionReason.value.trim(),
      }),
    });
    elements.campusCorrectionForm.reset();
    await loadCampusData();
    showToast("纠错建议已提交，审核前不会影响其他用户");
  } catch (error) {
    showToast(error.message, "error");
  } finally {
    setButtonBusy(button, false, "");
  }
}

async function loadSettingsContext(force = false, loadSubscription = true) {
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
  const requests = [loadCampusData(), loadHduHelpStatus()];
  if (loadSubscription) requests.push(loadScheduleSubscriptionStatus());
  await Promise.all(requests);
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
    syncCampusPlaceSelection();
    syncCampusRouteMaps();
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
  const hduHelpResult = new URLSearchParams(globalThis.location.search).get("hduhelp");
  if (hduHelpResult) {
    globalThis.history.replaceState({}, "", globalThis.location.pathname);
    setTimeout(() => showToast(
      hduHelpResult === "connected" ? "HDUHelp 授权成功，可在学习数据中开始同步" : "HDUHelp 授权未完成，请重试",
      hduHelpResult === "connected" ? "info" : "error",
    ), 100);
  }
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
elements.agentControlButton.addEventListener("click", () => elements.agentControlDialog.showModal());
elements.historyCloseButton.addEventListener("click", closeHistory);
elements.drawerScrim.addEventListener("click", closeHistory);
elements.historySearch.addEventListener("input", () => {
  clearTimeout(elements.historySearch.searchTimer);
  elements.historySearch.searchTimer = setTimeout(() => loadHistory(elements.historySearch.value.trim()), 180);
});
elements.settingsForm.addEventListener("submit", saveSettings);
elements.baiduMapSettingsForm.addEventListener("submit", event => {
  event.preventDefault();
  const browserAk = elements.baiduBrowserAk.value.trim();
  const serverAk = elements.baiduServerAk.value.trim();
  const payload = {};
  if (browserAk) payload.browser_ak = browserAk;
  if (serverAk) payload.server_ak = serverAk;
  void updateBaiduMapSettings(payload);
});
elements.clearBaiduBrowserAk.addEventListener("click", () => {
  if (baiduMapSettingsView?.sources?.browser === "account") void updateBaiduMapSettings({browser_ak: null});
});
elements.clearBaiduServerAk.addEventListener("click", () => {
  if (baiduMapSettingsView?.sources?.server === "account") void updateBaiduMapSettings({server_ak: null});
});
elements.hduHelpPatForm.addEventListener("submit", connectHduHelpPat);
elements.connectHduHelpButton.addEventListener("click", connectHduHelp);
elements.viewHduHelpDataButton.addEventListener("click", loadHduHelpData);
elements.syncHduHelpButton.addEventListener("click", syncHduHelp);
elements.disconnectHduHelpButton.addEventListener("click", disconnectHduHelp);
elements.setupSubscriptionForm.addEventListener("submit", previewScheduleSubscription);
elements.scheduleSubscriptionForm.addEventListener("submit", saveScheduleSubscription);
elements.syncSubscriptionButton.addEventListener("click", syncScheduleSubscription);
elements.disconnectSubscriptionButton.addEventListener("click", disconnectScheduleSubscription);
elements.campusCorrectionForm.addEventListener("submit", submitCampusCorrection);
elements.campusPlaceSearchForm.addEventListener("submit", event => {event.preventDefault(); void searchCampusPlaceCandidates();});
elements.campusPlaceMoreButton.addEventListener("click", () => {void searchCampusPlaceCandidates(true);});
elements.campusPlaceReselectButton.addEventListener("click", () => {void searchCampusPlaceCandidates();});
elements.campusPlaceConfirmButton.addEventListener("click", () => {void confirmCampusPlaceSelection();});
elements.campusPlaceSelect.addEventListener("change", () => {
  clearCampusPlaceCandidates();
  elements.campusPlaceQuery.value = "";
  updateCampusPlaceControls();
});
elements.campusPlaceQuery.addEventListener("input", () => {clearCampusPlaceCandidates(); updateCampusPlaceControls();});
elements.quickTaskForm.addEventListener("submit", createQuickTask);
elements.skillSearch.addEventListener("input", () => {
  clearTimeout(elements.skillSearch.searchTimer);
  elements.skillSearch.searchTimer = setTimeout(renderSkillLibrary, 120);
});
elements.skillCategory.addEventListener("change", renderSkillLibrary);
elements.skillDrawerClose.addEventListener("click", closeSkillDrawer);
elements.skillScrim.addEventListener("click", closeSkillDrawer);
elements.skillInstallButton.addEventListener("click", installSelectedSkill);
elements.skillToggleButton.addEventListener("click", toggleSelectedSkill);
elements.skillUpgradeButton.addEventListener("click", upgradeSelectedSkill);
elements.skillUninstallButton.addEventListener("click", uninstallSelectedSkill);
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
  if (elements.agentControlDialog.open) elements.agentControlDialog.close();
  elements.messageInput.value = button.dataset.prompt;
  resizeComposer();
  elements.messageInput.focus();
}));
$$('[data-route-origin][data-route-destination]').forEach((button) => button.addEventListener("click", () => {
  if (elements.agentControlDialog.open) elements.agentControlDialog.close();
  sendMessage(`从${button.dataset.routeOrigin}到${button.dataset.routeDestination}怎么走？请生成地图路线图。`);
}));
elements.newSessionButton.addEventListener("click", resetSession);
$$('[data-app-tab]').forEach((button) => button.addEventListener("click", () => switchAppTab(button.dataset.appTab)));
$$('[data-app-action="settings"]').forEach((button) => button.addEventListener("click", openSettings));
$$('[data-open-agent]').forEach((button) => button.addEventListener("click", () => openAgentWithPrompt(button.dataset.prompt)));

initialize();
