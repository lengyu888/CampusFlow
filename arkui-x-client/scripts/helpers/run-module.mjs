import { execFileSync } from 'node:child_process';

// Source can contain large nested data URLs. Send it through stdin, not the
// Windows command line; keep a separate process so each test can set its TZ.
export function runModuleSource(source, options = {}) {
  return execFileSync(process.execPath, ['--input-type=module'], {
    ...options,
    input: source,
    encoding: 'utf8'
  });
}
