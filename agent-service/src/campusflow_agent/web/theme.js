/* Appearance is device-local. Never rebuild app DOM or write account data to change it. */
(() => {
  const key = 'campusflow.theme';
  const fallback = 'paper-green';
  const valid = value => value === 'ios-blue' || value === 'paper-green';
  let current = fallback;
  let persisted = true;
  try { const saved = localStorage.getItem(key); if (valid(saved)) current = saved; }
  catch { persisted = false; }
  document.documentElement.dataset.theme = current;

  function refreshControls() {
    document.querySelectorAll('[data-theme-choice]').forEach(button => {
      const selected = button.dataset.themeChoice === current;
      button.setAttribute('aria-pressed', String(selected));
      button.classList.toggle('selected', selected);
    });
    const status = document.getElementById('themeStatus');
    if (status) status.textContent = persisted
      ? `当前为${current === 'ios-blue' ? '清透蓝' : '纸页绿'}，已保存在此浏览器。`
      : '主题已生效；此浏览器暂不允许保存偏好，关闭页面后可能需要重新选择。';
  }

  function select(value, save = true) {
    if (!valid(value)) return false;
    current = value;
    if (save) {
      try { localStorage.setItem(key, current); persisted = true; }
      catch { persisted = false; }
    }
    document.documentElement.dataset.theme = current;
    refreshControls();
    return true;
  }

  function bind() {
    document.querySelectorAll('[data-theme-choice]').forEach(button => {
      button.addEventListener('click', () => select(button.dataset.themeChoice));
    });
    refreshControls();
  }
  window.addEventListener('storage', event => {
    if (event.key === key) select(valid(event.newValue) ? event.newValue : fallback, false);
  });
  window.CampusFlowTheme = Object.freeze({ select, refreshControls, current: () => current });
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', bind, { once: true });
  else bind();
})();
