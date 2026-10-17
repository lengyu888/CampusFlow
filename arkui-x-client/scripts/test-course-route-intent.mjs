import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { test } from 'node:test';
const source = readFileSync(new URL('../entry/src/main/ets/utils/CourseRouteIntent.ets', import.meta.url), 'utf8').replace(/^import [^\n]+;\r?\n/gm, '');
const { matchCoursePlace } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source)).toString('base64')}`);
const place = (id, name, aliases = []) => ({ place_id: id, name, aliases, category: '教学楼', zone: '教学区' });
const data = { package: { package_id: 'hdu-xiasha', school: '杭州电子科技大学', campus: '下沙校区', version: 'fixture' }, places: [
  place('teaching-7', '第7教研楼（信博楼）', ['7教', '第七教研楼', '信博楼']),
  place('teaching-3', '第3教研楼（信礼楼）', ['3教', '第三教研楼', '信礼楼'])
] };
const intent = location => ({ requestId: 1, school: data.package.school, campus: data.package.campus,
  timetableRevision: 'a'.repeat(64), evidence: [], course: { date: '2026-10-19', title: '同名课程', start_time: '08:00', end_time: '09:00', location, teacher: '教师' } });
test('exact aliases and a real building name with a bounded classroom suffix match one node', () => {
  for (const text of ['7教', '第七教研楼', '第7教研楼(信博楼)', '第7教研楼北406', '下沙校区 第7教研楼311-313']) {
    const result = matchCoursePlace(intent(text), data); assert.equal(result.status, 'unique', text);
    assert.deepEqual(result.candidateIds, ['teaching-7']); assert.equal(result.originalLocation, text);
  }
  assert.equal(matchCoursePlace(intent('第7教研楼北406'), data).remainingRoomText, '北406');
});
test('same course title does not control destination; full location is used and inputs stay unchanged', () => {
  const first = intent('第7教研楼北406'), second = intent('3教301'); const before = JSON.stringify([first, second, data]);
  assert.deepEqual(matchCoursePlace(first, data).candidateIds, ['teaching-7']);
  assert.deepEqual(matchCoursePlace(second, data).candidateIds, ['teaching-3']); assert.equal(JSON.stringify([first, second, data]), before);
});
test('numeric boundaries, generic categories and absent rooms do not invent map nodes', () => {
  for (const text of ['17教301', '教学楼', '北406', '', '第7教研楼附近', '第7教研楼/未知楼']) {
    assert.equal(matchCoursePlace(intent(text), data).status, 'missing', text);
  }
});
test('multiple actual places or shared aliases remain explicit choices', () => {
  const result = matchCoursePlace(intent('7教/3教'), data); assert.equal(result.status, 'ambiguous');
  assert.deepEqual(result.candidateIds, ['teaching-7', 'teaching-3']);
  const aliased = { ...data, places: [...data.places, place('other', '其他楼', ['7教'])] };
  assert.equal(matchCoursePlace(intent('7教'), aliased).status, 'ambiguous');
});
test('scope mismatch and explicit another campus do not preselect the same named building', () => {
  for (const current of [{ ...intent('7教'), campus: '青山湖校区' }, { ...intent('7教'), school: '' },
    intent('青山湖校区7教'), intent('其他大学7教')]) {
    const result = matchCoursePlace(current, data); assert.equal(result.status, 'unsupported'); assert.deepEqual(result.candidateIds, []);
  }
});
