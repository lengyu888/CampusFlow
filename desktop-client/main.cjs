const { app, BrowserWindow, dialog, ipcMain, Menu, net, Notification, safeStorage, session, shell, Tray } = require('electron');
const { mkdir, readFile, rename, rm, writeFile } = require('node:fs/promises');
const path = require('node:path');
const { createHash } = require('node:crypto');
const { allowedKnowledgeSource, allowedNavigation, bundledAsset, checkServer, DEFAULT_SERVER_ORIGIN, desktopApiHeaders, desktopAuthResponseHeaders, loadAssets, serverOrigin, validToken } = require('./server.cjs');
const { createOfflineHistory, isHistoryId } = require('./history.cjs');
const { createReminderQueue } = require('./reminders.cjs');
const { createVoiceCapture } = require('./voice.cjs');

const preferences = { nodeIntegration: false, contextIsolation: true, sandbox: true, devTools: false };
const launcherPath = path.join(__dirname, 'launcher.html');
const icon = path.join(__dirname, 'assets', 'app.ico');
const windowsAppId = 'CampusFlow.Desktop.Workspace';
const assetFolder = app.isPackaged ? path.join(__dirname, 'web') : path.join(__dirname, '../agent-service/src/campusflow_agent/web');
const windows = new Map();
const voiceCapture = createVoiceCapture(path.join(__dirname, 'voice.ps1'));
let launcher;
let workspace;
let currentOrigin = '';
let connecting = false;
let history;
let tray;
let quitting = false;

function configPath() { return path.join(app.getPath('userData'), 'server.json'); }

async function savedOrigin() {
  try { return serverOrigin(JSON.parse(await readFile(configPath(), 'utf8')).origin); }
  catch { return ''; }
}

async function saveOrigin(origin) {
  const temporary = `${configPath()}.tmp`;
  await writeFile(temporary, JSON.stringify({ origin }), 'utf8');
  await rename(temporary, configPath());
}

function originKey(origin) { return createHash('sha256').update(origin).digest('hex'); }

function sessionPath(origin) { return path.join(app.getPath('userData'), 'sessions', `${originKey(origin)}.bin`); }

function setWindowsTaskbarDetails(window) {
  if (process.platform !== 'win32' || !app.isPackaged) return;
  window.setAppDetails({
    appId: windowsAppId,
    appIconPath: process.execPath,
    appIconIndex: 0,
    relaunchCommand: `"${process.execPath}"`,
    relaunchDisplayName: '行简 · CampusFlow',
  });
}

async function restoreSession(origin) {
  if (process.platform !== 'win32' || !safeStorage.isEncryptionAvailable()) return '';
  try {
    const token = safeStorage.decryptString(await readFile(sessionPath(origin)));
    return validToken(token) ? token : '';
  } catch { return ''; }
}

async function persistSession(context, token, remember) {
  const file = sessionPath(context.origin);
  if (!remember || !token) {
    await rm(file, { force: true });
    return { remembered: false };
  }
  if (process.platform !== 'win32' || !safeStorage.isEncryptionAvailable()) {
    return { remembered: false, message: '系统安全存储不可用，本次登录仍可使用。' };
  }
  await mkdir(path.dirname(file), { recursive: true });
  const pending = `${file}.tmp`;
  try {
    await writeFile(pending, safeStorage.encryptString(token));
    await rename(pending, file);
  } finally {
    await rm(pending, { force: true });
  }
  return { remembered: true };
}

function openLauncher() {
  if (launcher && !launcher.isDestroyed()) { launcher.focus(); return; }
  launcher = new BrowserWindow({
    width: 650, height: 500, minWidth: 520, minHeight: 460,
    title: '行简 · 连接服务器', backgroundColor: '#f1f6f4', icon,
    webPreferences: { ...preferences, preload: path.join(__dirname, 'preload.cjs') },
  });
  setWindowsTaskbarDetails(launcher);
  launcher.webContents.on('will-frame-navigate', (event) => event.preventDefault());
  launcher.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
  launcher.on('closed', () => { launcher = undefined; });
  void launcher.loadFile(launcherPath);
}

