import { planningPageDependencies, dependencyPrefix, timetableSnapshot, preferenceSnapshot } from './helpers/planning-overview-fixture.mjs';
import { draftFixture } from './helpers/local-draft-fixture.mjs';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { test } from 'node:test';
import { PlanningActionController, editedPlanningTime, validPlanningDate, planningTimestamp, CampusFlowRequestError, candidate, applied,
  sampleTask, samplePlan, presentation, deferred, clone, quickCapture, courseReview } from './helpers/planning-action-fixture.mjs';
const read = name => readFileSync(new URL(`../entry/src/main/ets/${name}`, import.meta.url), 'utf8');
const noImports = s => s.replace(/^import \{[\s\S]*?\} from '[^']+';\r?\n/gm, '').replace(/^import [^\n]+;\r?\n/gm, '');
const raw = read('pages/PlanCenterPage.ets');
const methods = noImports(raw.slice(0, raw.indexOf('\n  @Builder')))
  .replace(/^@Component\r?\n/m, '').replace(/@(Prop|State)\s+|@Watch\('[^']+'\)\s*/g, '')
  .replace('export struct PlanCenterPage', 'class PlanCenterPage') + '\n}\n';
const utility = async name => import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(noImports(read(`utils/${name}.ets`)))).toString('base64')}`);
const agenda = await utility('DailyAgenda');
async function fixture(handlers = {}) {
  const drafts = await draftFixture(handlers.driver);
  const calls = [], changed = [], confirmationAcks = []; let action;
  const overview = { plans: [samplePlan()], tasks: [sampleTask()], total_tasks: 1, completed_tasks: 0, due_today: 0, overdue_tasks: 0, progress: 0 };
  class Api {
    async planning() { calls.push(['planning']); return clone(overview); }
    async timetable() { return timetableSnapshot([]); }
    async learningPreferences() { return preferenceSnapshot(); }
    async updateTask(id, completed) { calls.push(['toggle', id, completed]); if (handlers.toggle) return handlers.toggle(); }
    async previewPlanningAction(request) { calls.push(['preview', clone(request)]); action = candidate(request); if (handlers.preview) action = await handlers.preview(action); return clone(action); }
    async confirmAction(id, acknowledgements = []) {
      calls.push(['confirm', id]); confirmationAcks.push(clone(acknowledgements)); const result = applied(action);
      if (action.course_policy_version === 1) {
        result.receipt.candidate_tasks = courseReview.courseCandidates(action).map((item,index) => ({candidate_id:item.candidate_id,task_id:result.receipt.task_ids[index]}));
        result.receipt.course_acknowledgements = courseReview.requiredCourseAcknowledgements(action).map((item,index) => ({candidate_id:item.candidate_id,acknowledgement_id:`ack-${index}`}));
        result.receipt.course_acknowledgement_ids = result.receipt.course_acknowledgements.map(item=>item.acknowledgement_id);
      }
      return handlers.confirm ? handlers.confirm(result) : { applied: true, action: result, receipt: result.receipt, message: '' };
    }
    async cancelAction(id) { calls.push(['cancel', id]); return { action: { ...action, status: 'cancelled' }, receipt: null, applied: false }; }
    async actionStatus(id) { calls.push(['status', id]); return handlers.status ? handlers.status(id) : applied(action); }
  }
  class Input { stopEditing() {} }
  const Page = new Function('CampusFlowApi', 'TextInputController', 'Scroller', 'AppTheme', 'Curve', 'shanghaiDate', 'buildDailyAgenda',
    'localDrafts', 'formatPlanDateTime', 'PlanningActionController', 'editedPlanningTime', 'validPlanningDate', 'planningTimestamp', 'CampusFlowRequestError', 'parseQuickCapture', 'captureEndAt', 'validCourseAcknowledgements', 'planningPageDependencies',
    dependencyPrefix + stripTypeScriptTypes(methods) + '\nreturn PlanCenterPage;')(Api, Input, class {}, { motion: () => 0 }, { EaseOut: '' },
    agenda.shanghaiDate, agenda.buildDailyAgenda, drafts.store, presentation.formatPlanDateTime, PlanningActionController, editedPlanningTime, validPlanningDate, planningTimestamp, CampusFlowRequestError, quickCapture.parseQuickCapture, quickCapture.captureEndAt, courseReview.validCourseAcknowledgements, planningPageDependencies);
  const page = new Page(); page.draftLease = drafts.lease; page.draftScopeChanged(); page.overview = clone(overview); page.getUIContext = () => ({ animateTo: (_, update) => update() });
  page.onPlanningChanged = () => changed.push(true);
  return { page, calls, changed, drafts, confirmationAcks };
}

test('create draft is cleared only after exact receipt; edited title or date survives confirmation', async () => {
  for (const changedDraft of ['none', 'title', 'date']) {
    const f = await fixture(); f.page.title = '原草稿'; f.page.draftTaskDate = '2028-10-20';
    await f.page.addTask(); assert.equal(f.page.title, '原草稿'); assert.equal(f.changed.length, 0);
    if (changedDraft === 'title') f.page.title = '新草稿';
    if (changedDraft === 'date') f.page.draftTaskDate = '2028-10-21';
    await f.page.confirmPlanningAction(); assert.equal(f.page.title, changedDraft === 'none' ? '' : changedDraft === 'title' ? '新草稿' : '原草稿');
    assert.equal(f.changed.length, 1); assert.equal(f.page.actionState.action.receipt.task_ids[0], 'created-task-a');
  }
});

test('task editor sends all five values, preserves precise unedited timestamps and reminder zero', async () => {
  const f = await fixture(); f.page.beginTaskEdit(sampleTask('target-exact', { title: '同名任务' }));
  f.page.editTaskTitle = '仅改名称'; await f.page.previewTaskEdit();
  assert.deepEqual(f.calls[0], ['preview', { operation: 'update_task', task_id: 'target-exact', task: {
    title: '仅改名称', start_at: '2028-10-20T09:00:03+08:00', end_at: '2028-10-20T10:00:07+08:00', reminder_minutes: 0, location: '图书馆', allow_during_course: false } }]);
  assert.equal(f.page.actionState.phase, 'review');
});

test('editor rejects invalid intervals/reminders and keeps drafts until fixed', async () => {
  const f = await fixture(); f.page.beginTaskEdit(sampleTask()); f.page.editTaskStart = '2028-02-30 09:00';
  await f.page.previewTaskEdit(); assert.equal(f.calls.length, 0); assert.match(f.page.errorText, /有效/);
  f.page.editTaskStart = ''; f.page.editTaskEnd = ''; f.page.editTaskReminder = '-1';
  await f.page.previewTaskEdit(); assert.equal(f.calls.length, 0); assert.match(f.page.errorText, /提醒/);
  f.page.editTaskReminder = ''; await f.page.previewTaskEdit(); assert.equal(f.calls[0][1].task.start_at, null);
  assert.equal(f.calls[0][1].task.reminder_minutes, null);
});

test('task/plan drafts survive back, other IDs cannot overwrite them, and discard is explicit', async () => {
  const f = await fixture(); f.page.beginTaskEdit(sampleTask('a')); f.page.editTaskTitle = '保留草稿'; f.page.closeDetails();
  f.page.beginTaskEdit(sampleTask('b')); assert.equal(f.page.editTaskId, 'a'); assert.equal(f.page.editTaskTitle, '保留草稿');
  assert.equal(f.page.detailId, 'a'); f.page.discardTaskEdit(); f.page.beginTaskEdit(sampleTask('b')); assert.equal(f.page.editTaskId, 'b');
  f.page.beginPlanEdit(samplePlan('p1')); f.page.editPlanSummary = '较长草稿'; f.page.closeDetails();
  f.page.beginPlanEdit(samplePlan('p2')); assert.equal(f.page.editPlanId, 'p1'); assert.equal(f.page.editPlanSummary, '较长草稿');
});

test('plan metadata preview contains only editable fields and exact plan ID, deletion remains preview only', async () => {
  const f = await fixture(); f.page.beginPlanEdit(samplePlan('p-exact')); f.page.editPlanDate = ''; f.page.editPlanSummary = '';
  await f.page.previewPlanEdit(); assert.deepEqual(f.calls[0][1], { operation: 'update_plan', plan_id: 'p-exact', plan: { title: '复习目标', summary: '', target_date: null } });
  await f.page.actionManager().cancel(); f.page.dismissAction();
  await f.page.requestPlanDelete(samplePlan('p-exact')); assert.deepEqual(f.calls.at(-1), ['preview', { operation: 'delete_plan', plan_id: 'p-exact' }]);
  assert.equal(f.changed.length, 0); assert.equal(f.page.actionState.action.before_plan.task_count, 2);
});

test('unknown action blocks create, update, completion, both deletes, and discarding its editor', async () => {
  const f = await fixture({ confirm: () => { throw new Error('response lost'); } }); f.page.beginTaskEdit(sampleTask());
  await f.page.previewTaskEdit(); await f.page.confirmPlanningAction(); assert.equal(f.page.actionState.phase, 'uncertain');
  const count = f.calls.length; f.page.title = 'new'; await f.page.addTask(); await f.page.toggle(sampleTask());
  await f.page.requestDelete(sampleTask('other')); await f.page.requestPlanDelete(samplePlan());
  await f.page.previewTaskEdit(); f.page.discardTaskEdit(); assert.equal(f.calls.length, count); assert.equal(f.page.editTaskId, 'task-a');
  await f.page.actionManager().check(); assert.equal(f.page.actionState.phase, 'resolved'); assert.equal(f.changed.length, 1);
});

test('replan unresolved state blocks all new action previews and task completion', async () => {
  const f = await fixture(); f.page.replanWriteBlocked = true; f.page.title = '待办';
  await f.page.addTask(); await f.page.toggle(sampleTask()); await f.page.requestDelete(sampleTask());
  await f.page.requestPlanDelete(samplePlan()); assert.deepEqual(f.calls, []);
});

test('hide/dispose during confirm ignores late result and never clears the draft or emits success', async () => {
  for (const kind of ['hide', 'dispose']) {
    const d = deferred(); const f = await fixture({ confirm: () => d.promise }); f.page.title = '保留'; await f.page.addTask();
    const pending = f.page.confirmPlanningAction();
    while (!f.calls.some(c => c[0] === 'confirm')) await new Promise(resolve => setImmediate(resolve));
    if (kind === 'hide') { f.page.active = false; f.page.activityChanged(); } else f.page.aboutToDisappear();
    const result = applied(f.page.actionState.action); d.resolve({ applied: true, action: result, receipt: result.receipt }); await pending;
    assert.equal(f.page.title, '保留'); assert.equal(f.changed.length, 0);
    if (kind === 'hide') { f.page.active = true; f.page.activityChanged(); await f.page.actionManager().check(); assert.equal(f.changed.length, 1); }
  }
});

test('successful edit clears its own unchanged draft only; later edits remain intact', async () => {
  for (const later of [false, true]) {
    const f = await fixture(); f.page.beginTaskEdit(sampleTask()); await f.page.previewTaskEdit();
    if (later) f.page.editTaskTitle = '后续草稿'; await f.page.confirmPlanningAction();
    assert.equal(f.page.editTaskId, later ? 'task-a' : '');
  }
});

test('restore conflict is a determinate error directing the user to edit the exact task', async () => {
  const f = await fixture({ toggle: () => { throw new CampusFlowRequestError(409, 'ACTION_CONFLICT', 'raw ignored'); } });
  await f.page.toggle(sampleTask('completed', { status: 'completed' }));
  assert.match(f.page.errorText, /调整时间/); assert.equal(f.changed.length, 0); assert.equal(f.page.mutationBusy, false);
});

test('editing one boundary of a naive legacy interval uses Shanghai on non-Shanghai devices', async () => {
  const previous = process.env.TZ; process.env.TZ = 'UTC';
  try {
    const f = await fixture(); f.page.beginTaskEdit(sampleTask('legacy', { start_at: '2028-10-20T09:00:00', end_at: '2028-10-20T10:00:00' }));
    f.page.editTaskEnd = '2028-10-20 11:00'; await f.page.previewTaskEdit();
    assert.equal(f.calls[0][1].task.start_at, '2028-10-20T09:00:00');
    assert.equal(f.calls[0][1].task.end_at, '2028-10-20T11:00:00+08:00');
  } finally { if (previous === undefined) delete process.env.TZ; else process.env.TZ = previous; }
});

test('cold draft recovery fills only after consent, retaining the original date and Shanghai anchor', async () => {
  const first = await fixture(); first.page.title = '明天复习'; first.page.draftTaskDate = '2026-10-19';
  first.page.draftDateChoice = 'tomorrow'; first.page.draftTaskTime = '18:30'; first.page.draftAnchorDate = '2026-10-18';
  first.page.stageTaskDraft(); await first.drafts.store.flush(first.drafts.lease);
  const next = await fixture({ driver: first.drafts.driver });
  assert.equal(next.page.title, ''); assert.equal(next.calls.length, 0); assert.ok(next.page.recoveredDraft);
  next.page.restoreTaskDraft();
  assert.equal(next.page.title, '明天复习'); assert.equal(next.page.draftTaskDate, '2026-10-19');
  assert.equal(next.page.draftAnchorDate, '2026-10-18'); assert.equal(next.page.draftTaskTime, '18:30');
  assert.equal(next.calls.length, 0, 'restoring never previews or creates a server action');
});

test('disk failure before operation persistence prevents confirmation and retains a recoverable pointer', async () => {
  const f = await fixture(); f.page.title = '先保存指针'; await f.page.addTask();
  f.drafts.driver.failWrite = true; await f.page.confirmPlanningAction();
  assert.equal(f.calls.filter(c => c[0] === 'confirm').length, 0);
  assert.equal(f.page.pendingProposals.length, 1); assert.match(f.page.errorText, /本次未提交/);
  assert.equal(f.page.title, '先保存指针');
});

test('unknown confirmation cold restart queries the same proposal without issuing a replacement write', async () => {
  let original;
  const first = await fixture({ preview: a => { original = clone(a); return a; }, confirm: () => { throw Error('lost response'); } });
  first.page.title = '已经提交但回包丢失'; await first.page.addTask(); await first.page.confirmPlanningAction();
  assert.equal(first.page.actionState.phase, 'uncertain');
  const next = await fixture({ driver: first.drafts.driver, status: id => { assert.equal(id, original.proposal_id); return applied(original); } });
  assert.equal(next.page.pendingProposals.length, 1); assert.equal(next.calls.length, 0);
  await next.page.recoverProposal(next.page.pendingProposals[0]);
  assert.equal(next.page.actionState.phase, 'resolved'); assert.equal(next.page.pendingProposals.length, 0);
  assert.equal(next.page.recoveredDraft, null); assert.equal(next.changed.length, 1);
  assert.equal(next.calls.some(c => ['confirm', 'preview', 'cancel'].includes(c[0])), false);
});

test('input typed after an unknown submission survives receipt resolution and a cold restart', async () => {
  let original;
  const f = await fixture({ preview: a => { original = clone(a); return a; }, confirm: () => { throw Error('offline'); }, status: () => applied(original) });
  f.page.title = '原安排'; await f.page.addTask(); await f.page.confirmPlanningAction();
  f.page.title = '后来新输入'; f.page.stageTaskDraft(); await f.drafts.store.flush(f.drafts.lease);
  await f.page.recoverProposal(f.page.pendingProposals[0]);
  assert.equal(f.page.title, '后来新输入');
  const next = await fixture({ driver: f.drafts.driver }); next.page.restoreTaskDraft();
  assert.equal(next.page.title, '后来新输入');
});

test('clear/account invalidation during pre-submit disk write cannot send the old proposal', async () => {
  const f = await fixture(); f.page.title = '旧账号输入'; await f.page.addTask();
  const held = deferred(), started = deferred();
  f.drafts.driver.beforeWrite = async () => { started.resolve(); await held.promise; };
  const submitting = f.page.confirmPlanningAction(); await started.promise;
  const clearing = f.drafts.store.clear(); f.page.draftLease = null; f.page.draftScopeChanged();
  held.resolve(); await submitting; await clearing;
  assert.equal(f.calls.some(c => c[0] === 'confirm'), false); assert.equal(f.page.title, '');
  assert.equal(f.page.actionState.action, null);
});

test('discard refuses an unresolved submission and a newer draft revision', async () => {
  const f = await fixture({ confirm: () => { throw Error('offline'); } }); f.page.title = '待核对';
  await f.page.addTask(); await f.page.confirmPlanningAction();
  f.page.recoveredDraft = f.drafts.store.read(f.drafts.lease, { kind: 'new-task', ownerId: 'main' });
  await f.page.discardTaskDraft(); assert.ok(f.page.recoveredDraft); assert.match(f.page.draftMessage, /待核对/);
  const clean = await fixture(); clean.page.title = '第一版'; clean.page.stageTaskDraft(); await clean.drafts.store.flush(clean.drafts.lease);
  const old = clean.drafts.store.read(clean.drafts.lease, { kind: 'new-task', ownerId: 'main' });
  clean.page.title = '更新版'; clean.page.stageTaskDraft(); clean.page.recoveredDraft = old;
  await clean.page.discardTaskDraft();
  assert.equal(clean.drafts.store.read(clean.drafts.lease, { kind: 'new-task', ownerId: 'main' }).payload.title, '更新版');
});

test('read-back failure or wrong proposal ID leaves the saved pointer blocked, never interprets 404 as failure to apply', async () => {
  let original;
  const first = await fixture({ preview: a => { original = clone(a); return a; }, confirm: () => { throw Error('offline'); } });
  first.page.title = '核对原编号'; await first.page.addTask(); await first.page.confirmPlanningAction();
  for (const status of [() => { throw new CampusFlowRequestError(404, 'ACTION_NOT_FOUND', 'missing'); }, () => applied({ ...original, proposal_id: 'wrong-id' })]) {
    const next = await fixture({ driver: first.drafts.driver, status });
    await next.page.recoverProposal(next.page.pendingProposals[0]);
    assert.equal(next.page.actionState.phase, 'uncertain'); assert.equal(next.page.pendingProposals.length, 1);
    assert.equal(next.page.writesBlocked(), true); assert.equal(next.calls.some(c => ['confirm','preview'].includes(c[0])), false);
  }
});

test('old time picker callback cannot repopulate a freshly cleared draft or a hidden page', async () => {
  for (const transition of ['clear', 'hide']) {
    const f = await fixture(); let picker;
    f.page.getUIContext = () => ({ animateTo: (_o, fn) => fn(), showTimePickerDialog: value => { picker = value; } });
    f.page.draftTaskTime = '14:00'; f.page.openTimePicker();
    if (transition === 'clear') {
      await f.drafts.store.clear(); f.page.draftLease = await f.drafts.store.activate(f.drafts.lease.scope); f.page.draftScopeChanged();
    } else { f.page.active = false; f.page.activityChanged(); }
    const before = f.page.draftTaskTime; picker.onAccept({ hour: 21, minute: 15 });
    assert.equal(f.page.draftTaskTime, before);
    assert.equal(f.drafts.store.read(f.page.draftLease, { kind: 'new-task', ownerId: 'main' }), undefined);
  }
});

function captureIntent(overrides={}) {
  return {text:'',date:'',time:'',durationMinutes:null,anchorDate:'2026-10-18',timezone:'Asia/Shanghai',source:'home',...overrides};
}
function openCapture(page,intent=captureIntent()) {
  page.captureOnly=true;page.captureIntent=intent;page.captureRevision++;page.captureRequested();
}
function reviewFor(action) {
  const value=clone(action);value.payload.task.candidate_id='candidate-a';value.course_policy_version=1;
  value.state_version={timetable:1,planning:3};
  value.course_reviews=[{candidate_id:'candidate-a',task_id:null,allow_during_course:value.payload.task.allow_during_course,
    state:'needs_review',review_digest:'a'.repeat(64),candidate_digest:'b'.repeat(64),requires_acknowledgement:true,revoke_only:false,
    school:'杭州电子科技大学',campus:'下沙校区',timezone:'Asia/Shanghai',timetable_version:1,planning_version:3,task_version:null,
    overlaps:[{course_key:'c'.repeat(64),course:{date:'2028-10-20',title:'软件工程',start_time:'14:30',end_time:'16:05',location:'教研楼311',teacher:''},
      overlap_start_at:'2028-10-20T15:30:00+08:00',overlap_end_at:'2028-10-20T16:05:00+08:00'}]}];
  return value;
}

test('home capture borrows the same Plan instance and restores its exact nested detail stack on close', async () => {
  const f=await fixture();const closed=[];f.page.onCloseCapture=()=>closed.push(true);
  f.page.openDetails('plan','plan-a');f.page.openDetails('task','task-a');
  const previous=clone(f.page.detailStack),controller=f.page.actionManager();
  f.page.selectedDate='2028-11-04';f.page.currentView='goals';f.page.taskFilter='completed';
  openCapture(f.page);assert.equal(f.page.detailKind,'draft');assert.equal(f.page.detailStack.length,previous.length+1);
  assert.deepEqual(f.page.detailStack.slice(0,previous.length),previous);
  assert.equal(f.page.actionManager(),controller);f.page.title='关闭仍保留的输入';f.page.stageTaskDraft();
  f.page.finishCapture();await f.drafts.store.flush(f.drafts.lease);
  assert.deepEqual(f.page.detailStack,previous);assert.equal(f.page.detailKind,'task');assert.equal(f.page.detailId,'task-a');
  assert.equal(f.page.selectedDate,'2028-11-04');assert.equal(f.page.currentView,'goals');assert.equal(f.page.taskFilter,'completed');
  assert.equal(f.page.title,'关闭仍保留的输入');assert.equal(closed.length,1);assert.equal(f.calls.length,0);
});

test('gap intent cannot overwrite a visible or recovered draft without explicit adoption', async () => {
  const f=await fixture();f.page.title='原待办';f.page.draftTaskDate='2028-11-03';f.page.draftTaskTime='17:00';
  f.page.durationText='60';f.page.stageTaskDraft();await f.drafts.store.flush(f.drafts.lease);
  const intent=captureIntent({source:'gap',text:'复习',date:'2028-11-04',time:'15:00',durationMinutes:25});
  openCapture(f.page,intent);assert.equal(f.page.title,'原待办');assert.equal(f.page.draftTaskDate,'2028-11-03');assert.equal(f.page.durationText,'60');
  assert.deepEqual(f.page.pendingCaptureIntent,intent);f.page.applyCaptureSuggestion();
  assert.equal(f.page.title,'原待办');assert.equal(f.page.draftTaskDate,'2028-11-04');assert.equal(f.page.durationText,'25');assert.equal(f.calls.length,0);
  await f.drafts.store.flush(f.drafts.lease);const restored=await fixture({driver:f.drafts.driver});
  openCapture(restored.page,intent);assert.equal(restored.page.title,'');assert.ok(restored.page.recoveredDraft);
  assert.equal(restored.page.pendingCaptureIntent.source,'gap');assert.equal(restored.calls.length,0);
});

test('parsing only fills editable fields with the original anchor; preview has a complete duration-derived end', async () => {
  const f=await fixture();f.page.title='明晚八点复习一小时';f.page.draftAnchorDate='2026-10-18';
  f.page.parseCapture();assert.equal(f.calls.length,0);assert.equal(f.page.captureOriginalText,'明晚八点复习一小时');
  assert.equal(f.page.title,'复习');assert.equal(f.page.draftTaskDate,'2026-10-19');assert.equal(f.page.draftTaskTime,'20:00');assert.equal(f.page.durationText,'60');
  assert.equal(f.page.allowDuringCourse,false);await f.page.addTask();
  assert.deepEqual(f.calls[0],['preview',{operation:'create_task',task:{title:'复习',start_at:'2026-10-19T20:00:00+08:00',end_at:'2026-10-19T21:00:00+08:00',reminder_minutes:null,location:null,allow_during_course:false}}]);
  assert.equal(f.calls.some(call=>call[0]==='confirm'),false);
});

test('duration crosses midnight explicitly, while invalid or missing date/time never becomes a guessed interval', async () => {
  const f=await fixture();f.page.title='夜间任务';f.page.draftTaskDate='2028-10-20';f.page.draftTaskTime='23:30';f.page.durationText='120';
  await f.page.addTask();assert.equal(f.calls[0][1].task.end_at,'2028-10-21T01:30:00+08:00');
  for(const input of [{date:'',time:'20:00',duration:'25'},{date:'2028-10-20',time:'',duration:'25'},
    {date:'2028-10-20',time:'23:59',duration:''},{date:'9999-12-31',time:'23:30',duration:'120'}]) {
    const item=await fixture();item.page.title='保留';item.page.draftTaskDate=input.date;item.page.draftTaskTime=input.time;item.page.durationText=input.duration;
    await item.page.addTask();assert.equal(item.calls.length,0);assert.equal(item.page.title,'保留');assert.ok(item.page.errorText);
  }
});

test('explicit course permission reaches preview, and missing overlap acknowledgement never persists an operation or confirms', async () => {
  const f=await fixture({preview:reviewFor});f.page.title='阅读资料';f.page.draftTaskDate='2028-10-20';f.page.draftTaskTime='15:30';
  f.page.durationText='45';f.page.allowDuringCourse=true;await f.page.addTask();
  assert.equal(f.calls[0][1].task.allow_during_course,true);assert.equal(f.page.actionState.phase,'review');
  await f.page.confirmPlanningAction();assert.equal(f.drafts.store.operations(f.drafts.lease).length,0);
  assert.equal(f.calls.some(call=>call[0]==='confirm'),false);assert.match(f.page.errorText,/仍这样安排/);
  await f.page.confirmPlanningAction([{candidate_id:'candidate-a',review_digest:'d'.repeat(64)}]);
  assert.equal(f.drafts.store.operations(f.drafts.lease).length,0);assert.equal(f.calls.some(call=>call[0]==='confirm'),false);
  await f.page.confirmPlanningAction([{candidate_id:'candidate-a',review_digest:'a'.repeat(64)}]);
  assert.deepEqual(f.confirmationAcks,[[{candidate_id:'candidate-a',review_digest:'a'.repeat(64)}]]);
  assert.equal(f.page.actionState.phase,'resolved'); assert.equal(f.changed.length,1);
  assert.equal(f.drafts.store.operations(f.drafts.lease).length,0,'the receipt atomically settles the same proposal pointer');
});

test('invalid duration text and the original phrase survive local persistence and explicit cold restoration', async () => {
  const f=await fixture();f.page.title='复习';f.page.captureOriginalText='明晚八点复习一小时';f.page.draftAnchorDate='2026-10-18';
  f.page.draftTaskDate='2026-10-19';f.page.draftTaskTime='20:00';f.page.durationText='1.';f.page.allowDuringCourse=true;
  f.page.stageTaskDraft();await f.drafts.store.flush(f.drafts.lease);await f.page.addTask();
  assert.equal(f.calls.length,0);assert.match(f.page.errorText,/整数分钟/);
  const saved=f.drafts.store.read(f.drafts.lease,{kind:'new-task',ownerId:'main'});assert.equal(saved.payload.durationMinutes,null);assert.equal(saved.payload.durationText,'1.');
  const next=await fixture({driver:f.drafts.driver});next.page.restoreTaskDraft();
  assert.equal(next.page.durationText,'1.');assert.equal(next.page.allowDuringCourse,true);assert.equal(next.page.captureOriginalText,'明晚八点复习一小时');
  assert.equal(next.page.draftAnchorDate,'2026-10-18');assert.equal(next.page.draftTaskDate,'2026-10-19');assert.equal(next.calls.length,0);
});

test('old six-field task drafts remain readable without fabricated duration or course permission', async () => {
  const f=await fixture();f.drafts.store.stage(f.drafts.lease,{kind:'new-task',ownerId:'main'},
    {title:'旧任务',date:'2026-10-19',dateChoice:'tomorrow',time:'18:30',anchorDate:'2026-10-18',timezone:'Asia/Shanghai'});
  await f.drafts.store.flush(f.drafts.lease);const next=await fixture({driver:f.drafts.driver});next.page.restoreTaskDraft();
  assert.equal(next.page.title,'旧任务');assert.equal(next.page.durationText,'');assert.equal(next.page.allowDuringCourse,false);
  assert.equal(next.page.captureOriginalText,'');assert.equal(next.page.draftTaskDate,'2026-10-19');assert.equal(next.calls.length,0);
});

test('unsupported or vague input preserves its reason and exact source instead of silently becoming a confident schedule', async () => {
  const f=await fixture();f.page.title='每周五复习';f.page.draftAnchorDate='2026-10-18';f.page.parseCapture();
  assert.equal(f.calls.length,0);assert.equal(f.page.captureOriginalText,'每周五复习');assert.equal(f.page.draftTaskDate,'');
  assert.ok(f.page.captureIssues.length>0,'unsupported rule reasons must be visible in the page, including after restoration');
  f.page.title='周五下午交报告';f.page.parseCapture();assert.equal(f.page.draftTaskTime,'');assert.ok(f.page.captureIssues.some(issue=>issue.field==='time'));
});

test('assistant handoff includes the current edited fields after parsing, with the original sentence only as context', async () => {
  const f=await fixture(),prompts=[];f.page.onOpenAgent=prompt=>prompts.push(prompt);
  f.page.title='明晚八点复习一小时';f.page.draftAnchorDate='2026-10-18';f.page.parseCapture();
  f.page.title='核对实验报告';f.page.selectDraftDate('2026-10-22','capture');f.page.selectDraftTime('18:30');
  f.page.durationText='45';f.page.allowDuringCourse=true;f.page.captureToAssistant();
  assert.equal(prompts.length,1);assert.match(prompts[0],/核对实验报告/);assert.match(prompts[0],/2026-10-22/);
  assert.match(prompts[0],/18:30/);assert.match(prompts[0],/45/);assert.match(prompts[0],/课内|上课/);
  assert.match(prompts[0],/明晚八点复习一小时/);assert.equal(f.calls.length,0);
});

test('closing an unadopted gap suggestion does not leak that temporary suggestion into the next plain capture', async () => {
  const f=await fixture();f.page.title='保留原草稿';f.page.draftTaskDate='2026-10-22';f.page.draftTaskTime='18:30';
  const intent=captureIntent({source:'gap',text:'复习',date:'2026-10-18',time:'15:00',durationMinutes:25});
  openCapture(f.page,intent);assert.ok(f.page.pendingCaptureIntent);f.page.finishCapture();
  f.page.captureOnly=false;openCapture(f.page);
  assert.equal(f.page.pendingCaptureIntent,null);assert.equal(f.page.title,'保留原草稿');
  assert.equal(f.page.draftTaskDate,'2026-10-22');assert.equal(f.page.draftTaskTime,'18:30');
  assert.equal(f.calls.length,0);
});

test('home capture keeps earlier detail frames mounted so their Scroll nodes can retain position', async () => {
  const f=await fixture();f.page.openDetails('plan','plan-a');f.page.openDetails('task','task-a');
  const previous=clone(f.page.detailStack);openCapture(f.page);
  assert.deepEqual(f.page.detailStack.slice(0,previous.length),previous,'ForEach must retain the original keyed detail frames while the capture is above them');
  assert.equal(f.page.detailStack.at(-1).kind,'draft');assert.equal(f.page.backLabel(),'返回今日');f.page.closeDetails();
  assert.deepEqual(f.page.detailStack,previous);assert.equal(f.page.captureOpened,false);
});

test('hiding capture during preview rejects the late response after reopening and preserves the edited input', async () => {
  const waiting=deferred();const f=await fixture({preview:async action=>{await waiting.promise;return action;}});
  openCapture(f.page);f.page.title='原问题';const pending=f.page.addTask();
  assert.equal(f.page.actionState.phase,'previewing');f.page.active=false;f.page.activityChanged();
  f.page.active=true;f.page.activityChanged();f.page.title='返回后的输入';waiting.resolve();await pending;
  assert.equal(f.page.actionState.action,null);assert.equal(f.page.actionState.phase,'idle');
  assert.equal(f.page.title,'返回后的输入');assert.equal(f.changed.length,0);assert.equal(f.calls.some(call=>call[0]==='confirm'),false);
});

test('switching draft account during preview discards the old candidate and cannot publish a success', async () => {
  const waiting=deferred();const f=await fixture({preview:async action=>{await waiting.promise;return action;}});
  openCapture(f.page);f.page.title='旧账号输入';const pending=f.page.addTask();
  const newLease=await f.drafts.store.activate('https://other-service.example\nother-user');
  f.page.draftLease=newLease;f.page.draftScopeChanged();f.page.title='新账号输入';
  waiting.resolve();await pending;assert.equal(f.page.actionState.action,null);assert.equal(f.page.actionState.phase,'idle');
  assert.equal(f.page.title,'新账号输入');assert.equal(f.changed.length,0);assert.equal(f.page.captureOpened,false);
});

test('capture Watch cannot consume a new revision using the old intent, and repeats do not duplicate detail frames', async () => {
  const f=await fixture();openCapture(f.page,captureIntent({requestRevision:1}));f.page.finishCapture();
  f.page.captureOnly=false;f.page.captureRequested();
  f.page.captureRevision=2;f.page.captureRequested();
  f.page.captureOnly=true;f.page.captureRequested();
  assert.equal(f.page.captureOpened,false);assert.equal(f.page.appliedCaptureRevision,1);
  f.page.captureIntent=captureIntent({requestRevision:2});f.page.captureRequested();
  assert.equal(f.page.captureOpened,true);assert.equal(f.page.appliedCaptureRevision,2);
  const stack=clone(f.page.detailStack);f.page.captureRequested();assert.deepEqual(f.page.detailStack,stack);
});

test('captureOnly arriving after intent and revision still opens once with the matching request', async () => {
  const f=await fixture();f.page.captureIntent=captureIntent({requestRevision:1});f.page.captureRequested();
  f.page.captureRevision=1;f.page.captureRequested();assert.equal(f.page.captureOpened,false);
  f.page.captureOnly=true;f.page.captureRequested();assert.equal(f.page.captureOpened,true);
  assert.equal(f.page.detailKind,'draft');assert.equal(f.page.appliedCaptureRevision,1);
  assert.match(raw,/@Watch\('captureRequested'\) captureOnly/);
  assert.match(raw,/@Watch\('captureRequested'\) captureIntent/);
  assert.match(raw,/@Watch\('captureRequested'\) captureRevision/);
});
