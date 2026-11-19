const { readFile } = require('node:fs/promises');
const path = require('node:path');

const assetTypes = {
  '.html': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.svg': 'image/svg+xml',
};
const files = [
  'index.html', 'app.js', 'baidu-map.html', 'baidu-map.css', 'baidu-map.js',
  'desktop.css', 'desktop-campus.css', 'desktop-campus.js',
  'desktop-workflow.css', 'desktop-workflow.js', 'desktop-timetable.css', 'desktop-timetable.js', 'desktop-planning.js',
  'desktop-voice.css', 'desktop-voice.js',
  'desktop-logo.svg', 'desktop-preferences.js', 'gsap.min.js', 'interface.css',
  'markdown.css', 'markdown.js', 'motion.js', 'native.css', 'polish.css', 'redesign.css',
  'styles.css', 'theme.js', 'themes.css', 'vendor/marked-18.1.1.umd.js',
  'vendor/purify-3.4.17.min.js',
];
const authHost = 'https://api.hduhelp.com';
const authPath = '/hduhelp-neo/open-apis/authen/authorize';
const mapPath = '/static/baidu-map.html';
const authEndpoints = new Set(['/api/v1/auth/login', '/api/v1/auth/register']);
const DEFAULT_SERVER_ORIGIN = 'http://47.93.112.200:8000';

function serverOrigin(input) {
  const address = typeof input === 'string' ? input.trim() : '';
  if (!/^https?:\/\//i.test(address) || /[\s\\?#]/u.test(address)) {
    throw new Error('请输入以 https:// 或 http:// 开头的服务地址。');
  }
  const url = parseUrl(address);
  const authority = address.match(/^https?:\/\/([^/]+)/i)?.[1];
  if (!url || !authority || authority.includes('@') || !/^https?:\/\/[^/]+\/?$/i.test(address) || url.pathname !== '/') {
    throw new Error('服务地址仅填写域名或 IP，可带端口。');
  }
  return url.origin;
}

function parseUrl(value) {
  try { return new URL(value); } catch { return null; }
}

function allowedNavigation(address, origin, isMainFrame) {
  const url = parseUrl(address);
  if (!url || url.username || url.password) return false;
  if (!isMainFrame) return url.origin === origin && url.pathname === mapPath;
  if (url.origin === origin) return ['/', '/api/v1/hduhelp/callback'].includes(url.pathname);
  return url.origin === authHost && url.pathname === authPath;
}

function allowedKnowledgeSource(address) {
  if (typeof address !== 'string' || address.length > 400 || /[\s\\?#]/u.test(address) ||
      !/^https:\/\/(?:tsg|nicin|xxgk)\.hdu\.edu\.cn(?:\/|$)/.test(address)) return false;
  const url = parseUrl(address);
  return Boolean(url && !url.username && !url.password && !url.port);
}

async function loadAssets(folder) {
  return new Map(await Promise.all(files.map(async (file) => {
    const source = await readFile(path.join(folder, file));
    const body = file === 'index.html'
      ? Buffer.from(source.toString('utf8').replace(/<html\b([^>]*)>/, '<html$1 data-platform="windows">'))
      : source;
    const type = assetTypes[path.extname(file)];
    return [file === 'index.html' ? '/' : `/static/${file}`, { body: body.toString('base64'), type }];
  })));
}

function validToken(token) {
  return typeof token === 'string' && token.length >= 20 && token.length <= 2048 && /^[A-Za-z0-9._~+/-]+=*$/.test(token);
}

function desktopApiHeaders(details, origin, token) {
  const request = parseUrl(details.url);
  if (request?.origin !== origin || !request.pathname.startsWith('/api/v1/')) return details.requestHeaders;
  const headers = { ...details.requestHeaders };
  for (const key of Object.keys(headers)) {
    if (key.toLowerCase() !== 'cookie') continue;
    const cookies = headers[key].split(';').filter((item) => !/^\s*campusflow_session\s*=/.test(item));
    if (cookies.length) headers[key] = cookies.join(';').trim();
    else delete headers[key];
  }
  if (!validToken(token) || details.initiatorOrigin !== origin || details.resourceType !== 'xhr' || authEndpoints.has(request.pathname)) {
    return headers;
  }
  for (const key of Object.keys(headers)) if (key.toLowerCase() === 'authorization') delete headers[key];
  headers.Authorization = `Bearer ${token}`;
  return headers;
}

function desktopAuthResponseHeaders(details, origin) {
  const request = parseUrl(details.url);
  const headers = details.responseHeaders;
  if (!headers || request?.origin !== origin || !authEndpoints.has(request.pathname)) return headers;
  const result = { ...headers };
  for (const key of Object.keys(result)) {
    if (key.toLowerCase() !== 'set-cookie') continue;
    const cookies = result[key].filter((item) => !/^\s*campusflow_session\s*=/.test(item));
    if (cookies.length) result[key] = cookies;
    else delete result[key];
  }
  return result;
}

function bundledAsset(request, origin, assets) {
  const url = parseUrl(request.url);
  if (request.method !== 'GET' || url?.origin !== origin || url.username || url.password) return undefined;
  return assets.get(url.pathname);
}

async function checkServer(origin, fetcher) {
  let response;
  let health;
  try {
    response = await fetcher(`${origin}/health`, {
      signal: AbortSignal.timeout(6500), cache: 'no-store', credentials: 'omit', redirect: 'error',
      headers: { Accept: 'application/json' },
    });
    if (response.ok && response.headers.get('content-type')?.includes('application/json')) {
      health = await response.json();
    }
  } catch {
    throw new Error('无法连接服务，请检查地址、网络和服务器证书。');
  }
  if (health?.status !== 'ok' || health.api_key_mode !== 'encrypted_account' || !Array.isArray(health.supported_models)) {
    throw new Error('该地址未返回行简服务信息，请核对后端地址和端口。');
  }
}

module.exports = { allowedKnowledgeSource, allowedNavigation, bundledAsset, checkServer, DEFAULT_SERVER_ORIGIN, desktopApiHeaders, desktopAuthResponseHeaders, loadAssets, serverOrigin, validToken };
