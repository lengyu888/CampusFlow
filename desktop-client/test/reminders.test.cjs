const test = require('node:test');
const assert = require('node:assert/strict');
const { createReminderQueue } = require('../reminders.cjs');

test('only upcoming reminders are scheduled and a failed replacement retains the prior schedule', (t) => {
  const now = Date.UTC(2026, 10, 14);
  t.mock.timers.enable({ apis: ['Date', 'setTimeout'], now });
  const delivered = [];
  const queue = createReminderQueue((title) => delivered.push(title));
  assert.equal(queue.replace([
    { id: 'task-past', title: '已过期', at: now - 1 },
    { id: 'task-first', title: '近期课程', at: now + 300 },
    { id: 'task-outside', title: '超过提醒期限', at: now + 367 * 86_400_000 },
  ]), true);
  assert.equal(queue.size, 1);
  assert.equal(queue.replace([{ id: 'task-bad', title: '', at: now + 400 }]), false);
  t.mock.timers.tick(300);
  assert.deepEqual(delivered, ['近期课程']);
  assert.equal(queue.size, 0);
});

test('updates cancel superseded reminders and logout-style clearing cancels pending reminders', (t) => {
  const now = Date.UTC(2026, 10, 14);
  t.mock.timers.enable({ apis: ['Date', 'setTimeout'], now });
  const delivered = [];
  const queue = createReminderQueue((title) => delivered.push(title));
  const old = { id: 'task-first', title: '原安排', at: now + 100 };
  assert.equal(queue.replace([old]), true);
  assert.equal(queue.replace([old, old]), false);
  assert.equal(queue.replace([{ ...old, title: '改期后', at: now + 200 }]), true);
  t.mock.timers.tick(100);
  assert.deepEqual(delivered, []);
  queue.clear();
  t.mock.timers.tick(100);
  assert.deepEqual(delivered, []);
});

test('a reminder beyond the Node timer limit is retained until its actual time', (t) => {
  const now = Date.UTC(2026, 10, 14);
  t.mock.timers.enable({ apis: ['Date', 'setTimeout'], now });
  const delivered = [];
  const queue = createReminderQueue((title) => delivered.push(title));
  assert.equal(queue.replace([{ id: 'task-december', title: '期末复习', at: now + 30 * 86_400_000 }]), true);
  t.mock.timers.tick(2_147_483_647);
  assert.deepEqual(delivered, []);
  assert.equal(queue.size, 1);
  t.mock.timers.tick(30 * 86_400_000 - 2_147_483_647);
  assert.deepEqual(delivered, ['期末复习']);
  assert.equal(queue.size, 0);
});
