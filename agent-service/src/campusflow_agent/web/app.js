const elements = {
  apiKey: document.querySelector("#apiKey"),
  toggleSecret: document.querySelector("#toggleSecret"),
  sessionId: document.querySelector("#sessionId"),
  newSessionButton: document.querySelector("#newSessionButton"),
  modelBadge: document.querySelector("#modelBadge"),
  messages: document.querySelector("#messages"),
  emptyState: document.querySelector("#emptyState"),
  composer: document.querySelector("#composer"),
  messageInput: document.querySelector("#messageInput"),
  sendButton: document.querySelector("#sendButton"),
  traceList: document.querySelector("#traceList"),
  systemState: document.querySelector("#systemState"),
  toast: document.querySelector("#toast"),
};

const state = {
  userId: "demo-student",
  sessionId: createSessionId(),
  sending: false,
  hasTraces: false,
};

function createSessionId() {
  const id = globalThis.crypto?.randomUUID?.() ?? `${Date.now()}-${Math.random()}`;
  return `web-${id}`;
}

function selectedModel() {
  return document.querySelector('input[name="model"]:checked').value;
}

function modelLabel(model = selectedModel()) {
  return model === "deepseek-flash" ? "FLASH" : "V4 PRO";
}

function setSessionId() {
  elements.sessionId.textContent = state.sessionId;
  elements.sessionId.title = state.sessionId;
}

function showToast(message, kind = "info") {
  elements.toast.textContent = message;
  elements.toast.classList.toggle("error", kind === "error");
  elements.toast.classList.add("show");
  clearTimeout(showToast.timer);
  showToast.timer = setTimeout(() => elements.toast.classList.remove("show"), 2800);
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
  meta.textContent = role === "user" ? "YOU / 任务输入" : `AGENT / ${modelLabel()}`;

  const bubble = document.createElement("div");
  bubble.className = "bubble";
  if (options.loading) {
    const typing = document.createElement("span");
    typing.className = "typing";
    for (let index = 0; index < 3; index += 1) {
      typing.append(document.createElement("span"));
    }
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
  details.textContent = safeJson({
    arguments: trace.arguments,
    result: trace.result,
    tool_call_id: trace.tool_call_id,
  });
  card.append(summary, details);
  elements.traceList.prepend(card);
}

function actionDescription(action) {
  const lines = [];
  if (action.start_at) lines.push(`开始：${new Date(action.start_at).toLocaleString("zh-CN")}`);
  if (action.end_at) lines.push(`结束：${new Date(action.end_at).toLocaleString("zh-CN")}`);
  if (action.reminder_minutes != null) lines.push(`提醒：提前 ${action.reminder_minutes} 分钟`);
  if (action.reason) lines.push(`原因：${action.reason}`);
  return lines.join("\n") || "确认后写入演示事务存储。";
}

function renderPendingAction(action) {
  ensureTraceArea();
  const card = document.createElement("section");
  card.className = "action-card";

  const label = document.createElement("div");
  label.className = "action-label";
  label.textContent = `PENDING / ${action.action.toUpperCase()}`;
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
    const response = await fetch(
      `/api/v1/actions/${encodeURIComponent(proposalId)}/confirm?user_id=${encodeURIComponent(state.userId)}`,
      { method: "POST" },
    );
    const payload = await response.json();
    if (!response.ok) throw new Error(payload.detail || "确认失败");
    card.classList.add("confirmed");
    label.textContent = "CONFIRMED / 已写入";
    button.textContent = "已确认";
    showToast(payload.message || "操作已确认");
  } catch (error) {
    button.disabled = false;
    button.textContent = "重新确认";
    showToast(error.message, "error");
  }
}

async function responseError(response) {
  try {
    const payload = await response.json();
    if (Array.isArray(payload.detail)) {
      return payload.detail.map((item) => item.msg).join("；");
    }
    return payload.detail || `请求失败（${response.status}）`;
  } catch {
    return `请求失败（${response.status}）`;
  }
}

async function sendMessage(message) {
  const apiKey = elements.apiKey.value.trim();
  if (!apiKey) {
    elements.apiKey.focus();
    showToast("请先填写 DeepSeek API Key", "error");
    return;
  }
  if (!message || state.sending) return;

  state.sending = true;
  elements.sendButton.disabled = true;
  elements.messageInput.disabled = true;
  appendMessage("user", message);
  const loading = appendMessage("assistant", "", { loading: true });

  try {
    const response = await fetch("/api/v1/chat", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        user_id: state.userId,
        session_id: state.sessionId,
        api_key: apiKey,
        model: selectedModel(),
        message,
      }),
    });
    if (!response.ok) throw new Error(await responseError(response));
    const payload = await response.json();
    loading.remove();
    appendMessage("assistant", payload.message);
    payload.tool_traces.forEach(renderToolTrace);
    payload.pending_actions.forEach(renderPendingAction);
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

function resetSession() {
  state.sessionId = createSessionId();
  state.hasTraces = false;
  setSessionId();
  elements.messages.innerHTML = `
    <div class="empty-state" id="emptyState">
      <div class="orb"><span></span><span></span><span></span></div>
      <p class="eyebrow">NEW CONTEXT</p>
      <h3>新会话已就绪</h3>
      <p>模型选择和当前输入框中的 API Key 保持不变，会话记忆与执行轨迹已经清空。</p>
    </div>`;
  elements.emptyState = document.querySelector("#emptyState");
  elements.traceList.innerHTML = '<div class="trace-empty">尚无工具调用<br /><span>新会话不会继承上一轮上下文</span></div>';
  showToast("已创建独立会话");
}

async function checkHealth() {
  try {
    const response = await fetch("/health");
    if (!response.ok) throw new Error();
    const payload = await response.json();
    const modelCount = payload.supported_models?.length ?? 0;
    setServiceState(true, `服务在线 · ${modelCount} 个模型`);
  } catch {
    setServiceState(false, "服务连接失败");
  }
}

elements.composer.addEventListener("submit", (event) => {
  event.preventDefault();
  sendMessage(elements.messageInput.value.trim());
});

elements.messageInput.addEventListener("input", resizeComposer);
elements.messageInput.addEventListener("keydown", (event) => {
  if (event.key === "Enter" && !event.shiftKey) {
    event.preventDefault();
    elements.composer.requestSubmit();
  }
});

elements.toggleSecret.addEventListener("click", () => {
  const reveal = elements.apiKey.type === "password";
  elements.apiKey.type = reveal ? "text" : "password";
  elements.toggleSecret.textContent = reveal ? "隐藏" : "显示";
});

document.querySelectorAll('input[name="model"]').forEach((radio) => {
  radio.addEventListener("change", () => {
    elements.modelBadge.textContent = modelLabel();
    showToast(`已切换至 ${modelLabel()}`);
  });
});

document.querySelectorAll("[data-prompt]").forEach((button) => {
  button.addEventListener("click", () => {
    elements.messageInput.value = button.dataset.prompt;
    resizeComposer();
    elements.messageInput.focus();
  });
});

elements.newSessionButton.addEventListener("click", resetSession);

setSessionId();
checkHealth();
elements.messageInput.focus();
