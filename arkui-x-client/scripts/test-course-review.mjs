import assert from 'node:assert/strict';
import { test } from 'node:test';
import { courseReview as policy, reliability } from './helpers/course-review-fixture.mjs';
import { PlanningActionController } from './helpers/planning-action-fixture.mjs';

const clone = value => JSON.parse(JSON.stringify(value));
const now = Date.now();
const digest = char => char.repeat(64);
function candidate(id = 'candidate-a') {
  const task = { candidate_id: id, allow_during_course: true, title: '阅读资料', start_at: '2028-10-20T15:30:00+08:00',
    end_at: '2028-10-20T16:15:00+08:00', location: null, reminder_minutes: null };
  return { proposal_id: 'proposal-a', contract_version: 2, action: 'create', kind: 'task', title: task.title,
    start_at: task.start_at, end_at: task.end_at, reminder_minutes: null, reason: null, payload: { task },
    conflicts: [], warnings: [], status: 'pending', created_at: new Date(now).toISOString(), expires_at: new Date(now + 900000).toISOString(),
    target_task_id: null, target_plan_id: null, before_task: null, before_plan: null, receipt: null,
    course_policy_version: 1, state_version: { timetable: 12, planning: 7 }, course_reviews: [{
      candidate_id: id, task_id: null, allow_during_course: true, state: 'needs_review', review_digest: digest('a'),
      candidate_digest: digest('b'), requires_acknowledgement: true, revoke_only: false,
      school: '杭州电子科技大学', campus: '下沙校区', timezone: 'Asia/Shanghai', timetable_version: 12,
      planning_version: 7, task_version: null, overlaps: [{ course_key: digest('c'),
        course: { date: '2028-10-20', title: '软件工程', start_time: '14:30', end_time: '16:05', location: '教研楼311', teacher: '老师' },
        overlap_start_at: '2028-10-20T15:30:00+08:00', overlap_end_at: '2028-10-20T16:05:00+08:00' }]
    }] };
}
function confirmed(value) {
  const result=clone(value); result.status='confirmed';
  result.receipt={ receipt_id:'receipt-a',proposal_id:value.proposal_id,action:value.action,kind:value.kind,
    applied_at:new Date(now+1000).toISOString(),task_ids:['created-a'],plan_ids:[],milestone_ids:[],retained_task_ids:[],
    candidate_tasks:[{candidate_id:'candidate-a',task_id:'created-a'}],course_acknowledgement_ids:['ack-a'],
    course_acknowledgements:[{candidate_id:'candidate-a',acknowledgement_id:'ack-a'}] };
  return result;
}

test('a full review validates exact task/course intersection and asks for its candidate-specific digest', () => {
  const value=candidate(); assert.equal(policy.validCoursePolicy(value),true); assert.equal(reliability.validReliableAction(value),true);
  assert.deepEqual(policy.requiredCourseAcknowledgements(value),[{candidate_id:'candidate-a',review_digest:digest('a')}]);
  assert.equal(policy.validCourseAcknowledgements(value,policy.requiredCourseAcknowledgements(value)),true);
});

test('missing policy cannot silently grant course permission while ordinary v2 remains compatible', () => {
  const value=candidate();delete value.course_policy_version;delete value.state_version;delete value.course_reviews;
  assert.equal(policy.validCoursePolicy(value),false);
  value.payload.task.allow_during_course=false; assert.equal(policy.validCoursePolicy(value),true);
  delete value.payload.task.allow_during_course; assert.equal(policy.validCoursePolicy(value),true);
});

test('candidate identity, permission, versions and digest format are all required to match', () => {
  for(const mutate of [a=>a.course_reviews[0].candidate_id='other',a=>a.payload.task.candidate_id='',
    a=>a.course_reviews[0].allow_during_course=false,a=>a.course_reviews[0].timetable_version++,
    a=>a.course_reviews[0].planning_version++,a=>a.course_reviews[0].review_digest='short',
    a=>a.course_reviews[0].candidate_digest='G'.repeat(64),a=>a.course_reviews[0].timezone='UTC',
    a=>a.course_reviews[0].task_id='unrelated',a=>a.state_version.timetable=-1]) {
    const value=candidate();mutate(value);assert.equal(policy.validCoursePolicy(value),false);
    assert.equal(reliability.validReliableAction(value),false);
  }
});

