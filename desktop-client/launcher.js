const form = document.getElementById('connectionForm');
const address = document.getElementById('serverAddress');
const button = document.getElementById('connectButton');
const status = document.getElementById('connectionStatus');
const transportHint = document.getElementById('transportHint');

function showTransport() { transportHint.hidden = !/^http:\/\//i.test(address.value.trim()); }

void window.campusFlowConnection.address().then((value) => {
  if (!address.value) address.value = value;
  showTransport();
});
address.addEventListener('input', showTransport);

form.addEventListener('submit', async (event) => {
  event.preventDefault();
  const value = address.value;
  address.disabled = true;
  button.disabled = true;
  status.removeAttribute('data-error');
  status.textContent = '正在检查服务器…';
  try {
    const result = await window.campusFlowConnection.connect(value);
    if (result.connected) return;
    status.setAttribute('data-error', '');
    status.textContent = result.error;
  } catch {
    status.setAttribute('data-error', '');
    status.textContent = '连接未完成，请重试。';
  } finally {
    address.disabled = false;
    button.disabled = false;
  }
});