async function installBundledFrontend(contents, origin) {
  const assets = await loadAssets(assetFolder);
  const debuggerClient = contents.debugger;
  debuggerClient.attach('1.3');
  debuggerClient.on('message', (_event, method, params) => {
    if (method !== 'Fetch.requestPaused') return;
    const asset = bundledAsset(params.request, origin, assets);
    const requestId = params.requestId;
    if (!asset) {
      void debuggerClient.sendCommand('Fetch.continueRequest', { requestId }).catch(() => {});
      return;
    }
    const responseHeaders = [
      { name: 'Content-Type', value: asset.type },
      { name: 'Cache-Control', value: 'no-store' },
      { name: 'X-Content-Type-Options', value: 'nosniff' },
    ];
    if (new URL(params.request.url).pathname === '/') {
      responseHeaders.push({ name: 'Content-Security-Policy', value: "default-src 'self'; connect-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; frame-src 'self'; object-src 'none'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'" });
    }
    void debuggerClient.sendCommand('Fetch.fulfillRequest', {
      requestId, responseCode: 200, responseHeaders, body: asset.body,
    }).catch(() => {});
  });
  await debuggerClient.sendCommand('Network.setBypassServiceWorker', { bypass: true });
  await debuggerClient.sendCommand('Fetch.enable', {
    patterns: [
      { urlPattern: `${origin}/*`, resourceType: 'Document' },
      { urlPattern: `${origin}/static/*`, resourceType: 'Script' },
      { urlPattern: `${origin}/static/*`, resourceType: 'Stylesheet' },
      { urlPattern: `${origin}/static/*`, resourceType: 'Image' },
    ],
  });
}

async function createWorkspace(origin) {
  const partition = `persist:campusflow-desktop-${originKey(origin)}`;
  const browserSession = session.fromPartition(partition);
  browserSession.setPermissionRequestHandler((_contents, _permission, callback) => callback(false));
  browserSession.setPermissionCheckHandler(() => false);
  const next = new BrowserWindow({
    width: 1320, height: 860, minWidth: 900, minHeight: 590, show: false,
    title: '行简 · CampusFlow', backgroundColor: '#f1f6f4', icon,
    webPreferences: {
      ...preferences, session: browserSession, preload: path.join(__dirname, 'workspace-preload.cjs'),
      additionalArguments: [`--campusflow-origin=${origin}`],
    },
  });
  setWindowsTaskbarDetails(next);
  const contents = next.webContents;
  const id = contents.id;
  const context = {
    origin, token: await restoreSession(origin), sessionWrite: Promise.resolve(),
    historyOwner: '', historyBlocked: false, historyGeneration: 0,
    backgroundReminders: false, missedReminders: [], window: next, contents,
  };
  context.reminders = createReminderQueue((title) => deliverReminder(context, title));
  windows.set(id, context);
  next.on('hide', () => voiceCapture.cancel(context));
  next.on('minimize', () => voiceCapture.cancel(context));
  next.on('blur', () => voiceCapture.cancel(context));
  contents.on('did-start-navigation', (details) => {
    if (details.isMainFrame && !details.isSameDocument) voiceCapture.cancel(context);
  });
  contents.on('render-process-gone', () => voiceCapture.cancel(context));
  contents.once('destroyed', () => voiceCapture.cancel(context));
  const filter = { urls: [`${origin}/api/v1/*`] };
  browserSession.webRequest.onBeforeSendHeaders(filter, (details, callback) => {
    callback({ requestHeaders: desktopApiHeaders(details, origin, windows.get(details.webContentsId)?.token) });
  });
  browserSession.webRequest.onHeadersReceived(filter, (details, callback) => {
    const responseHeaders = desktopAuthResponseHeaders(details, origin);
    callback(responseHeaders === details.responseHeaders ? {} : { responseHeaders });
  });
  function restrictNavigation(event) {
    if (!allowedNavigation(event.url, origin, event.isMainFrame)) event.preventDefault();
  }
  contents.on('will-frame-navigate', restrictNavigation);
  contents.on('will-redirect', restrictNavigation);
  contents.setWindowOpenHandler(() => ({ action: 'deny' }));
  contents.on('before-input-event', (event, input) => {
    if (input.type !== 'keyDown' || input.isAutoRepeat || !input.control || input.alt || input.shift || input.key !== ',') return;
    event.preventDefault();
    openLauncher();
  });
  next.on('close', (event) => {
    if (quitting || workspace !== next || !context.backgroundReminders || !context.reminders.size || !ensureTray()) return;
    event.preventDefault();
    next.hide();
    tray.displayBalloon({ iconType: 'info', title: '行简提醒', content: '行简在通知区域继续提醒。', noSound: true, respectQuietTime: true });
  });
  next.on('show', () => {
    if (workspace !== next) return;
    discardTray();
    const missed = context.missedReminders.splice(0);
    if (missed.length) contents.send('workspace:reminder-due', missed.length === 1 ? missed[0] : `${missed.length} 项安排已到提醒时间`);
  });
  next.on('closed', () => {
    cancelReminders(context);
    context.historyGeneration++;
    context.token = '';
    windows.delete(id);
    if (workspace === next) { workspace = undefined; discardTray(); }
  });
  try {
    // Initialize the render target before attaching the in-process Fetch session.
    await next.loadURL('about:blank');
    await installBundledFrontend(contents, origin);
    await next.loadURL(`${origin}/`);
    return next;
  } catch (error) {
    if (!next.isDestroyed()) next.destroy();
    throw error;
  }
}

