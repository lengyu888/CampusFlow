const assert = require('node:assert/strict');
const path = require('node:path');
const { test } = require('node:test');
const { allowedKnowledgeSource, allowedNavigation, bundledAsset, checkServer, DEFAULT_SERVER_ORIGIN, desktopApiHeaders, desktopAuthResponseHeaders, loadAssets, serverOrigin, validToken } = require('../server.cjs');

test('server address is a normalized HTTP or HTTPS origin', () => {
  assert.equal(serverOrigin(' HTTP://127.0.0.1:8000/ '), 'http://127.0.0.1:8000');
  assert.equal(serverOrigin('https://[::1]:8000'), 'https://[::1]:8000');
  assert.equal(serverOrigin(DEFAULT_SERVER_ORIGIN), DEFAULT_SERVER_ORIGIN);
  for (const value of ['file:///tmp/test', 'https://user:pass@example.com', 'https://example.com/a',
    'https://example.com/a/..', 'https://example.com?token=secret', 'https://example.com#part', 'http://example.com\\host']) {
    assert.throws(() => serverOrigin(value));
  }
});

test('desktop Bearer uses only same-origin API fetches and omits stale session cookies', () => {
  const origin = DEFAULT_SERVER_ORIGIN;
  const token = 'fake_synthetic_token_abcdefghijklmnopqrstuvwxyz';
  const details = { url: `${origin}/api/v1/me`, initiatorOrigin: origin, resourceType: 'xhr',
    requestHeaders: { Cookie: 'theme=blue; campusflow_session=browser; other=retained', Accept: 'application/json' } };
  assert.deepEqual(desktopApiHeaders(details, origin, token), {
    Cookie: 'theme=blue; other=retained', Accept: 'application/json', Authorization: `Bearer ${token}`,
  });
  assert.equal(desktopApiHeaders({ ...details, url: `${origin}/api/v1/auth/login` }, origin, token).Authorization, undefined);
  assert.equal(desktopApiHeaders({ ...details, initiatorOrigin: 'https://external.example' }, origin, token).Authorization, undefined);
  assert.equal(desktopApiHeaders({ ...details, resourceType: 'mainFrame' }, origin, token).Authorization, undefined);
  assert.equal(desktopApiHeaders({ ...details, url: 'https://external.example/api/v1/me' }, origin, token).Authorization, undefined);
  assert.equal(desktopApiHeaders(details, origin, 'invalid\nheader-value-fake').Authorization, undefined);
  assert.equal(validToken(null), false);
});

test('desktop auth strips only its session cookie on login and registration', () => {
  const origin = DEFAULT_SERVER_ORIGIN;
  const responseHeaders = {
    'Set-Cookie': ['campusflow_session=fake_cookie; Secure; HttpOnly', 'other=retained'],
    'Content-Type': ['application/json'],
  };
  for (const pathname of ['/api/v1/auth/login', '/api/v1/auth/register']) {
    assert.deepEqual(desktopAuthResponseHeaders({ url: origin + pathname, responseHeaders }, origin), {
      'Set-Cookie': ['other=retained'], 'Content-Type': ['application/json'],
    });
  }
  assert.equal(desktopAuthResponseHeaders({ url: `${origin}/api/v1/me`, responseHeaders }, origin), responseHeaders);
});

test('only exact first-party assets are bundled, with cookies and API traffic left to Chromium', () => {
  const origin = 'https://campus.example.com';
  const assets = new Map([['/', 1], ['/static/app.js', 2]]);
  const resolve = (url, method = 'GET') => bundledAsset({ url, method }, origin, assets);
  assert.equal(resolve(`${origin}/?hduhelp=connected`), 1);
  assert.equal(resolve(`${origin}/static/app.js?v=20`), 2);
  assert.equal(resolve(`${origin}/static/app.js`, 'POST'), undefined);
  assert.equal(resolve(`${origin}/api/v1/me`), undefined);
  assert.equal(resolve('https://campus.example.com.evil.test/static/app.js'), undefined);
  assert.equal(resolve('file:///static/app.js'), undefined);
});

test('the desktop packages every local resource referenced by the shared Web entry', async () => {
  const folder = path.resolve(__dirname, '../../agent-service/src/campusflow_agent/web');
  const assets = await loadAssets(folder);
  const html = Buffer.from(assets.get('/').body, 'base64').toString('utf8');
  assert.match(html, /<html[^>]*data-platform="windows"/);
  assert.match(html, /\/static\/polish\.css/);
  for (const [, resource] of html.matchAll(/(?:src|href)="(\/static\/[^"?]+)/g)) {
    assert.ok(assets.has(resource), `Missing bundled resource: ${resource}`);
  }
});

test('workspace navigation is limited to its server and the official authorization entry', () => {
  const origin = 'http://127.0.0.1:8000';
  assert.equal(allowedNavigation(`${origin}/?hduhelp=connected`, origin, true), true);
  assert.equal(allowedNavigation(`${origin}/api/v1/hduhelp/callback?code=fixture`, origin, true), true);
  assert.equal(allowedNavigation(`${origin}/static/baidu-map.html?managed=1`, origin, false), true);
  assert.equal(allowedNavigation(`${origin}/api/v1/me`, origin, true), false);
  assert.equal(allowedNavigation('https://api.hduhelp.com/hduhelp-neo/open-apis/authen/authorize', origin, true), true);
  assert.equal(allowedNavigation('https://api.hduhelp.com/anything-else', origin, true), false);
  assert.equal(allowedNavigation('https://untrusted.example/', origin, false), false);
});

test('campus sources open only reviewed HTTPS domains without URL credentials or parameters', () => {
  assert.equal(allowedKnowledgeSource('https://tsg.hdu.edu.cn/campus.htm'), true);
  assert.equal(allowedKnowledgeSource('https://nicin.hdu.edu.cn/guide/list.htm'), true);
  assert.equal(allowedKnowledgeSource('https://xxgk.hdu.edu.cn/guide/list.htm'), true);
  for (const address of ['http://tsg.hdu.edu.cn/', 'https://tsg.hdu.edu.cn:443/', 'https://tsg.hdu.edu.cn@other.example/',
    'https://other.example@tsg.hdu.edu.cn/', 'https://tsg.hdu.edu.cn.example/', 'https://tsg.hdu.edu.cn/\nredirect',
    'https://tsg.hdu.edu.cn/?next=elsewhere', 'https://tsg.hdu.edu.cn/#section']) {
    assert.equal(allowedKnowledgeSource(address), false);
  }
});

test('health probe carries no credentials or redirects and checks the service signature', async () => {
  const origin = 'http://127.0.0.1:8000';
  await checkServer(origin, async (url, options) => {
    assert.equal(url, `${origin}/health`);
    assert.equal(options.credentials, 'omit');
    assert.equal(options.redirect, 'error');
    return Response.json({ status: 'ok', api_key_mode: 'encrypted_account', supported_models: [] });
  });
  await assert.rejects(checkServer(origin, async () => Response.json({ status: 'ok' })), /行简服务/);
  await assert.rejects(checkServer(origin, async () => { throw new Error('fixture outage'); }), /无法连接/);
});
