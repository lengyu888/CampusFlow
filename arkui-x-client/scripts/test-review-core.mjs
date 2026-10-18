import assert from 'node:assert/strict';
import { test } from 'node:test';
import { readFileSync } from 'node:fs';
import { time, validation, summary, reviewSnapshot, populatedReview, reviewTask, reviewInterval, reviewAllocation,
  reviewFixture, CampusFlowRequestError, deferred, uuid } from './helpers/review-fixture.mjs';
const valid = value => validation.validateReview(value, 'account-a', 'day', '2030-10-19');

test('campus day/week ranges are fixed UTC+08 across leap years, Mondays and historical DST', () => {
  assert.deepEqual(time.reviewRange('day', '2024-02-29'), { start: '2024-02-29T00:00:00+08:00', end: '2024-03-01T00:00:00+08:00', noteAnchor: '2024-02-29' });
  assert.equal(time.reviewRange('week', '2030-10-20').noteAnchor, '2030-10-14');
  assert.equal(time.reviewRange('week', '2030-10-21').end, '2030-10-28T00:00:00+08:00');
  assert.equal(time.reviewRange('day', '1990-07-01').start, '1990-07-01T00:00:00+08:00');
  assert.equal(time.reviewToday(Date.parse('2030-10-18T16:00:00Z')), '2030-10-19');
  assert.equal(time.reviewShiftAnchor('0099-12-31', 1), '0100-01-01');
  assert.equal(time.reviewShiftAnchor('2030-10-19', -1), '2030-10-18');
});
test('invalid and nonrepresentable date bounds do not produce a fabricated range', () => {
  for (const date of ['2023-02-29','2024-02-30','2024-13-01','0000-01-01','9999-12-31','0001-01-01',' 2030-10-19','2030-1-1']) assert.equal(time.reviewRange('day', date), null, date);
  assert.equal(time.reviewRange('week', '9999-12-29'), null);
  assert.equal(time.reviewRange('month', '2030-10-19'), null);
  assert.equal(time.reviewShiftAnchor('9999-12-31', 1), '');
  assert.equal(time.reviewShiftAnchor('2030-10-19', NaN), '');
  assert.equal(time.reviewToday(Infinity), '');
});
test('exact ISO pairs preserve microseconds and reject invalid or naive timestamps', () => {
  const first = time.reviewInstant('9999-12-30T12:00:00.123456+08:00');
  const second = time.reviewInstant('9999-12-30T04:00:00.123457Z');
  assert.equal(time.reviewCompare(first, second), -1);
  assert.equal(time.reviewDifferenceUs(first, second), 1);
  assert.equal(time.reviewCompare(first, time.reviewInstant('9999-12-30T04:00:00.123456Z')), 0);
  assert.equal(time.reviewInstant('1960-01-01T00:00:00.000001Z').remainderUs, 1);
  for (const iso of ['2030-10-19T08:00:00','2030-02-30T00:00:00Z','2030-10-19T24:00:00Z','2030-10-19T08:00:00.1234567Z','0001-01-01T00:00:00+08:00']) assert.equal(time.reviewInstant(iso), null, iso);
});
test('safe mulDiv agrees exactly with integer oracle, including products above safe float precision', () => {
  let seed = 871;
  const random = maximum => { seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0; return seed % maximum; };
  for (let i = 0; i < 3000; i++) {
    const span = 1 + random(86402000000) * (i % 2 ? 17 : 1);
    const bounded = Math.min(span, 86402000000), offset = random(bounded + 1), elapsed = random(86400001);
    assert.equal(time.reviewMulDiv(elapsed, offset, bounded), Number(BigInt(elapsed) * BigInt(offset) / BigInt(bounded)));
  }
  assert.equal(time.reviewMulDiv(86400000, 86401999999, 86402000000), Number(86400000n * 86401999999n / 86402000000n));
  for (const input of [[1,2,1],[-1,0,1],[1,0,0],[86400001,1,1],[1,0,86402000001],[1.5,1,1]]) assert.equal(time.reviewMulDiv(...input), null);
});
test('adjacent day microsecond clips conserve every millisecond while retaining zero allocation sources', () => {
  const start = '2030-10-18T23:59:59.999999+08:00', end = '2030-10-19T00:00:00.001001+08:00';
  const before = time.reviewClip(start, end, 1, time.reviewRange('day','2030-10-18'));
  const after = time.reviewClip(start, end, 1, time.reviewRange('day','2030-10-19'));
  assert.deepEqual(before, { spanUs: 1002, fromUs: 0, toUs: 1, allocatedMs: 0 });
  assert.equal(before.allocatedMs + after.allocatedMs, 1);
  const longStart = '2030-10-20T23:59:59.123456+08:00', longEnd = '2030-10-21T23:59:59.124457+08:00';
  const sunday = time.reviewClip(longStart,longEnd,86400000,time.reviewRange('week','2030-10-20'));
  const monday = time.reviewClip(longStart,longEnd,86400000,time.reviewRange('week','2030-10-21'));
  assert.equal(sunday.allocatedMs + monday.allocatedMs, 86400000);
});
test('validator accepts empty/complete explicit evidence and offset-equivalent period bounds', () => {
  assert.equal(valid(reviewSnapshot()), true);
  const value = populatedReview(); value.period_start = '2030-10-18T16:00:00Z'; value.period_end = '2030-10-19T16:00:00Z';
  assert.equal(valid(value), true);
  value.completed_tasks[0].completion_operation_id = '10000000-0000-1000-8000-000000000091';
  assert.equal(valid(value), true, 'legacy status operations use canonical UUID, not only v4');
  value.completed_tasks[0].completion_operation_id = null; value.completed_tasks[0].completion_evidence = 'current_task_time';
  assert.equal(valid(value), true);
});
test('validator rejects identity, extra fields, policies, totals and date relabeling', () => {
  const mutations = [v=>v.user_id='account-b',v=>v.anchor='2030-10-18',v=>v.timezone_policy='iana_dst',v=>v.timezone='UTC',
    v=>v.period_end='2030-10-20T00:00:01+08:00',v=>v.snapshot_digest='bad',v=>v.token='private',v=>v.totals.current_completed_count++,
    v=>v.totals.confirmed_elapsed_ms++,v=>v.totals.unknown_gap_count++,v=>v.totals.confirmed_elapsed_ms=Number.MAX_SAFE_INTEGER];
  for (const mutate of mutations) { const value=populatedReview(); mutate(value); assert.equal(valid(value),false); }
  for (const value of [null,{},[],{totals:{}},undefined]) assert.equal(valid(value),false);
});
test('task sets are mutually exclusive and never attribute legacy missing completion time to creation', () => {
  const mutations = [v=>v.completed_tasks[0].completed_at=null,v=>v.completed_tasks[0].completed_at='2030-10-20T00:00:00+08:00',
    v=>v.completed_tasks[0].completion_evidence='current_task_time',v=>v.unattributed_completed_tasks[0].completed_at=v.completed_tasks[0].completed_at,
    v=>v.unscheduled_tasks[0].start_at='2030-10-19T12:00:00Z',v=>v.unscheduled_tasks[0].task_id='task-a',
    v=>v.unattributed_completed_tasks[0].completion_operation_id=uuid(9),v=>v.completed_tasks[0].completion_operation_id='not-a-receipt'];
  for(const mutate of mutations){const value=populatedReview();mutate(value);assert.equal(valid(value),false);}
});
test('every allocation is recomputed and malformed/duplicate fragments fail closed', () => {
  const mutations = [v=>v.focus_intervals[0].clip_from_us++,v=>v.focus_intervals[0].span_us++,v=>v.focus_intervals[0].allocated_elapsed_ms++,
    v=>v.focus_intervals[0].interval.elapsed_ms++,v=>v.focus_intervals[0].interval.raw_monotonic=4,v=>v.focus_intervals[0].record_revision=0,
    v=>v.unknown_gaps[0].record_revision++,v=>v.unknown_gaps[0].gap.gap_id=v.focus_intervals[0].interval.interval_id,
    v=>v.unknown_gaps[0].gap.observed_start_at='2030-10-20T00:00:00+08:00',v=>v.unknown_gaps[0].task_title='mixed-new-title'];
  for(const mutate of mutations){const value=populatedReview();mutate(value);assert.equal(valid(value),false);}
  const value=populatedReview(); value.focus_intervals.push(structuredClone(value.focus_intervals[0]));value.totals.confirmed_elapsed_ms*=2;
  assert.equal(valid(value),false);
});
test('zero-ms intersecting source, reversed-clock gap and missing task remain visible and honest', () => {
  const interval = reviewInterval({started_at:'2030-10-19T23:59:59.999999+08:00',ended_at:'2030-10-20T00:00:00.001001+08:00',elapsed_ms:1});
  const value=reviewSnapshot('day','2030-10-19',{focus_intervals:[reviewAllocation(interval)]});
  assert.equal(value.focus_intervals[0].allocated_elapsed_ms,0); assert.equal(valid(value),true);
  const gapValue=populatedReview();gapValue.unknown_gaps[0].gap.observed_end_at='2030-10-18T01:00:00Z';assert.equal(valid(gapValue),true);
  for(const item of [...gapValue.focus_intervals,...gapValue.unknown_gaps]){item.task_id='deleted-task';item.task_title=null;item.task_missing=true;}assert.equal(valid(gapValue),true);
  gapValue.focus_intervals[0].task_id='task-a';assert.equal(valid(gapValue),false,'one snapshot cannot show the same task as both present and deleted');
});
test('same-segment overlap/duplicate sequence and whole-response size are rejected', () => {
  const value=populatedReview();const other=reviewAllocation(reviewInterval({interval_id:uuid(999),sequence:2,started_at:'2030-10-19T08:24:00+08:00',ended_at:'2030-10-19T08:49:00+08:00'}));
  value.focus_intervals.push(other);value.totals.confirmed_elapsed_ms+=other.allocated_elapsed_ms;assert.equal(valid(value),false);
  const huge=reviewSnapshot();huge.unattributed_completed_tasks=[reviewTask({title:'界'.repeat(710000),completed_at:null,completion_operation_id:null,completion_evidence:'unattributed'})];
  assert.equal(valid(huge),false);
  const many=reviewSnapshot();many.unscheduled_tasks=Array.from({length:10001},(_,i)=>reviewTask({task_id:`t${i}`,status:'pending',completed_at:null,completion_operation_id:null,completion_evidence:'pending'}));many.totals.current_unscheduled_count=10001;assert.equal(valid(many),false);
});
test('controller accepts only the latest selected date and immutable caller snapshots', async () => {
  const fixture=reviewFixture(),old=deferred(),latest=deferred();fixture.api.review=(_,anchor)=>anchor==='2030-10-18'?old.promise:latest.promise;
  const a=fixture.controller.select('day','2030-10-18');const b=fixture.controller.select('day','2030-10-19');
  latest.resolve(populatedReview());await b;old.resolve(reviewSnapshot('day','2030-10-18'));await a;
  assert.equal(fixture.state().anchor,'2030-10-19');assert.equal(fixture.state().phase,'ready');
  fixture.state().snapshot.totals.current_completed_count=999;assert.equal(fixture.state().snapshot.totals.current_completed_count,1);
});
test('same range failed refresh retains marked old snapshot, range change clears it', async () => {
  const fixture=reviewFixture();await fixture.controller.select('day','2030-10-19');
  const old=fixture.state().snapshot;fixture.api.review=async()=>{throw new CampusFlowRequestError(500,'REVIEW_DATA_INVALID','private SQL token');};
  await fixture.controller.refresh();assert.equal(fixture.state().phase,'stale');assert.deepEqual(fixture.state().snapshot,old);
  assert.equal(fixture.state().message.includes('private'),false);
  await fixture.controller.select('week','2030-10-19');assert.equal(fixture.state().phase,'error');assert.equal(fixture.state().snapshot,null);
});
test('hide, reconfigure and dispose reject late replies without clearing another account state', async () => {
  const fixture=reviewFixture(),late=deferred();fixture.api.review=()=>late.promise;
  const pending=fixture.controller.select('day','2030-10-19');fixture.controller.setActive(false);late.resolve(populatedReview());await pending;
  assert.equal(fixture.state().snapshot,null);fixture.controller.setActive(true);
  const late2=deferred();fixture.api.review=()=>late2.promise;const request=fixture.controller.refresh();
  fixture.controller.configure('https://example.test|account-b','account-b',{review:async(p,a)=>reviewSnapshot(p,a,{user_id:'account-b'})});
  await fixture.controller.select('day','2030-10-19');late2.resolve(populatedReview());await request;
  assert.equal(fixture.state().snapshot.user_id,'account-b');
  fixture.controller.dispose();assert.equal(fixture.state().snapshot,null);
});
test('invalid payload cannot replace a prior valid snapshot and invalid date does not issue HTTP', async () => {
  const fixture=reviewFixture();await fixture.controller.select('day','2030-10-19');fixture.api.review=async()=>({...populatedReview(),user_id:'account-b'});
  await fixture.controller.refresh();assert.equal(fixture.state().phase,'stale');assert.equal(fixture.state().errorCode,'INVALID_RESPONSE');
  let count=0;fixture.api.review=async()=>{count++;return populatedReview();};await fixture.controller.select('day','2030-02-30');assert.equal(count,0);assert.equal(fixture.state().snapshot,null);
});
test('summary contains only explicitly chosen facts, no private source titles or note by default', () => {
  const value=populatedReview();const text=summary.reviewSummary(value,{completed:true,unscheduled:false,focus:false});
  assert.match(text,/1 项/);assert.doesNotMatch(text,/私密课程|task-a|尚未安排|1500000/);assert.match(text,/UTC\+08:00/);assert.match(text,/2030-10-20T01:00:00Z/);
  assert.equal(summary.reviewSummary(value,{completed:false,unscheduled:false,focus:false}),'');
  assert.match(summary.reviewSummary(value,{completed:false,unscheduled:false,focus:false},'我主动选入的感受'),/我主动选入的感受/);
  assert.match(summary.reviewSummary(value,{completed:false,unscheduled:false,focus:true}),/不等同于有效学习时间/);
  assert.equal(summary.reviewSummary(value,{completed:true,unscheduled:false,focus:false},'🙂'.repeat(501)),'');
  value.totals.current_completed_count=999;assert.equal(summary.reviewSummary(value,{completed:true,unscheduled:false,focus:false}),'');
});

test('eight real authenticated ASGI/SQLite snapshots validate and source tampering fails', () => {
  const fixture=JSON.parse(readFileSync(new URL('./fixtures/review-asgi-v1.json',import.meta.url),'utf8'));
  assert.equal(fixture.synthetic,true);assert.equal(fixture.cases.length,8);
  for(const item of fixture.cases){
    assert.equal(validation.validateReview(item.response,fixture.user_id,item.period,item.anchor),true,item.label);
    const changed=structuredClone(item.response);changed.totals.confirmed_elapsed_ms++;
    assert.equal(validation.validateReview(changed,fixture.user_id,item.period,item.anchor),false,`${item.label} totals`);
    const text=summary.reviewSummary(item.response,{completed:true,unscheduled:true,focus:true});
    assert.match(text,/UTC\+08:00/);assert.doesNotMatch(text,new RegExp(fixture.user_id));
    for(const source of item.response.focus_intervals){assert.equal(text.includes(source.record_id),false);}
  }
  const previous=fixture.cases.find(item=>item.label==='micro_previous_day').response;
  assert.equal(previous.focus_intervals.some(item=>item.allocated_elapsed_ms===0),true);
});