test('displayed intersection must be the exact overlap, with complete dates and valid course calendar', () => {
  for(const mutate of [a=>a.course_reviews[0].overlaps[0].overlap_start_at='2028-10-20T15:29:00+08:00',
    a=>a.course_reviews[0].overlaps[0].overlap_end_at='2028-10-20T16:15:00+08:00',
    a=>a.course_reviews[0].overlaps[0].course.end_time='15:30',a=>a.course_reviews[0].overlaps[0].course.start_time='25:00']) {
    const value=candidate();mutate(value);assert.equal(policy.validCoursePolicy(value),false);
  }
  const invalid=candidate(); invalid.payload.task.start_at='2028-03-01T15:30:00+08:00';invalid.payload.task.end_at='2028-03-01T16:15:00+08:00';
  const overlap=invalid.course_reviews[0].overlaps[0];overlap.course.date='2028-02-30';
  overlap.overlap_start_at='2028-03-01T15:30:00+08:00';overlap.overlap_end_at='2028-03-01T16:05:00+08:00';
  assert.equal(policy.validCoursePolicy(invalid),false,'a nonexistent course date must not normalize into March and validate');
});

test('same-title plan subtasks require unique candidate IDs and one matching review per candidate', () => {
  const value=candidate();value.kind='plan';value.title='计划';value.start_at=null;value.end_at=null;
  const first=value.payload.task,second={...first,candidate_id:'candidate-b'};
  value.payload={summary:'',target_date:null,milestones:[{title:'阶段',due_at:null,tasks:[first,second]}]};
  value.course_reviews.push({...clone(value.course_reviews[0]),candidate_id:'candidate-b',review_digest:digest('d')});
  assert.equal(policy.validCoursePolicy(value),true);assert.equal(policy.requiredCourseAcknowledgements(value).length,2);
  const before=clone(value);value.payload.milestones[0].tasks[1].candidate_id='candidate-a';assert.equal(policy.validCoursePolicy(value),false);
  before.course_reviews[1].candidate_id='candidate-a';assert.equal(policy.validCoursePolicy(before),false);
});

test('none/unchecked cannot hide an overlap and accepted state is not an opt-in substitute', () => {
  for(const state of ['none','unchecked']) {const value=candidate();value.course_reviews[0].state=state;value.course_reviews[0].requires_acknowledgement=false;assert.equal(policy.validCoursePolicy(value),false);}
  const value=candidate();value.course_reviews[0].state='accepted';value.course_reviews[0].requires_acknowledgement=false;
  assert.equal(policy.validCoursePolicy(value),true);assert.deepEqual(policy.requiredCourseAcknowledgements(value),[]);
  value.payload.task.allow_during_course=false;value.course_reviews[0].allow_during_course=false;assert.equal(policy.validCoursePolicy(value),false);
});

test('missing, stale, extra and duplicate acknowledgements cannot authorize a write', () => {
  const value=candidate();
  for(const acks of [[],[{candidate_id:'candidate-b',review_digest:digest('a')}],
    [{candidate_id:'candidate-a',review_digest:digest('d')}],
    [{candidate_id:'candidate-a',review_digest:digest('a')},{candidate_id:'candidate-a',review_digest:digest('a')}]]) {
    assert.equal(policy.validCourseAcknowledgements(value,acks),false);
  }
});

test('malformed acknowledgement items fail closed instead of crashing confirmation', () => {
  for(const acks of [[null],[42],[{}]]) {
    assert.equal(policy.validCourseAcknowledgements(candidate(),acks),false);
  }
});