async function connect(input, restore = false) {
  if (connecting) return { error: '正在连接，请稍候。' };
  connecting = true;
  let next;
  try {
    const origin = serverOrigin(input);
    if (!restore) await checkServer(origin, net.fetch);
    next = await createWorkspace(origin);
    await saveOrigin(origin);
    const previous = workspace;
    currentOrigin = origin;
    workspace = next;
    next.show();
    if (previous && !previous.isDestroyed()) previous.destroy();
    if (launcher && !launcher.isDestroyed()) launcher.close();
    return { connected: true };
  } catch (error) {
    if (next && !next.isDestroyed()) next.destroy();
    return { error: error.message };
  } finally {
    connecting = false;
    if (!next && !launcher && !workspace && app.isReady()) openLauncher();
  }
}

function fromLauncher(event) {
  return launcher && !launcher.isDestroyed() && event.sender === launcher.webContents &&
    event.senderFrame === launcher.webContents.mainFrame;
}

function fromWorkspace(event) {
  const context = windows.get(event.sender.id);
  if (!event.senderFrame || event.senderFrame !== event.sender.mainFrame || !context) return null;
  const url = new URL(event.senderFrame.url);
  return url.origin === context.origin && url.pathname === '/' ? context : null;
}

function updateWorkspaceSession(context, token, remember) {
  context.token = token;
  const write = context.sessionWrite.catch(() => {}).then(() => persistSession(context, token, remember));
  context.sessionWrite = write;
  return write;
}

function cancelReminders(context) {
  context.reminders.clear();
  context.missedReminders.length = 0;
  context.backgroundReminders = false;
}

function showWorkspace() {
  if (!workspace || workspace.isDestroyed()) return;
  if (workspace.isMinimized()) workspace.restore();
  workspace.show();
  workspace.focus();
}

function discardTray() {
  if (!tray) return;
  tray.destroy();
  tray = undefined;
}

function ensureTray() {
  if (process.platform !== 'win32') return false;
  if (tray) return true;
  try {
    tray = new Tray(icon);
    tray.setToolTip('行简 · 待办提醒');
    tray.setContextMenu(Menu.buildFromTemplate([
      { label: '打开行简', click: showWorkspace },
      { label: '退出行简', role: 'quit' },
    ]));
    tray.on('click', showWorkspace);
    tray.on('balloon-click', showWorkspace);
    return true;
  } catch {
    discardTray();
    return false;
  }
}

