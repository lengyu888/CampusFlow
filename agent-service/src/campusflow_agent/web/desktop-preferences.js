(() => {
  if (document.documentElement.dataset.platform !== "windows") return;

  const client = window.CampusFlowWindows;
  const panel = document.getElementById("windowsPreferences");
  const form = document.getElementById("windowsPreferencesForm");
  const fields = form.querySelector("fieldset");
  const status = document.getElementById("windowsPreferencesStatus");
  const clear = document.getElementById("windowsPreferencesClear");
  const reload = document.getElementById("windowsPreferencesReload");
  const retry = document.getElementById("windowsPreferencesRetry");
  const endpoint = "/api/v1/learning-preferences";
  const valueNames = ["enabled", "session_minutes", "break_minutes", "daily_minutes", "preferred_period"];
  const defaults = { enabled: false, session_minutes: 50, break_minutes: 10, daily_minutes: 120, preferred_period: "any" };
  let owner = null;
  let snapshot = null;
  let pending = null;
  let waiting = false;
  let stale = false;
  let dirty = false;
  let generation = 0;

  function render() {
    fields.disabled = waiting || stale || !snapshot || Boolean(pending);
    reload.disabled = waiting;
    retry.hidden = !pending;
    retry.disabled = waiting;
    retry.textContent = pending?.method === "DELETE" ? "核对上次清除" : "核对上次保存";
  }

  function fill(value) {
    form.elements.enabled.checked = value.enabled;
    for (const name of valueNames.slice(1)) form.elements[name].value = value[name];
    dirty = false;
  }

  function valid(value) {
    return value && Number.isSafeInteger(value.revision) && value.revision >= 0 && typeof value.enabled === "boolean" &&
      [["session_minutes", 15, 120], ["break_minutes", 0, 30], ["daily_minutes", 30, 480]]
        .every(([field, min, max]) => Number.isInteger(value[field]) && value[field] >= min && value[field] <= max) &&
      ["any", "morning", "afternoon", "evening"].includes(value.preferred_period);
  }

  function reset(nextOwner = null) {
    generation += 1;
    owner = nextOwner;
    snapshot = null;
    pending = null;
    waiting = false;
    stale = false;
    form.reset();
    dirty = false;
    status.textContent = "";
    render();
  }

  function current(request) {
    return request === generation && owner === client.user()?.user_id;
  }

  async function load() {
    if (!owner || waiting) return;
    const request = generation;
    waiting = true;
    status.textContent = "正在读取学习偏好…";
    render();
    try {
      const result = await client.api(endpoint, { cache: "no-store", signal: AbortSignal.timeout(10000) });
      if (!current(request)) return;
      if (!valid(result)) throw new Error("Invalid preference snapshot");
      snapshot = result;
      stale = false;
      if (!dirty && !pending) fill(result);
      status.textContent = pending ? "已读取当前值。请核对上次操作。" : dirty ? "已读取最新版本，输入仍保留。请核对后保存。" : "";
    } catch {
      if (current(request)) status.textContent = "读取失败，请检查连接后重试。";
    } finally {
      if (current(request)) { waiting = false; render(); }
    }
  }

  async function write() {
    if (!pending || waiting) return;
    const request = generation;
    const operation = pending;
    waiting = true;
    render();
    status.textContent = "正在核对操作…";
    try {
      const result = await client.api(endpoint, {
        method: operation.method, headers: { "Content-Type": "application/json" },
        body: JSON.stringify(operation.body), signal: AbortSignal.timeout(10000),
      });
      if (!current(request)) return;
      if (!valid(result) || result.revision <= operation.body.base_revision) throw new Error("Invalid preference receipt");
      snapshot = result;
      pending = null;
      const expected = operation.method === "DELETE" ? defaults : operation.body;
      if (valueNames.every(name => expected[name] === result[name])) {
        fill(result);
        status.textContent = operation.method === "DELETE" ? "学习偏好已清除。" : "学习偏好已保存。";
      } else {
        status.textContent = "其他设备随后修改了偏好。已显示服务器当前值。";
        fill(result);
      }
    } catch (error) {
      if (!current(request)) return;
      if (error.status === 409) {
        pending = null;
        stale = true;
        status.textContent = "服务器版本已变化。请读取最新值后检查输入。";
      } else if ([400, 401, 403, 422].includes(error.status)) {
        pending = null;
        status.textContent = "未保存。请检查登录状态和输入。";
      } else {
        status.textContent = "暂时无法确认结果。重新联网后可核对原操作。";
      }
    } finally {
      if (current(request)) { waiting = false; render(); }
    }
  }

  function start(method, values = {}) {
    if (panel.hidden || fields.disabled || owner !== client.user()?.user_id) return;
    pending = { method, body: { base_revision: snapshot.revision, operation_id: client.uuid(), ...values } };
    void write();
  }

  document.querySelector('[data-settings-tab="learning"]').addEventListener("click", () => {
    const nextOwner = client.user()?.user_id;
    if (!nextOwner) return;
    if (owner !== nextOwner) reset(nextOwner);
    if (!snapshot) void load();
  });
  document.addEventListener("campusflow:desktop-view", (event) => {
    if (event.detail.tab === "logout" || (owner && owner !== event.detail.userId)) reset();
  });
  form.addEventListener("input", () => { dirty = true; });
  form.addEventListener("submit", (event) => {
    event.preventDefault();
    start("PUT", {
      enabled: form.elements.enabled.checked,
      session_minutes: form.elements.session_minutes.valueAsNumber,
      break_minutes: form.elements.break_minutes.valueAsNumber,
      daily_minutes: form.elements.daily_minutes.valueAsNumber,
      preferred_period: form.elements.preferred_period.value,
    });
  });
  clear.addEventListener("click", () => {
    if (window.confirm("清除已同步的学习偏好并恢复默认设置？")) start("DELETE");
  });
  reload.addEventListener("click", () => void load());
  retry.addEventListener("click", () => void write());
})();
