import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { execFileSync } from 'node:child_process';
import { test } from 'node:test';
const source = readFileSync(new URL('../entry/src/main/ets/utils/QuickCaptureParser.ets', import.meta.url), 'utf8');
const moduleUrl = `data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source)).toString('base64')}`;
const { parseQuickCapture: parse, captureEndAt } = await import(moduleUrl);
const anchor = '2026-10-18'; // Sunday, fixed Shanghai date.
const has = (result, code) => result.issues.some(issue => issue.code === code);

test('clear Chinese date/time/duration produces editable fields and retains original verbatim', () => {
  const result = parse('  明晚八点复习一小时  ', anchor);
  assert.deepEqual([result.title, result.date, result.time, result.durationMinutes, result.timezone],
    ['复习', '2026-10-19', '20:00', 60, 'Asia/Shanghai']);
  assert.equal(result.originalText, '  明晚八点复习一小时  '); assert.deepEqual(result.issues, []);
  assert.equal(captureEndAt(result.date, result.time, result.durationMinutes), '2026-10-19T21:00:00+08:00');
});
test('afternoon without an exact time is never converted to 15:00', () => {
  const result = parse('周五下午交报告', anchor);
  assert.equal(result.date, '2026-10-23'); assert.equal(result.time, '');
  assert.equal(result.durationMinutes, null); assert.ok(has(result, 'TIME_REQUIRED'));
  assert.equal(result.originalText, '周五下午交报告');
});
test('week rules are explicit, including Sunday, this-week past and same-day anchor', () => {
  assert.equal(parse('周五交报告', anchor).date, '2026-10-23');
  assert.equal(parse('本周五交报告', anchor).date, '2026-10-16');
  assert.ok(has(parse('本周五交报告', anchor), 'DATE_IN_PAST'));
  assert.equal(parse('下周一复习', anchor).date, '2026-10-19');
  assert.equal(parse('星期天整理', anchor).date, anchor);
  assert.equal(parse('周五08:00开会', '2026-10-23').date, '2026-10-23', 'does not roll a same-day time into next week');
});
test('relative dates remain based on the supplied draft anchor over month and year boundaries', () => {
  assert.equal(parse('明天交报告', '2026-12-31').date, '2027-01-01');
  assert.equal(parse('后天复习', '2028-02-28').date, '2028-03-01');
  assert.equal(parse('今天复习', '2026-10-18').date, '2026-10-18');
});
test('invalid anchors and impossible dates cannot be normalized into another day', () => {
  for (const value of ['2026-02-30', '0000-01-01', '2026-13-01', '99999-01-01']) {
    assert.ok(has(parse('明天复习', value), 'ANCHOR_INVALID'));
    const result = parse(`${value}复习`, anchor); assert.equal(result.date, '');
  }
});
test('bare ambiguous hours and approximate times remain unresolved', () => {
  for (const text of ['明天八点复习', '明天八九点复习', '明天晚上十二点复习', '明天上午十二点复习',
    '明天约20:00复习', '明天20:00左右复习', '明天120:00复习', '明天25:00复习', '明天20:99复习']) {
    const result = parse(text, anchor); assert.equal(result.time, '', text); assert.ok(result.requiresReview, text);
  }
});
test('explicit 24h and qualified word clocks support half-hours and exact minutes', () => {
  for (const [text, time] of [['明天7:30复习', '07:30'], ['今天上午九点半开会', '09:30'],
    ['今天下午三点十五分复习', '15:15'], ['今天中午十二点吃饭', '12:00'], ['今天二十点复习', '20:00']]) {
    assert.equal(parse(text, anchor).time, time, text);
  }
});
test('explicit durations are positive integer minutes bounded to one day', () => {
  for (const [text, minutes] of [['明晚八点复习半小时', 30], ['今天20:00复习1.5小时', 90], ['今天20:00复习二十五分钟', 25]]) {
    assert.equal(parse(text, anchor).durationMinutes, minutes);
  }
  for (const text of ['复习0分钟', '复习负一小时', '复习-1小时', '复习一百小时', '复习25小时', '复习半分钟', '复习约一小时', '复习第一小时内容']) {
    assert.equal(parse(text, anchor).durationMinutes, null, text);
  }
});
test('multiple competing fields and recurring schedules are not silently chosen', () => {
  assert.equal(parse('明天后天复习', anchor).date, '');
  assert.equal(parse('今天20:00或21:00复习', anchor).time, '');
  assert.equal(parse('今天20:00复习1小时30分钟', anchor).durationMinutes, null);
  const recurring = parse('每周五下午三点复习', anchor);
  assert.equal(recurring.date, ''); assert.ok(recurring.unsupported.length > 0);
});
test('missing date/time is retained as a draft, without substituting today or a default duration', () => {
  const undated = parse('交报告', anchor); assert.equal(undated.title, '交报告'); assert.equal(undated.date, ''); assert.equal(undated.time, '');
  const timeOnly = parse('20:00复习', anchor); assert.equal(timeOnly.date, ''); assert.ok(has(timeOnly, 'DATE_REQUIRED'));
  const durationOnly = parse('复习25分钟', anchor); assert.equal(durationOnly.durationMinutes, 25); assert.equal(durationOnly.time, '');
  assert.equal(captureEndAt('', '20:00', 25), null); assert.equal(captureEndAt(anchor, '20:00', null), null);
});
test('manual 23:59 without duration is explicitly flagged instead of becoming an all-day task', () => {
  const result = parse('今天23:59提交', anchor); assert.equal(result.time, '23:59'); assert.equal(result.durationMinutes, null);
  assert.ok(has(result, 'TIME_PRECISION_REQUIRED'));
  const bounded = parse('今天23:59复习一分钟', anchor); assert.equal(bounded.durationMinutes, 1);
  assert.equal(has(bounded, 'TIME_PRECISION_REQUIRED'), false);
  assert.equal(captureEndAt(anchor, '23:59', 1), '2026-10-19T00:00:00+08:00');
});
test('duration calculation crosses midnight and is independent of the device timezone', () => {
  const script = `import {parseQuickCapture,captureEndAt} from ${JSON.stringify(moduleUrl)};console.log(JSON.stringify([parseQuickCapture('明晚八点复习一小时','2026-10-18'),captureEndAt('2026-12-31','23:30',120)]));`;
  const results = ['UTC', 'America/Los_Angeles', 'Asia/Shanghai'].map(TZ => execFileSync(process.execPath, ['--input-type=module', '-e', script], { env: { ...process.env, TZ }, encoding: 'utf8' }));
  assert.equal(new Set(results).size, 1); assert.equal(JSON.parse(results[0])[1], '2027-01-01T01:30:00+08:00');
});
test('names are never truncated and date/time-only input asks for a title', () => {
  const title = '😀'.repeat(121); const result = parse(title, anchor);
  assert.equal(result.title, title); assert.ok(has(result, 'TITLE_TOO_LONG'));
  assert.ok(has(parse('明天20:00一小时', anchor), 'TITLE_REQUIRED'));
  assert.equal(parse('复习第一小时内容', anchor).title, '复习第一小时内容');
});
test('a conflicting period and numeric clock are unresolved, while a consistent qualifier is removed from the title', () => {
  for (const text of ['明天下午08:00复习一小时', '明天早上20:00复习一小时']) {
    const result = parse(text, anchor); assert.equal(result.time, ''); assert.ok(has(result, 'TIME_PERIOD_CONFLICT'));
  }
  const result = parse('明天下午14:00复习一小时', anchor);
  assert.equal(result.time, '14:00'); assert.equal(result.title, '复习');
});
test('unsupported descriptions remain visible in the issue list used by the form', () => {
  for (const text of ['每周五复习', '下课后复习', '看书然后跑步']) {
    const result = parse(text, anchor); assert.ok(result.unsupported.length > 0);
    result.unsupported.forEach(message => assert.ok(result.issues.some(issue => issue.message === message)));
  }
});
test('end calculation rejects overflow or invalid input instead of inventing an end', () => {
  assert.equal(captureEndAt('9999-12-31', '23:59', 2), null);
  assert.equal(captureEndAt('2026-02-30', '08:00', 25), null);
  assert.equal(captureEndAt(anchor, '24:00', 25), null);
});
