import assert from 'node:assert/strict';
import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, realpathSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { test } from 'node:test';
import { runModuleSource } from './helpers/run-module.mjs';
import { findHostCommand, spawnHostCommandSync } from './helpers/host-command.mjs';
import { journeyPython } from './helpers/ux11-journey.mjs';

const client = fileURLToPath(new URL('../', import.meta.url));
function temporary(t) {
  const folder = mkdtempSync(path.join(tmpdir(), 'campusflow-portability-'));
  t.after(() => rmSync(folder, { recursive: true, force: true }));
  const root = path.join(folder, '行简 空格目录');
  mkdirSync(root);
  return realpathSync(root);
}
function copy(root, relative) {
  const destination = path.join(root, relative);
  mkdirSync(path.dirname(destination), { recursive: true });
  cpSync(path.join(client, relative), destination, { recursive: true });
}
function setLineEndings(folder, ending) {
  for (const item of readdirSync(folder, { withFileTypes: true })) {
    const file = path.join(folder, item.name);
    if (item.isDirectory()) setLineEndings(file, ending);
    else if (item.name.endsWith('.ets')) writeFileSync(file, readFileSync(file, 'utf8').replace(/\r?\n/g, ending));
  }
}

for (const [name, ending] of [['LF', '\n'], ['CRLF', '\r\n']]) {
  test(`existing driver assertions and build-plan paths work from a Chinese/space checkout with ${name}`, t => {
    const root = temporary(t);
    for (const file of ['scripts', 'entry/src/main/ets', 'build-profile.json5',
      'entry/src/main/module.json5', '.arkui-x/arkui-x-config.json5']) copy(root, file);
    setLineEndings(path.join(root, 'entry/src/main/ets'), ending);
    const tests = ['test-focus-file-store.mjs', 'test-harmony-reminders.mjs',
      'test-reminder-coordinator.mjs', 'test-native-build-plan.mjs'];
    const env = { ...process.env };
    delete env.NODE_TEST_CONTEXT; // Start a real child runner, not a nested test-worker protocol.
    const result = spawnSync(process.execPath, ['--test', '--test-reporter=tap', ...tests], {
      cwd: path.join(root, 'scripts'), env, encoding: 'utf8', timeout: 60000, maxBuffer: 2 * 1024 * 1024
    });
    assert.equal(result.error, undefined, result.error?.message);
    assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
    assert.match(result.stdout, /# fail 0\b/);
    assert.match(result.stdout, /# skipped 0\b/);
  });
}

test('large module source travels through stdin with no source in process arguments', t => {
  const root = temporary(t);
  const payload = '中文 payload 📚'.repeat(6000);
  const moduleUrl = `data:text/javascript;base64,${Buffer.from(`export default ${JSON.stringify(payload)}`).toString('base64')}`;
  const source = `import value from ${JSON.stringify(moduleUrl)};console.log(JSON.stringify({value,argv:process.argv.slice(1),cwd:process.cwd()}));`;
  assert.ok(source.length > 32767);
  const result = JSON.parse(runModuleSource(source, { cwd: root }));
  assert.equal(result.value, payload);
  assert.deepEqual(result.argv, []);
  assert.equal(result.cwd, root);
});

test('Windows file URL conversion preserves the drive and decodes spaces and Chinese names', () => {
  assert.equal(fileURLToPath(new URL('file:///C:/Users/%E5%AD%A6%E9%95%BF/My%20Project/build-native.mjs'), { windows: true }),
    'C:\\Users\\学长\\My Project\\build-native.mjs');
});

test('host command discovery accepts Windows Path/PATHEXT and does not execute candidates', t => {
  const root = temporary(t);
  const command = path.join(root, 'ace.CMD');
  writeFileSync(command, '@echo THIS MUST NOT RUN\r\n');
  assert.equal(findHostCommand('ace', { platform: 'win32', env: { Path: `"${root}"`, PATHEXT: '.EXE;.CMD;.BAT' } }), command);
  assert.equal(findHostCommand('missing', { platform: 'win32', env: { Path: root } }), undefined);
});

test('journey chooses the correct existing venv layout or platform fallback and respects explicit Python', t => {
  const root = temporary(t);
  assert.equal(journeyPython(root, {}, 'win32'), 'python');
  assert.equal(journeyPython(root, {}, 'linux'), 'python3');
  for (const [platform, suffix] of [['win32', ['Scripts', 'python.exe']], ['linux', ['bin', 'python']]]) {
    const python = path.join(root, 'agent-service', '.venv', ...suffix);
    mkdirSync(path.dirname(python), { recursive: true }); writeFileSync(python, 'synthetic marker only');
    assert.equal(journeyPython(root, {}, platform), python);
    assert.equal(journeyPython(root, { CAMPUSFLOW_TEST_PYTHON: 'explicit-python' }, platform), 'explicit-python');
  }
});

test('Windows .cmd launcher executes fixed flags from a path with spaces without a native SDK',
  { skip: process.platform !== 'win32' }, t => {
    const root = temporary(t);
    const command = path.join(root, 'fake-ace.cmd');
    writeFileSync(command, '@echo off\r\necho fake-ace %*\r\nexit /b 0\r\n');
    const result = spawnHostCommandSync(command, ['build', 'apk', '--debug'], { encoding: 'utf8' });
    assert.equal(result.error, undefined, result.error?.message);
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /fake-ace "build" "apk" "--debug"/);
    assert.throws(() => spawnHostCommandSync(command, ['build&exit']), /fixed build\/probe flags/);
  });

test('host command runner retains native executable arguments and exit status', t => {
  const root = temporary(t);
  const script = path.join(root, '参数.mjs');
  writeFileSync(script, 'console.log(JSON.stringify(process.argv.slice(2)));process.exitCode=7;');
  const result = spawnHostCommandSync(process.execPath, [fileURLToPath(pathToFileURL(script)), '中文 空格'], { encoding: 'utf8' });
  assert.equal(result.status, 7);
  assert.deepEqual(JSON.parse(result.stdout), ['中文 空格']);
});

test('Windows build wrapper uses an existing PATH .cmd and keeps all writes inside its fixture',
  { skip: process.platform !== 'win32' }, t => {
    const root = temporary(t);
    for (const file of ['scripts/build-native.mjs', 'scripts/helpers/host-command.mjs',
      'build-profile.json5', 'entry/src/main/module.json5', '.arkui-x/arkui-x-config.json5']) copy(root, file);
    const bin = path.join(root, '假的 命令'); mkdirSync(bin);
    writeFileSync(path.join(bin, 'ace.cmd'), '@echo off\r\nif "%~1"=="--version" (echo synthetic-ace-1&exit /b 0)\r\necho synthetic-build %*\r\nexit /b 0\r\n');
    const env = { ...process.env };
    for (const key of Object.keys(env)) if (key.toUpperCase() === 'PATH') delete env[key];
    delete env.CAMPUSFLOW_ACE_BIN;
    env.Path = bin; env.PATHEXT = '.EXE;.CMD;.BAT';
    const result = spawnSync(process.execPath, [path.join(root, 'scripts/build-native.mjs'), 'android', '--execute'], {
      cwd: tmpdir(), env, encoding: 'utf8', timeout: 15000
    });
    assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
    const receipt = JSON.parse(readFileSync(path.join(root, '.native-build-android.local.json'), 'utf8'));
    assert.equal(receipt.ace, 'synthetic-ace-1');
    assert.equal(receipt.device_verified, false);
    assert.deepEqual(receipt.command, ['ace', 'build', 'apk', '--debug']);
  });

test('Windows PowerShell HAP wrapper anchors the project directory using only a fake local Hvigor',
  { skip: process.platform !== 'win32' }, t => {
    const root = temporary(t);
    for (const file of ['scripts/build-hap.ps1', 'scripts/arkuix-sdk-path.ps1']) copy(root, file);
    const devEco = path.join(root, '假的 DevEco');
    const hvigor = path.join(devEco, 'tools/hvigor/bin/hvigorw.bat');
    for (const directory of [path.dirname(hvigor), path.join(devEco, 'tools/node'), path.join(devEco, 'jbr'), path.join(devEco, 'sdk')]) mkdirSync(directory, { recursive: true });
    const sdk = path.join(root, '假的 SDK');
    const marker = path.join(sdk, '24/arkui-x/sdkConfig.json');
    mkdirSync(path.dirname(marker), { recursive: true }); writeFileSync(marker, '{}');
    // This is a synthetic text marker in a disposable fixture, never a HAP build.
    writeFileSync(hvigor, '@echo off\r\nif "%~1"=="--stop-daemon" exit /b 0\r\nmkdir "entry\\build\\default\\outputs\\default"\r\necho synthetic-test-marker>"entry\\build\\default\\outputs\\default\\fixture.hap"\r\nexit /b 0\r\n');
    const powershell = path.join(process.env.SystemRoot || 'C:\\Windows', 'System32/WindowsPowerShell/v1.0/powershell.exe');
    const result = spawnSync(powershell, ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
      path.join(root, 'scripts/build-hap.ps1'), '-SdkPath', sdk], {
      cwd: path.dirname(root), env: { ...process.env, DEVECO_STUDIO_HOME: devEco }, encoding: 'utf8', timeout: 15000
    });
    assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
    assert.match(readFileSync(path.join(root, 'entry/build/default/outputs/default/fixture.hap'), 'utf8'), /synthetic-test-marker/);
    assert.equal(existsSync(path.join(path.dirname(root), 'entry/build/default/outputs/default/fixture.hap')), false);
  });
