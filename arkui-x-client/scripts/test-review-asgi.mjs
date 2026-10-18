import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { test } from 'node:test';
import { validation, time, summary, ReviewController, CampusFlowRequestError, deferred } from './helpers/review-fixture.mjs';

// These are real authenticated ASGI/SQLite outputs with synthetic accounts and
// records, frozen by the backend fixture generator. No HTTP/model/device runs here.
const fixture = JSON.parse(readFileSync(new URL('./fixtures/review-asgi-v1.json', import.meta.url), 'utf8'));
const canonical = value => value !== null && typeof value === 'object' ? Array.isArray(value) ? value.map(canonical) :
  Object.fromEntries(Object.keys(value).sort().map(key => [key, canonical(value[key])])) : value;
const digest = snapshot => {
  const { snapshot_digest, ...body } = snapshot;
  return createHash('sha256').update(JSON.stringify(canonical(body)), 'utf8').digest('hex');
};
function controller(api, owner = fixture.user_id) {
  const changes = [];
  const value = new ReviewController(state => changes.push(state));
  value.configure(`https://fixture.invalid|${owner}`, owner, api); value.setActive(true);
  return { controller: value, changes };
}

for (const item of fixture.cases) {
  test(`ASGI ${item.label}: digest, validation, controller and selected-only summary`, async () => {
    assert.equal(digest(item.response), item.response.snapshot_digest, 'Node crypto independently checks backend canonical digest');
    assert.equal(validation.validateReview(item.response, fixture.user_id, item.period, item.anchor), true);
    let calls = 0;
    const f = controller({ async review(period, anchor) { calls++; assert.equal(period,item.period); assert.equal(anchor,item.anchor); return structuredClone(item.response); } });
    await f.controller.select(item.period,item.anchor);
    assert.equal(calls,1);assert.equal(f.controller.snapshot().phase,'ready');assert.deepEqual(f.controller.snapshot().snapshot,item.response);
    const text=summary.reviewSummary(f.controller.snapshot().snapshot,{completed:true,unscheduled:false,focus:true});
    assert.match(text,/UTC\+08:00/);assert.ok(text.includes(item.response.as_of));assert.doesNotMatch(text,/当前尚未安排开始时间的待办：/);
    assert.equal(text.includes(fixture.user_id),false);
    for(const source of item.response.focus_intervals)assert.equal(text.includes(source.record_id),false);
    assert.equal(summary.reviewSummary(item.response,{completed:false,unscheduled:false,focus:false}),'');
    const selectedNote='这是用户单独勾选的本机感受';
    assert.equal(text.includes(selectedNote),false);
    assert.ok(summary.reviewSummary(item.response,{completed:false,unscheduled:false,focus:false},selectedNote).includes(selectedNote));
    f.controller.dispose();
  });
}

test('actual ASGI wrong-owner and tampered totals/relative microsecond sources never become ready', async () => {
  const item=fixture.cases.find(value=>value.label==='mixed_current_day');
  const changed=[];
  const other=structuredClone(item.response);other.user_id='another-account';changed.push(other);
  const totals=structuredClone(item.response);totals.totals.current_completed_count++;changed.push(totals);
  const micro=structuredClone(item.response);micro.focus_intervals[0].clip_from_us++;changed.push(micro);
  const hidden=structuredClone(item.response);hidden.focus_intervals[0].interval.monotonic_start=123;changed.push(hidden);
  for(const value of changed){
    assert.equal(validation.validateReview(value,fixture.user_id,item.period,item.anchor),false);
    const f=controller({review:async()=>value});await f.controller.select(item.period,item.anchor);
    assert.equal(f.controller.snapshot().phase,'error');assert.equal(f.controller.snapshot().snapshot,null);assert.equal(f.controller.snapshot().errorCode,'INVALID_RESPONSE');
    // Summary has no external owner parameter: only the controller's accepted
    // snapshot is eligible for it. A forged owner must never cross that boundary.
    assert.equal(summary.reviewSummary(f.controller.snapshot().snapshot,{completed:true,unscheduled:true,focus:true}),'');
    if(value.user_id===fixture.user_id)assert.equal(summary.reviewSummary(value,{completed:true,unscheduled:true,focus:true}),'');
    f.controller.dispose();
  }
});

test('actual microsecond allocations conserve adjacent-day totals and independently match integer arithmetic', () => {
  const before=fixture.cases.find(value=>value.label==='micro_previous_day').response;
  const after=fixture.cases.find(value=>value.label==='mixed_current_day').response;
  const week=fixture.cases.find(value=>value.label==='current_natural_week').response;
  assert.equal(before.totals.confirmed_elapsed_ms+after.totals.confirmed_elapsed_ms,week.totals.confirmed_elapsed_ms);
  assert.equal(before.focus_intervals.some(value=>value.allocated_elapsed_ms===0),true);
  for(const snapshot of [before,after,week])for(const item of snapshot.focus_intervals){
    const expected=BigInt(item.interval.elapsed_ms)*BigInt(item.clip_to_us)/BigInt(item.span_us)-BigInt(item.interval.elapsed_ms)*BigInt(item.clip_from_us)/BigInt(item.span_us);
    assert.equal(item.allocated_elapsed_ms,Number(expected));
    assert.deepEqual(time.reviewClip(item.interval.started_at,item.interval.ended_at,item.interval.elapsed_ms,time.reviewRange(snapshot.period,snapshot.anchor)),
      {spanUs:item.span_us,fromUs:item.clip_from_us,toUs:item.clip_to_us,allocatedMs:item.allocated_elapsed_ms});
  }
});

test('actual invalid-date errors match local bounds and safe error mapping never returns raw response', async () => {
  for(const error of fixture.errors){
    assert.equal(time.reviewRange(error.period,error.anchor),null);
    let calls=0;const f=controller({review:async()=>{calls++;throw new CampusFlowRequestError(error.status_code,error.response.code,error.response.detail);}});
    await f.controller.select(error.period,error.anchor);assert.equal(calls,0);assert.equal(f.controller.snapshot().errorCode,error.response.code);f.controller.dispose();
  }
  const item=fixture.cases[0];
  for(const code of ['REVIEW_LIMIT','REVIEW_DATA_INVALID','REVIEW_FAILED']){
    const f=controller({review:async()=>{throw new CampusFlowRequestError(500,code,'private SQL/bearer token');}});
    await f.controller.select(item.period,item.anchor);assert.equal(f.controller.snapshot().errorCode,code);assert.doesNotMatch(f.controller.snapshot().message,/private|SQL|token/);f.controller.dispose();
  }
});

test('actual response preserved stale on failed refresh; old-account delayed snapshot is ignored', async () => {
  const item=fixture.cases.find(value=>value.label==='mixed_current_day');let failing=false;
  const api={review:async()=>{if(failing)throw new CampusFlowRequestError(413,'REVIEW_LIMIT','private payload');return item.response;}};
  const f=controller(api);await f.controller.select(item.period,item.anchor);failing=true;await f.controller.refresh();
  assert.equal(f.controller.snapshot().phase,'stale');assert.equal(f.controller.snapshot().snapshot.snapshot_digest,item.response.snapshot_digest);
  const late=deferred();api.review=()=>late.promise;const request=f.controller.refresh();
  f.controller.configure('https://fixture.invalid|other','other',{review:async()=>{throw Error('unavailable');}});
  late.resolve(item.response);await request;assert.equal(f.controller.snapshot().snapshot,null);f.controller.dispose();
});