function deliverReminder(context, title) {
  if (!context.token || !context.historyOwner || context.contents.isDestroyed()) return;
  const message = '有一项安排即将开始，打开行简查看。';
  if (tray && workspace === context.window && !workspace.isVisible()) {
    context.missedReminders.push(title);
    if (context.missedReminders.length > 10) context.missedReminders.shift();
    tray.displayBalloon({ iconType: 'info', title: '行简提醒', content: message, respectQuietTime: true });
  } else {
    context.contents.send('workspace:reminder-due', title);
    if (Notification.isSupported()) new Notification({ title: '行简提醒', body: message, icon }).show();
  }
}

async function verifyHistoryOwner(context, owner) {
  const token = context.token;
  const generation = context.historyGeneration;
  if (!token || !isHistoryId(owner)) return false;
  if (context.historyOwner === owner && !context.historyBlocked) return true;
  context.historyBlocked = true;
  try {
    const response = await net.fetch(`${context.origin}/api/v1/me`, {
      redirect: 'error', credentials: 'omit', cache: 'no-store', signal: AbortSignal.timeout(5500),
      headers: { Authorization: `Bearer ${token}`, Accept: 'application/json' },
    });
    if (!response.ok || (await response.json()).user_id !== owner || generation !== context.historyGeneration) return false;
    context.historyOwner = owner;
    context.historyBlocked = true;
    try { return await history.useOwner(context.origin, owner); }
    finally { if (context.historyGeneration === generation) context.historyBlocked = false; }
  } catch { return false; }
}

function registerHistoryIpc() {
  ipcMain.handle('workspace:history-use-owner', (event, owner) => {
    const context = fromWorkspace(event);
    return context ? verifyHistoryOwner(context, owner) : false;
  });
  ipcMain.handle('workspace:history-list', (event) => {
    const context = fromWorkspace(event);
    return context && !context.historyBlocked ? history.list(context.origin, context.historyOwner) : null;
  });
  ipcMain.handle('workspace:history-get', (event, owner, sessionId) => {
    const context = fromWorkspace(event);
    if (!context || context.historyBlocked || (context.historyOwner && context.historyOwner !== owner) ||
      !isHistoryId(owner) || !isHistoryId(sessionId)) return null;
    return history.get(context.origin, owner, sessionId);
  });
  ipcMain.handle('workspace:history-save', async (event, owner, value) => {
    const context = fromWorkspace(event);
    if (!context || !await verifyHistoryOwner(context, owner)) return false;
    return history.save(context.origin, owner, value);
  });
  ipcMain.handle('workspace:history-delete', async (event, owner, sessionId) => {
    const context = fromWorkspace(event);
    if (!context || !isHistoryId(sessionId) || !await verifyHistoryOwner(context, owner)) return false;
    return history.delete(context.origin, owner, sessionId);
  });
  ipcMain.handle('workspace:history-clear', async (event) => {
    const context = fromWorkspace(event);
    if (!context) return false;
    context.historyGeneration++;
    context.historyBlocked = true;
    context.historyOwner = '';
    await history.clear(context.origin);
    return true;
  });
  ipcMain.handle('workspace:reminders', (event, entries, background) => {
    const context = fromWorkspace(event);
    if (!context?.token || !context.historyOwner || typeof background !== 'boolean' || !context.reminders.replace(entries)) return false;
    context.backgroundReminders = background;
    return true;
  });
  ipcMain.handle('workspace:knowledge-source', async (event, address) => {
    const context = fromWorkspace(event);
    if (!context?.token || !context.historyOwner || !allowedKnowledgeSource(address)) return false;
    try { await shell.openExternal(address); return true; }
    catch { return false; }
  });
}

