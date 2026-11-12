import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { test } from 'node:test';
const source = readFileSync(new URL('../entry/src/main/ets/utils/CourseRouteIntent.ets', import.meta.url), 'utf8').replace(/^import [^\n]+;\r?\n/gm, '');
const bridgeSource = readFileSync(new URL('../entry/src/main/ets/utils/RouteMapBridge.ets', import.meta.url), 'utf8')
  .replace(/^import [^\n]+;\r?\n/gm, '').replace(/^export /gm, '');
const supportedMapCampus = new Function(stripTypeScriptTypes(bridgeSource) + '\nreturn supportedMapCampus;')();
const matchCoursePlace = new Function('supportedMapCampus',
  stripTypeScriptTypes(source.replace(/^export /gm, '')) + '\nreturn matchCoursePlace;')(supportedMapCampus);
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

test('renamed full school-prefixed places match while old course aliases and original room text remain intact',()=>{
 const renamed={...data,places:[
  place('library','杭州电子科技大学(高教园校区)-图书馆',['图书馆','校图书馆']),
  place('teaching-7','杭州电子科技大学第七教学科研楼北楼',['第7教研楼（信博楼）','7教','第七教研楼','信博楼','第7教研楼']),
  place('teaching-3','杭州电子科技大学(下沙校区)-第三教学科研楼',['第3教研楼（信礼楼）','3教','第三教研楼','信礼楼'])]};
 for(const [text,id,room] of [
  ['杭州电子科技大学(高教园校区)-图书馆','library',''],
  ['杭州电子科技大学第七教学科研楼北楼406','teaching-7','406'],
  ['杭州电子科技大学(下沙校区)-第三教学科研楼301','teaching-3','301'],
  ['第7教研楼北406','teaching-7','北406'],['7教','teaching-7','']]){
 const result=matchCoursePlace(intent(text),renamed);assert.equal(result.status,'unique',text);
 assert.deepEqual(result.candidateIds,[id]);assert.equal(result.originalLocation,text);assert.equal(result.remainingRoomText,room);}
 assert.equal(matchCoursePlace(intent('青山湖校区7教'),renamed).status,'unsupported');
});

test('bare and qualified names match the canonical buildings in the active campus package', () => {
  const campusData = { ...data, places: [
    ...data.places,
    place('teaching-6', '杭州电子科技大学(下沙校区)-第六教学科研楼中楼', ['第6教研楼', '6教', '信诚楼']),
    place('teaching-4', '杭州电子科技大学(下沙校区)南区-第四教学科研楼', ['第4教研楼', '4教']),
    place('teaching-7-new', '杭州电子科技大学第七教学科研楼北楼')
  ] };
  for (const [text, id, suffix] of [
    ['第六教学科研楼中楼', 'teaching-6', ''],
    ['第六教学科研楼中楼325', 'teaching-6', '325'],
    ['杭州电子科技大学（下沙校区） 第六教学科研楼中楼 325', 'teaching-6', '325'],
    ['下沙校区 第6教研楼中325', 'teaching-6', '中325'],
    ['第四教学科研楼北406', 'teaching-4', '北406'],
    ['第七教学科研楼北楼311-313', 'teaching-7-new', '311-313']
  ]) {
    const result = matchCoursePlace(intent(text), campusData);
    assert.equal(result.status, 'unique', text);
    assert.deepEqual(result.candidateIds, [id]);
    assert.equal(result.originalLocation, text);
    assert.equal(result.remainingRoomText, suffix);
  }
  for (const text of ['杭州电子科技大学(青山湖校区)-第六教学科研楼中楼325', '其他大学(下沙校区)-第六教学科研楼中楼325']) {
    const result = matchCoursePlace(intent(text), campusData);
    assert.equal(result.status, 'unsupported', text);
    assert.deepEqual(result.candidateIds, []);
  }
  assert.equal(matchCoursePlace(intent('杭州电子科技大学'), campusData).status, 'missing');
  assert.equal(matchCoursePlace(intent('下沙校区'), campusData).status, 'missing');
  assert.equal(matchCoursePlace(intent('第六教学科研楼中楼附近'), campusData).status, 'missing');
});

test('shared short names derived from canonical campus labels stay ambiguous', () => {
  const campusData = { ...data, places: [
    place('north', '杭州电子科技大学(下沙校区)北区-教学楼'),
    place('south', '杭州电子科技大学(下沙校区)南区-教学楼')
  ] };
  const result = matchCoursePlace(intent('教学楼101'), campusData);
  assert.equal(result.status, 'ambiguous');
  assert.deepEqual(result.candidateIds, ['north', 'south']);
});

test('documented account aliases preselect only in the canonical HDU Xiasha package', () => {
  for (const [school, campus] of [['杭电', '下沙'], [' HDU ', ' Xiasha '], ['杭州电子科技大学', '下沙']]) {
    const current = { ...intent('第7教研楼北406'), school, campus };
    const result = matchCoursePlace(current, data);
    assert.equal(result.status, 'unique', school + '/' + campus);
    assert.deepEqual(result.candidateIds, ['teaching-7']);
    assert.equal(result.remainingRoomText, '北406');
    assert.equal(matchCoursePlace(current, { ...data, package: { ...data.package, package_id: 'other' } }).status, 'unsupported');
  }
  assert.equal(matchCoursePlace({ ...intent('7教'), school: '杭电', campus: '临安校区' }, data).status, 'unsupported');
  assert.equal(matchCoursePlace({ ...intent('青山湖校区7教'), school: '杭电', campus: '下沙' }, data).status, 'unsupported');
});