test('a success receipt links each exact candidate to an executed task and acknowledgement ID', () => {
  const result=confirmed(candidate());assert.equal(policy.validCourseReceipt(result,result.receipt),true);
  assert.equal(reliability.validatedActionReceipt(result),result.receipt);assert.equal(reliability.receiptTaskId(result),'created-a');
  for(const mutate of [r=>r.candidate_tasks[0].task_id='unrelated',r=>r.candidate_tasks[0].candidate_id='other',
    r=>r.candidate_tasks=[],r=>r.course_acknowledgement_ids=['different'],r=>r.course_acknowledgements[0].candidate_id='other',
    r=>r.course_acknowledgements=[],r=>r.course_acknowledgements[0].acknowledgement_id='']) {
    const changed=clone(result);mutate(changed.receipt);assert.equal(policy.validCourseReceipt(changed,changed.receipt),false);
    assert.equal(reliability.validatedActionReceipt(changed),null);
  }
});

test('malformed receipt entries cannot crash or appear as a successful task result', () => {
  for(const field of ['candidate_tasks','course_acknowledgements']) {
    const result=confirmed(candidate());result.receipt[field]=[null];
    assert.equal(policy.validCourseReceipt(result,result.receipt),false);
    assert.equal(reliability.validatedActionReceipt(result),null);
  }
});

test('candidate comparison binds course snapshot, versions, title, place and precise overlap', () => {
  const value=candidate();
  for(const mutate of [a=>a.course_reviews[0].review_digest=digest('d'),a=>a.course_reviews[0].candidate_digest=digest('d'),
    a=>a.course_reviews[0].overlaps[0].course.title='另一门课',a=>a.course_reviews[0].overlaps[0].course.location='别处',
    a=>a.state_version.planning++,a=>a.course_reviews[0].school='另一所学校']) {
    const next=clone(value);mutate(next);assert.equal(policy.sameCoursePolicy(value,next),false);assert.equal(reliability.sameActionCandidate(value,next),false);
  }
  const reordered=clone(value);reordered.course_reviews[0]=Object.fromEntries(Object.entries(reordered.course_reviews[0]).reverse());
  assert.equal(policy.sameCoursePolicy(value,reordered),true);
});

test('receipt comparison is structural: object property order does not change exact result identity', () => {
  const a=confirmed(candidate()).receipt,b=clone(a);
  b.candidate_tasks[0]=Object.fromEntries(Object.entries(b.candidate_tasks[0]).reverse());
  b.course_acknowledgements[0]=Object.fromEntries(Object.entries(b.course_acknowledgements[0]).reverse());
  assert.equal(policy.sameCourseReceipt(a,b),true); assert.equal(reliability.sameActionReceipt(a,b),true);
  b.candidate_tasks[0].task_id='changed';assert.equal(policy.sameCourseReceipt(a,b),false);
});

test('real planning controller waits for the precise user acknowledgement then sends it with the same proposal', async () => {
  const action=candidate(),calls=[],applied=[];
  const controller=new PlanningActionController({
    async previewPlanningAction(){return clone(action);},async confirmAction(id,acks){calls.push([id,clone(acks)]);const result=confirmed(action);return {action:result,applied:true,receipt:result.receipt,message:''};},
    async cancelAction(){throw new Error('unexpected cancel');},async actionStatus(){throw new Error('unexpected status');}
  },()=>{},result=>applied.push(result));
  await controller.preview({operation:'create_task',task:{...action.payload.task}});
  await controller.confirm();assert.equal(calls.length,0);assert.equal(controller.snapshot().phase,'review');
  await controller.confirm([{candidate_id:'candidate-a',review_digest:digest('d')}]);assert.equal(calls.length,0);
  await controller.confirm(policy.requiredCourseAcknowledgements(action));
  assert.deepEqual(calls,[[action.proposal_id,[{candidate_id:'candidate-a',review_digest:digest('a') }]]]);
  assert.equal(applied.length,1);assert.equal(controller.snapshot().phase,'resolved');
});