function configureMenu() {
  Menu.setApplicationMenu(Menu.buildFromTemplate([
    { label: '连接', submenu: [
      { label: '设置服务器地址', accelerator: 'CommandOrControl+,', click: openLauncher },
      { label: '退出行简', role: 'quit' },
    ] },
    { label: '编辑', submenu: [
      { label: '撤销', role: 'undo' }, { label: '剪切', role: 'cut' }, { label: '复制', role: 'copy' },
      { label: '粘贴', role: 'paste' }, { label: '全选', role: 'selectAll' },
    ] },
    { label: '查看', submenu: [
      { label: '重新加载', role: 'reload' }, { label: '放大', role: 'zoomIn' },
      { label: '缩小', role: 'zoomOut' }, { label: '恢复缩放', role: 'resetZoom' },
      { label: '全屏', role: 'togglefullscreen' },
    ] },
  ]));
}

app.setName('CampusFlow');
if (process.platform === 'win32') app.setAppUserModelId(windowsAppId);
if (!app.requestSingleInstanceLock()) app.quit();
else {
  app.on('second-instance', () => {
    const win = launcher || workspace;
    if (win?.isMinimized()) win.restore();
    if (win === workspace) showWorkspace();
    else if (win) win.focus();
  });
  app.on('before-quit', () => { quitting = true; discardTray(); });
  app.whenReady().then(async () => {
    history = createOfflineHistory(path.join(app.getPath('userData'), 'offline-history'), {
      available: () => process.platform === 'win32' && safeStorage.isEncryptionAvailable(),
      encrypt: (value) => safeStorage.encryptString(value), decrypt: (value) => safeStorage.decryptString(value),
    });
    configureMenu();
    registerHistoryIpc();
    ipcMain.handle('workspace:voice-start', (event, operation) => {
      const context = fromWorkspace(event);
      if (!Number.isSafeInteger(operation) || !context?.token || !workspace?.isFocused() ||
        context.contents !== workspace.webContents) return 'unavailable';
      return voiceCapture.start(context, (phase, text) => {
        if (!context.contents.isDestroyed()) context.contents.send('workspace:voice-event', { operation, phase, text });
      });
    });
    ipcMain.handle('workspace:voice-stop', (event) => {
      const context = fromWorkspace(event);
      return context ? voiceCapture.stop(context) : false;
    });
    ipcMain.handle('workspace:voice-cancel', (event) => {
      const context = fromWorkspace(event);
      return context ? voiceCapture.cancel(context) : false;
    });
    ipcMain.handle('launcher:address', (event) => fromLauncher(event) ? currentOrigin || DEFAULT_SERVER_ORIGIN : '');
    ipcMain.handle('launcher:connect', (event, address) => fromLauncher(event) ? connect(address) : { error: '无法连接。' });
    ipcMain.handle('workspace:session', async (event, token, remember) => {
      const context = fromWorkspace(event);
      if (!context || !validToken(token) || typeof remember !== 'boolean') throw new Error('无法建立桌面登录。');
      voiceCapture.cancel(context);
      cancelReminders(context);
      context.historyGeneration++;
      context.historyOwner = '';
      context.historyBlocked = true;
      try { return await updateWorkspaceSession(context, token, remember); }
      catch { return { remembered: false, message: '无法更新本机登录状态，本次登录仍可使用。' }; }
    });
    ipcMain.handle('workspace:clear', async (event) => {
      const context = fromWorkspace(event);
      if (!context) throw new Error('无法清除桌面登录。');
      voiceCapture.cancel(context);
      cancelReminders(context);
      context.historyGeneration++;
      context.historyOwner = '';
      try { return await updateWorkspaceSession(context, '', false); }
      catch { return { remembered: false, message: '无法清除已保存的本机登录。' }; }
    });
    currentOrigin = await savedOrigin();
    if (currentOrigin) {
      const result = await connect(currentOrigin, true);
      if (result.connected) return;
      openLauncher();
      void dialog.showMessageBox(launcher, { type: 'info', title: '无法恢复连接', message: '上次的服务暂时不可用', detail: result.error });
    } else openLauncher();
  });
  app.on('window-all-closed', () => { if (!connecting) app.quit(); });
}
