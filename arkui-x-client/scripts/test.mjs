import { readdirSync } from 'node:fs';
import { spawnSync } from 'node:child_process';

// Enumerate explicitly so the same command works in shells without glob expansion.
// These tests execute shared logic and page controllers, not native ArkUI rendering.
const tests = readdirSync(import.meta.dirname).filter(name => /^test-.+\.mjs$/.test(name)).sort();
if (tests.length === 0) throw new Error('No client tests found');
const result = spawnSync(process.execPath, ['--test', ...tests], {
  cwd: import.meta.dirname,
  stdio: 'inherit'
});
if (result.error) throw result.error;
process.exitCode = result.status ?? 1;
