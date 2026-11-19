import { cp, glob, mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { createReadStream, existsSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { packager } from '@electron/packager';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const { version, devDependencies } = require('../package.json');
const client = fileURLToPath(new URL('../', import.meta.url));
const repository = path.resolve(client, '..');
const output = path.join(repository, 'output', 'windows-desktop');
const work = await mkdtemp(path.join(os.tmpdir(), 'campusflow-package-'));
const release = `V${version.replace(/\.0$/, '')}`;
const archive = path.join(output, `CampusFlow-Windows-x64-${release}.zip`);
const electronVersion = devDependencies.electron;

try {
  const stage = path.join(work, 'app');
  await mkdir(stage);
  for (const file of ['main.cjs', 'server.cjs', 'history.cjs', 'reminders.cjs', 'voice.cjs', 'voice.ps1',
    'preload.cjs', 'workspace-preload.cjs', 'launcher.html', 'launcher.css', 'launcher.js']) {
    await cp(path.join(client, file), path.join(stage, file));
  }
  await cp(path.join(client, 'assets'), path.join(stage, 'assets'), { recursive: true });
  await cp(path.join(repository, 'agent-service/src/campusflow_agent/web'), path.join(stage, 'web'), { recursive: true });
  await writeFile(path.join(stage, 'package.json'), JSON.stringify({ name: 'campusflow', version, main: 'main.cjs' }));
  const runtimeName = `electron-v${electronVersion}-win32-x64.zip`;
  const cache = process.env.LOCALAPPDATA && path.join(process.env.LOCALAPPDATA, 'electron', 'Cache');
  let cachedDirectory;
  if (cache && existsSync(cache)) {
    for await (const entry of glob(`*/${runtimeName}`, { cwd: cache })) {
      cachedDirectory = path.dirname(path.join(cache, entry));
      break;
    }
  }
  const [build] = await packager({
    dir: stage, out: work, name: 'CampusFlow', executableName: 'CampusFlow',
    icon: path.join(stage, 'assets', 'app.ico'),
    electronVersion, electronZipDir: cachedDirectory, platform: 'win32', arch: 'x64', asar: true,
    win32metadata: { FileDescription: 'CampusFlow', ProductName: 'CampusFlow' },
  });
  await cp(path.join(client, 'README.md'), path.join(build, '快速开始.md'));
  await mkdir(output, { recursive: true });
  const pendingArchive = path.join(work, path.basename(archive));
  const zip = spawnSync('tar.exe', ['-a', '-cf', pendingArchive, '-C', path.dirname(build), path.basename(build)], { stdio: 'inherit' });
  if (zip.status !== 0) throw zip.error || new Error(`ZIP creation failed (${zip.status})`);
  await cp(pendingArchive, archive);
  const digest = createHash('sha256');
  for await (const chunk of createReadStream(archive)) digest.update(chunk);
  await writeFile(`${archive}.sha256`, `${digest.digest('hex')}  ${path.basename(archive)}\n`);
  console.log(archive);
} finally {
  await rm(work, { recursive: true, force: true });
}
