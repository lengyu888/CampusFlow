import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import test from 'node:test';

test('Agent session AST and Markdown strict-type suites run on a host without DevEco', () => {
  const environment = { ...process.env };
  delete environment.CAMPUSFLOW_TYPESCRIPT_PATH;
  delete environment.DEVECO_STUDIO_HOME;
  delete environment.NODE_TEST_CONTEXT;
  const result = spawnSync(process.execPath, ['--import',
    new URL('./helpers/no-deveco-fixture.mjs', import.meta.url).href,
    '--test', '--test-reporter=spec', 'test-agent-session.mjs', 'test-markdown-parser.mjs'], {
    cwd: import.meta.dirname, env: environment, encoding: 'utf8', timeout: 60000
  });
  assert.ifError(result.error);
  assert.equal(result.status, 0, `Portable suites must execute every assertion:\n${result.stdout}\n${result.stderr}`);
  assert.match(result.stdout, /tests\s+30\b/, 'both complete suites must execute, not be skipped');
  assert.match(result.stdout, /skipped\s+0\b/);
});
