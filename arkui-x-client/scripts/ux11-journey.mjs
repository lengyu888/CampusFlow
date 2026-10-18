import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { mkdtemp, rm, writeFile, mkdir } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { JourneyBridge, loadJourneyModules, localFiles, JourneyScheduler, eventually, tick } from './helpers/ux11-journey.mjs';

// Continuous synthetic journey, not a native UI test or a paid/model evaluation.
// Every server ID below comes from an actual authenticated response. No SQL seeds.
const report={contract_version:1,synthetic:true,boundary:'Actual ETS methods + native adapter shims + real ASGI/SQLite + scripted provider stream; no native rendering or real model.',steps:[],requests:[],status:'running'};
let now=Date.parse('2030-10-21T07:00:00+08:00');
const loader=loadJourneyModules(()=>now), m=loader.module, bridge=new JourneyBridge();
const directory=await mkdtemp(path.join(tmpdir(),'campusflow-ux11-'));
const cleanups=[];
function step(name,input,output,assertions){report.steps.push({name,input,output,assertions});process.stdout.write(`PASS ${name}\n`);}
const course={date:'2030-10-21',title:'合成高等数学',start_time:'08:00',end_time:'09:00',location:'合成教室101',teacher:''};
const editor={date:'',title:'',start_time:'',end_time:'',location:'',teacher:''};
const base='https://journey.invalid';
try{
  const initialized=await bridge.rpc('init',{wall_time:'2030-10-21T07:00:00+08:00'});
  assert.equal(initialized.network_mode,'asgi_and_mock_only');
  const Api=loader.api(bridge,report.requests), anon=new Api(base);
  const authA=await anon.register('journey-a@example.invalid','Synthetic-password-A1!','合成同学甲');
  const authB=await anon.register('journey-b@example.invalid','Synthetic-password-B1!','合成同学乙');
  const apiA=new Api(base,authA.access_token),apiB=new Api(base,authB.access_token);
  assert.notEqual(authA.user.user_id,authB.user.user_id);
  assert.equal((await apiA.me()).user_id,authA.user.user_id);
  const files=await localFiles(loader,directory),store=new m.DraftStore(files.draftDriver,new JourneyScheduler(()=>now));
  await store.initialize();const scopeA=m.historyScope(base,authA.user.user_id),scopeB=m.historyScope(base,authB.user.user_id);
  let lease=await store.activate(scopeA);
  step('register-two-owners','Two synthetic accounts without model keys',{user_a:authA.user.user_id,user_b:authB.user.user_id},['Distinct real authenticated owners','No preseeded account or timetable']);

  const Onboarding=loader.page('OnboardingPage',{CampusFlowApi:Api,localDrafts:store,Scroller:class{scrollEdge(){}},Edge:{Top:'top'}});
  const page=new Onboarding();Object.assign(page,{baseUrl:base,token:authA.access_token,draftLease:lease});
  let completed=null;page.onCompleted=user=>{completed=user;};page.aboutToAppear();
  await eventually(()=>page.expectedRevision.length===64&&!page.loading,'onboarding baseline');
  page.nextStep();assert.equal(page.step,1);
  for(const [field,value] of Object.entries(course))page.updateEditor(field,value);
  page.addEntry();assert.deepEqual(page.entries,[course]);page.nextStep();assert.equal(page.step,2);
  const beforeOnboarding=await apiA.timetable();assert.equal(beforeOnboarding.entries.length,0);
  await page.finish();assert.ok(completed,`onboarding failed: ${page.message}`);assert.equal(completed.onboarding_complete,true);
  const firstTimetable=await apiA.timetable();assert.deepEqual(firstTimetable.entries,[course]);
  assert.equal(store.operations(lease).length,0);page.aboutToDisappear();await store.flush(lease);
  step('first-guided-course','Actual OnboardingPage editor → confirm → durable operation → real PUT',{course_count:1,revision:firstTimetable.revision,onboarding_completed:true},['Editor did not write server before finish','One exact six-field course persisted','Onboarding callback followed a valid operation receipt']);

  const parsed=m.parseQuickCapture('今晚八点复习一小时','2030-10-21');
  assert.equal(parsed.date,'2030-10-21');assert.equal(parsed.time,'20:00');assert.equal(parsed.durationMinutes,60);
  const action=new m.PlanningActionController(apiA,()=>{},()=>{});cleanups.push(()=>action.dispose());
  const taskDraft={title:parsed.title,start_at:`${parsed.date}T${parsed.time}:00+08:00`,end_at:m.captureEndAt(parsed.date,parsed.time,parsed.durationMinutes),reminder_minutes:null,location:null,allow_during_course:false};
  await action.preview({operation:'create_task',task:taskDraft});assert.equal(action.snapshot().phase,'review',action.snapshot().message);
  assert.equal((await apiA.planning()).tasks.length,0);
  const quickProposal=action.snapshot().action.proposal_id;
  const quickKey={kind:'new-task',ownerId:'main'};
  const quickTicket=store.stage(lease,quickKey,{title:parsed.title,date:parsed.date,time:parsed.time,dateChoice:'calendar',anchorDate:'2030-10-21',timezone:'Asia/Shanghai',durationMinutes:60,durationText:'60',originalText:parsed.originalText,allowDuringCourse:false});
  await store.flush(lease);await store.beginOperation(lease,{kind:'proposal',id:quickProposal,draftKind:'new-task',ownerId:'main',localRevision:quickTicket.localRevision});
  await action.confirm();assert.equal(action.snapshot().phase,'resolved',action.snapshot().message);
  const quickTaskId=m.receiptTaskId(action.snapshot().action);assert.ok(quickTaskId);
  await store.resolveOperation(lease,'proposal',quickProposal,true);
  assert.equal((await apiA.planning()).tasks.length,1);
  step('quick-capture-confirm','今晚八点复习一小时',{proposal_id:quickProposal,task_id:quickTaskId,start_at:taskDraft.start_at,end_at:taskDraft.end_at},['Actual deterministic parser','Preview wrote no task','Explicit confirmation produced exact receipt task ID']);

  const sessionId=randomUUID(),assistantKey=m.assistantDraftKey(sessionId);
  store.stage(lease,assistantKey,{text:'请结合今天课表，安排今晚七点到八点复习。',sessionId,anchorDate:'2030-10-21',timezone:'Asia/Shanghai'});
  store.stage(lease,quickKey,{title:'尚未保存的待办',date:'2030-10-22',time:'',dateChoice:'calendar',anchorDate:'2030-10-21',timezone:'Asia/Shanghai'});
  await store.flush(lease);
  const subscription=await bridge.rpc('subscription.fixture',{name:'mixed'});
  const preview=await apiA.previewSubscription(subscription.url),review=m.parseImportReview(JSON.stringify(preview));
  assert.equal(review.valid,true);assert.equal(review.rows.length,3);
  const classified=m.classifyImportRows(review.rows,firstTimetable.entries,[]);
  assert.deepEqual(classified.rows.map(row=>row.category),['duplicate','new','invalid']);
  assert.equal(m.assembleSelectedImport(review.rows,firstTimetable.entries,[]).valid,false);
  const choices=review.rows.map(row=>({sourceIndex:row.source_index,mode:row.status==='ready'?'default':'exclude',edited:null,sourceIssuesReviewed:true,overlapKey:''}));
  const assembled=m.assembleSelectedImport(review.rows,firstTimetable.entries,choices);assert.equal(assembled.valid,true,assembled.message);
  assert.equal(assembled.entries.length,2);assert.deepEqual((await apiA.timetable()).entries,[course]);
  let timetableOp='';
  const maintenance=new m.TimetableMaintenance(apiA,()=>{},()=>{},randomUUID,async draft=>{
    const submission={operationId:draft.operation.id,expectedRevision:draft.operation.revision,entries:draft.operation.entries,confirmClear:draft.operation.confirmClear};
    const ticket=store.stage(lease,{kind:'timetable',ownerId:'main'},{baselineEntries:draft.baselineEntries,expectedRevision:draft.expectedRevision,draftEntries:draft.draftEntries,editor,editorOpen:false,editorDirty:false,editingIndex:-1,repeatWeeks:1,sourceWarnings:assembled.warnings,anchorDate:'2030-10-21',timezone:'Asia/Shanghai',submission});
    await store.flush(lease);timetableOp=submission.operationId;
    await store.beginOperation(lease,{kind:'timetable',id:timetableOp,draftKind:'timetable',ownerId:'main',localRevision:ticket.localRevision});
  });cleanups.push(()=>maintenance.dispose());maintenance.setActive(true);await eventually(()=>maintenance.snapshot().phase!=='loading','timetable initial read');assert.equal(maintenance.snapshot().phase,'ready');
  assert.equal(maintenance.replaceDraft(assembled.entries),true);await maintenance.save();
  assert.equal(maintenance.snapshot().dirty,false,maintenance.snapshot().message);assert.equal((await apiA.timetable()).entries.length,2);
  await store.resolveOperation(lease,'timetable',timetableOp,true);
  step('mixed-import-explicit-review','3 real parsed synthetic ICS rows',{classifications:classified.rows.map(row=>row.category),excluded_source_index:2,operation_id:timetableOp,saved_courses:2},['Six-field duplicate not repeated','Invalid row blocked assembly until explicit exclusion','Preview and local assembly did not save server data','Real maintenance wrote original revision with durable operation ID']);

  const catalog=await apiA.models();
  await apiA.updateSettings('合成同学甲','杭州电子科技大学','下沙校区',completed.semester,'synthetic-offline-provider-only');
  const skills=await apiA.skills();
  for(const id of ['timetable-planner','ddl-guardian']){const skill=skills.find(item=>item.skill_id===id);if(skill&&!skill.installed)await apiA.installSkill(skill);}
  await bridge.rpc('model.script',{script_id:'evening-review',turns:[
    {tool_calls:[{name:'get_schedule',arguments:{date:'2030-10-21'}}]},
    {tool_calls:[{name:'propose_task_change',arguments:{action:'create',title:'合成晚间复习',start_at:'2030-10-21T19:00:00+08:00',end_at:'2030-10-21T20:00:00+08:00'}}]},
    {text:'离线模型替身：已读取课表并生成候选，请核对后确认。'}]});
  const runScheduler=new JourneyScheduler();let successfulRun=null;
  const run=new m.AgentRunController(apiA,()=>{},value=>{successfulRun=value;},randomUUID,runScheduler);cleanups.push(()=>run.dispose());
  run.configure(scopeA,apiA);run.setActive(true);
  run.setBeforeSubmit(async request=>{
    const ticket=store.stage(lease,assistantKey,{text:request.message,sessionId:request.session_id,anchorDate:'2030-10-21',timezone:'Asia/Shanghai'});
    await store.flush(lease);await store.beginOperation(lease,{kind:'run',id:request.run_id,draftKind:'assistant',ownerId:assistantKey.ownerId,localRevision:ticket.localRevision,runRequest:request});
    // A later input revision while the original submitted revision is pending.
    // Resolving that original operation must not delete this newer unsent text.
    store.stage(lease,assistantKey,{text:'尚未发送的学习想法',sessionId,anchorDate:'2030-10-21',timezone:'Asia/Shanghai'});await store.flush(lease);
  });
  await run.start(sessionId,catalog.default_model,'请结合今天课表，安排今晚七点到八点复习。','new');
  await eventually(async()=>{await run.refresh();return ['succeeded','failed','cancelled','interrupted','budget_exceeded'].includes(run.snapshot().snapshot?.status);},'real runtime terminal');
  assert.equal(run.snapshot().snapshot.status,'succeeded',run.snapshot().message);assert.ok(successfulRun);
  const runSnapshot=run.snapshot().snapshot;
  const traces=runSnapshot.result.tool_traces;
  assert.deepEqual(traces.map(trace=>trace.tool_name),['get_schedule','propose_task_change']);
  assert.ok(traces.every(trace=>trace.status==='success'));
  assert.equal(runSnapshot.result.pending_actions.length,1);const agentProposal=runSnapshot.result.pending_actions[0];
  assert.equal((await apiA.planning()).tasks.length,1,'tool proposal must not create task');
  const history=await apiA.history(sessionId);assert.equal(history.length,2);
  const events=await apiA.agentRunEvents(runSnapshot.run_id,0);assert.ok(events.events.length>0);
  assert.equal(new Set(events.events.map(event=>event.seq)).size,events.events.length);
  await store.resolveOperation(lease,'run',runSnapshot.run_id,true);
  assert.equal(store.read(lease,assistantKey).payload.text,'尚未发送的学习想法','settling old submitted revision must preserve newer draft without restaging it');
  step('agent-actual-tools-offline-provider','Read schedule → propose task → final response',{session_id:sessionId,run_id:runSnapshot.run_id,proposal_id:agentProposal.proposal_id,event_count:events.events.length,history_messages:history.length,tools:traces.map(trace=>({name:trace.tool_name,status:trace.status}))},['Real run scheduler and Agent tool loop','Provider stream alone replaced','Both actual tools report success','Tool produced pending proposal without task write','Authoritative history contains one user/assistant pair']);

  const agentAction=new m.PlanningActionController(apiA,()=>{},()=>{});cleanups.push(()=>agentAction.dispose());
  await agentAction.recover(agentProposal.proposal_id);assert.equal(agentAction.snapshot().phase,'retryable');
  const auxKey={kind:'new-task',ownerId:`proposal:${agentProposal.proposal_id}`};
  const auxTicket=store.stage(lease,auxKey,{title:'',date:'',time:'',dateChoice:'none',anchorDate:'2030-10-21',timezone:'Asia/Shanghai'});
  await store.flush(lease);await store.beginOperation(lease,{kind:'proposal',id:agentProposal.proposal_id,draftKind:'new-task',ownerId:auxKey.ownerId,localRevision:auxTicket.localRevision,sessionId,
    proposalRequest:{proposal_id:agentProposal.proposal_id,intent:'confirm',course_acknowledgements:[]}});
  await bridge.rpc('fault.next_response',{http_method:'POST',path:`/api/v1/actions/${agentProposal.proposal_id}/confirm`,mode:'drop_after_commit'});
  await agentAction.confirm();assert.equal(agentAction.snapshot().phase,'uncertain');
  assert.equal((await apiA.planning()).tasks.length,2,'write committed before response was lost');
  const pointerFiles=await localFiles(loader,directory),pointerStore=new m.DraftStore(pointerFiles.draftDriver,new JourneyScheduler(()=>now));
  await pointerStore.initialize();const pointerLease=await pointerStore.activate(scopeA);
  const pointer=pointerStore.operations(pointerLease).find(item=>item.id===agentProposal.proposal_id);assert.equal(pointer.proposalRequest.intent,'confirm');
  const recoveredAction=new m.PlanningActionController(apiA,()=>{},()=>{});cleanups.push(()=>recoveredAction.dispose());
  const beforeRecovery=report.requests.length;await recoveredAction.recover(pointer.id);assert.equal(recoveredAction.snapshot().phase,'resolved');
  assert.ok(report.requests.slice(beforeRecovery).every(request=>request.method==='GET'));
  const agentTaskId=m.receiptTaskId(recoveredAction.snapshot().action);assert.ok(agentTaskId);assert.notEqual(agentTaskId,quickTaskId);
  await store.resolveOperation(lease,'proposal',agentProposal.proposal_id,true);
  const replay=await apiA.confirmAction(agentProposal.proposal_id);assert.equal(m.receiptTaskId(replay.action),agentTaskId);
  assert.equal((await apiA.planning()).tasks.length,2);
  step('confirm-loss-and-original-id-recovery','Explicit confirmation; drop actual committed response',{proposal_id:agentProposal.proposal_id,task_id:agentTaskId,receipt_id:recoveredAction.snapshot().action.receipt.receipt_id},['Response loss enters uncertain, not success','Fresh store/controller recovered durable original-ID pointer with GET only','Idempotent replay created no duplicate task','Unsent assistant and unrelated task drafts remain intact']);

  const addedCourse={date:'2030-10-21',title:'合成晚间课程',start_time:'19:00',end_time:'19:45',location:'合成教室303',teacher:''};
  maintenance.replaceDraft(maintenance.snapshot().entries.concat([addedCourse]));await maintenance.save();
  assert.equal(maintenance.snapshot().dirty,false,maintenance.snapshot().message);await store.resolveOperation(lease,'timetable',timetableOp,true);
  const replanning=new m.PlanningReplanController(apiA,()=>{},()=>{},()=>now);cleanups.push(()=>replanning.dispose());
  replanning.setActive(true);await eventually(()=>replanning.snapshot().report!==null,'conflict initial read');
  assert.ok(replanning.snapshot().report.conflicts.some(item=>item.task_id===agentTaskId));
  const beforeReplan=(await apiA.planning()).tasks.find(task=>task.task_id===agentTaskId);
  await replanning.preview();assert.equal(replanning.snapshot().phase,'review',replanning.snapshot().message);
  const changes=replanning.snapshot().preview.changes;assert.ok(changes.some(change=>change.task_id===agentTaskId));
  assert.equal((await apiA.planning()).tasks.find(task=>task.task_id===agentTaskId).start_at,beforeReplan.start_at);
  await replanning.confirm();assert.equal(replanning.snapshot().phase,'applied',replanning.snapshot().message);
  const replanned=(await apiA.planning()).tasks.find(task=>task.task_id===agentTaskId);
  assert.notEqual(replanned.start_at,beforeReplan.start_at);assert.equal(replanned.task_id,beforeReplan.task_id);
  assert.equal((await apiA.planningConflicts()).conflicts.length,0);
  step('course-change-conflict-and-replan','Save 19:00–19:45 course over actual proposed task',{task_id:agentTaskId,replan_id:replanning.snapshot().preview.replan_id,old_start:beforeReplan.start_at,new_start:replanned.start_at,course_revision:(await apiA.timetable()).revision},['Confirmed timetable change produced real conflict','Replan preview did not mutate task','Confirmation preserved task ID and duration','Fresh conflict read has no ordinary conflict']);

  const statuses=new m.TaskStatusController(store,()=>{},()=>{},randomUUID,()=>now);cleanups.push(()=>statuses.dispose());
  statuses.configure(scopeA,authA.user.user_id,apiA,lease);statuses.setActive(true);
  await statuses.begin(replanned,'complete');let statusItem=statuses.snapshot().items.find(item=>item.operationId===statuses.snapshot().selectedId);
  assert.equal(statusItem.phase,'applied',statusItem.message);const firstCompletion=statusItem.operationId;
  let liveTask=(await apiA.planning()).tasks.find(task=>task.task_id===agentTaskId);assert.equal(liveTask.status,'completed');
  assert.equal(liveTask.completion_operation_id,firstCompletion);
  await statuses.begin(liveTask,'restore');statusItem=statuses.snapshot().items.find(item=>item.operationId===statuses.snapshot().selectedId);
  assert.equal(statusItem.phase,'review',statusItem.message);const restoreId=statusItem.operationId;
  assert.equal((await apiA.planning()).tasks.find(task=>task.task_id===agentTaskId).status,'completed');
  await statuses.confirm([],restoreId);assert.equal(statuses.snapshot().items.find(item=>item.operationId===restoreId).phase,'applied');
  liveTask=(await apiA.planning()).tasks.find(task=>task.task_id===agentTaskId);assert.equal(liveTask.status,'pending');
  const quickTask=(await apiA.planning()).tasks.find(task=>task.task_id===quickTaskId);
  await statuses.begin(quickTask,'complete');assert.equal(statuses.snapshot().pendingCount,0);
  step('complete-and-reviewed-restore','Complete exact agent task, then explicitly restore; complete quick task',{agent_task_id:agentTaskId,complete_operation:firstCompletion,restore_operation:restoreId,agent_status:'pending',quick_task_id:quickTaskId,quick_status:'completed'},['Restore preview leaves current task completed','Confirmation uses original completion provenance and current revision','All durable status pointers settled']);

  const focusStore=new m.FocusStore(files.focusDriver);await focusStore.initialize();let monotonic=1000;
  const clockSession=randomUUID(),focusScheduler=new JourneyScheduler();
  const focus=new m.FocusController(focusStore,{sample:async()=>({wallMs:now,monotonicMs:monotonic,clockSessionId:clockSession})},()=>{},randomUUID,focusScheduler);
  cleanups.push(()=>focus.dispose());await focus.configure(scopeA,authA.user.user_id,apiA);focus.setForeground(true);
  await focus.start(agentTaskId,60000,'online');assert.equal(focus.snapshot().local.localState,'running',focus.snapshot().message);
  const focusId=focus.snapshot().selectedRecordId;
  async function advanceSamples(seconds){for(let i=0;i<seconds;i++){const result=await bridge.rpc('clock.advance',{milliseconds:1000});now=Date.parse(result.wall_time);monotonic+=1000;await focusScheduler.step();await focus.mutationTail;await tick();}}
  await advanceSamples(65);assert.equal(focus.snapshot().local.elapsedMs,65000);assert.equal(focus.snapshot().local.localState,'running','target is not automatic finish');
  await focus.pause();assert.equal(focus.snapshot().local.localState,'paused');await focus.resume();await advanceSamples(5);await focus.end();
  const detail=await apiA.focusDetail(focusId);assert.equal(detail.record.state,'ended');assert.equal(detail.record.confirmed_elapsed_ms,70000);
  assert.equal(detail.intervals.reduce((sum,item)=>sum+item.elapsed_ms,0),70000);assert.equal(detail.unknown_gaps.length,0);
  assert.equal((await apiA.planning()).tasks.find(task=>task.task_id===agentTaskId).status,'pending');
  step('focus-confirmed-intervals','Online 60s target; 65s → pause → resume → 5s → end',{record_id:focusId,task_id:agentTaskId,elapsed_ms:70000,intervals:detail.intervals.length,unknown_gaps:0},['Native clock boundary replaced by deterministic samples','Timer starts after durable receipt/current-state checks','Only elapsed differences sent; raw monotonic stays local','Target does not complete task','Pause/end travel through real FocusService']);

  const reviewController=new m.ReviewController(()=>{});cleanups.push(()=>reviewController.dispose());
  reviewController.configure(scopeA,authA.user.user_id,apiA);reviewController.setActive(true);await reviewController.select('day','2030-10-21');
  assert.equal(reviewController.snapshot().phase,'ready',reviewController.snapshot().message);const day=reviewController.snapshot().snapshot;
  assert.equal(day.totals.confirmed_elapsed_ms,70000);assert.equal(day.totals.current_completed_count,1);assert.equal(day.totals.unknown_gap_count,0);
  await reviewController.select('week','2030-10-21');const week=reviewController.snapshot().snapshot;assert.equal(week.totals.confirmed_elapsed_ms,70000);
  const noteKey=m.reviewNoteKey('day','2030-10-21');store.stage(lease,noteKey,{period:'day',anchor:'2030-10-21',timezone:'Asia/Shanghai',text:'合成私人感受，不默认发送'});await store.flush(lease);
  const summary=m.reviewSummary(day,{completed:true,unscheduled:true,focus:true});assert.ok(summary.includes('70000'));assert.equal(summary.includes('合成私人感受'),false);
  const oldAssistant=store.read(lease,assistantKey).payload.text;assert.equal(oldAssistant,'尚未发送的学习想法');
  const messageCount=(await apiA.history(sessionId)).length;
  step('review-three-evidence-facts','Read same SQLite day/week; select summary without private note',{day_totals:day.totals,week_totals:week.totals,snapshot_digest:day.snapshot_digest,history_messages:messageCount,unsent_draft_preserved:true},['Actual strict validator recalculates source totals','Completion counted by real receipt provenance','Focus totals from real sealed intervals','Summary generation made no run/action request and omitted private note']);

  const beforeOffline=report.requests.length;
  await focus.start(agentTaskId,null,'offline');const offlineId=focus.snapshot().selectedRecordId;
  await advanceSamples(6);assert.equal(focus.snapshot().local.elapsedMs,6000);focus.dispose();
  assert.equal(report.requests.length,beforeOffline,'offline sampling never sends an HTTP checkpoint');
  const offlineFiles=await localFiles(loader,directory),offlineStore=new m.FocusStore(offlineFiles.focusDriver);await offlineStore.initialize();
  const coldFocus=new m.FocusController(offlineStore,{sample:async()=>({wallMs:now,monotonicMs:1,clockSessionId:randomUUID()})},()=>{},randomUUID,new JourneyScheduler());cleanups.push(()=>coldFocus.dispose());
  await coldFocus.configure(scopeA,authA.user.user_id,apiA);
  const recoveredOffline=coldFocus.snapshot().localRecords.find(item=>item.recordId===offlineId);
  assert.equal(recoveredOffline.localState,'paused');assert.equal(recoveredOffline.elapsedMs,5000);assert.equal(recoveredOffline.unknownGapCount,1);
  assert.equal(coldFocus.snapshot().pendingOperations.filter(item=>item.recordId===offlineId).length,2);
  await assert.rejects(()=>apiA.focusDetail(offlineId),error=>error.statusCode===404);
  const reviewWithoutLocal=await apiA.review('day','2030-10-21');assert.equal(reviewWithoutLocal.totals.confirmed_elapsed_ms,70000);assert.equal(reviewWithoutLocal.totals.unknown_gap_count,0);
  step('offline-prefix-crash-recovery','Start offline; sample 6s; dispose without sealing; hydrate actual disk',{local_record_id:offlineId,durable_elapsed_ms:5000,unknown_local_gaps:1,pending_operations:2,server_record_found:false,server_review_ms:70000},['No HTTP checkpoint while offline','Only persisted 5s prefix survives; unproved tail is not guessed','Cold recovery pauses with explicit gap and retains original ordered operation IDs','Unsent local fragments are excluded from server review facts']);

  const failureSession=randomUUID(),failureKey=m.assistantDraftKey(failureSession),failureRun=new m.AgentRunController(apiA,()=>{},()=>{},randomUUID,new JourneyScheduler(()=>now));
  cleanups.push(()=>failureRun.dispose());failureRun.configure(scopeA,apiA);failureRun.setActive(true);
  failureRun.setBeforeSubmit(async request=>{
    const ticket=store.stage(lease,failureKey,{text:request.message,sessionId:failureSession,anchorDate:'2030-10-21',timezone:'Asia/Shanghai'});
    await store.flush(lease);await store.beginOperation(lease,{kind:'run',id:request.run_id,draftKind:'assistant',ownerId:failureKey.ownerId,localRevision:ticket.localRevision,runRequest:request});
  });
  const requestsBeforeFailure=report.requests.length;files.setFailure(true);
  await failureRun.start(failureSession,catalog.default_model,'合成本机保存失败边界','new');files.setFailure(false);
  assert.equal(failureRun.snapshot().phase,'local_error');assert.equal(report.requests.length,requestsBeforeFailure);
  assert.equal(store.read(lease,failureKey).payload.text,'合成本机保存失败边界');await store.flush(lease);
  const failedDraft=store.read(lease,failureKey);await store.remove(lease,failureKey,failedDraft.localRevision);
  step('local-durable-failure-before-http','Fail actual atomic file rename before run submission',{http_requests:0,phase:'local_error',draft_retained:true},['Real FileDraftDriver fails safely','No model or run POST before durable barrier','Raw input remains recoverable; retrying local save does not send']);

  // A real response may arrive after account navigation. Delay only its delivery,
  // never fabricate response contents or bypass the production controller guard.
  let releaseRead,readArrived;const delivered=new Promise(resolve=>{releaseRead=resolve;}),arrived=new Promise(resolve=>{readArrived=resolve;});
  const delayedApi={review:async(period,anchor)=>{const response=await apiA.review(period,anchor);readArrived();await delivered;return response;}};
  reviewController.configure(scopeA,authA.user.user_id,delayedApi);const oldRead=reviewController.refresh();await arrived;
  reviewController.configure(scopeB,authB.user.user_id,apiB);await reviewController.select('day','2030-10-21');
  releaseRead();await oldRead;assert.equal(reviewController.snapshot().snapshot.user_id,authB.user.user_id);
  assert.equal(reviewController.snapshot().snapshot.totals.confirmed_elapsed_ms,0);
  step('late-read-owner-isolation','Delay real A review response; switch to B before delivery',{visible_user:authB.user.user_id,visible_focus_ms:0},['Production generation guard rejects late A snapshot','No A completion or focus facts shown to B']);

  // Simulated process restart: fresh production Store/driver reads the actual files.
  for(const cleanup of cleanups)cleanup();cleanups.length=0;
  await store.flush(lease);const coldFiles=await localFiles(loader,directory),coldStore=new m.DraftStore(coldFiles.draftDriver,new JourneyScheduler(()=>now));
  await coldStore.initialize();const coldLeaseA=await coldStore.activate(scopeA);
  assert.equal(coldStore.read(coldLeaseA,assistantKey).payload.text,'尚未发送的学习想法');
  assert.equal(coldStore.read(coldLeaseA,quickKey).payload.title,'尚未保存的待办');
  assert.equal(coldStore.read(coldLeaseA,noteKey).payload.text,'合成私人感受，不默认发送');
  assert.equal(coldStore.operations(coldLeaseA).length,0);assert.equal(coldStore.taskStatusOperations(coldLeaseA).length,0);
  await apiA.logout();await coldStore.clear();await focusStore.clear();
  assert.equal(coldStore.valid(coldLeaseA),false);
  assert.throws(()=>coldStore.stage(coldLeaseA,assistantKey,{text:'旧账号迟到写入',sessionId,anchorDate:'2030-10-21',timezone:'Asia/Shanghai'}));
  const leaseB=await coldStore.activate(scopeB);assert.equal(coldStore.list(leaseB,'assistant').length,0);assert.equal(coldStore.list(leaseB,'new-task').length,0);assert.equal(coldStore.list(leaseB,'review-note').length,0);
  assert.equal((await apiB.planning()).tasks.length,0);
  await assert.rejects(()=>apiB.actionStatus(agentProposal.proposal_id),error=>error.statusCode===404);
  await assert.rejects(()=>apiB.agentRun(runSnapshot.run_id),error=>error.statusCode===404);
  await assert.rejects(()=>apiB.focusDetail(focusId),error=>error.statusCode===404);
  await assert.rejects(()=>apiA.me(),error=>error.statusCode===401);
  const againA=await anon.login('journey-a@example.invalid','Synthetic-password-A1!'),apiAgainA=new Api(base,againA.access_token);
  assert.equal((await apiAgainA.planning()).tasks.length,2);assert.equal((await apiAgainA.focusDetail(focusId)).record.confirmed_elapsed_ms,70000);
  const database=await bridge.rpc('inspect',{user_id:authA.user.user_id});
  assert.equal(database.data.tasks.length,2);assert.equal(database.data.runs.length,1);assert.equal(database.data.message_count,2);assert.equal(database.data.focus.length,1);
  report.database_counts={tasks:database.data.tasks.length,runs:database.data.runs.length,messages:database.data.message_count,focus_records:database.data.focus.length,focus_operations:database.data.focus_operations.length,task_status_operations:database.data.task_status_operations.length};
  const bKey=m.assistantDraftKey(randomUUID());coldStore.stage(leaseB,bKey,{text:'乙自己的合成草稿',sessionId:bKey.ownerId.slice(8),anchorDate:'2030-10-21',timezone:'Asia/Shanghai'});await coldStore.flush(leaseB);
  const lastFiles=await localFiles(loader,directory),lastStore=new m.DraftStore(lastFiles.draftDriver,new JourneyScheduler(()=>now));await lastStore.initialize();const lastLease=await lastStore.activate(scopeB);
  assert.equal(lastStore.read(lastLease,bKey).payload.text,'乙自己的合成草稿');assert.equal(lastStore.read(lastLease,assistantKey),undefined);
  step('restart-logout-and-account-boundary','Fresh actual stores → explicit logout/clear → B → fresh stores',{restored_a_drafts:3,revoked_a_token:true,b_tasks:0,b_drafts:1,a_server_tasks_preserved:2,a_focus_ms_preserved:70000},['Cold restart restores exact unsent draft/date/notes before logout','Explicit cleanup invalidates old lease and removes local A content','B cannot read A proposal/run/focus exact IDs','Server A facts survive logout; no local A draft resurrects','B draft survives its own cold restart']);

  report.status='passed';report.source_hashes=loader.hashes;
}catch(error){report.status='failed';report.failure={name:error.name??'Error',message:error.message??'Journey failed',location:(error.stack??'').split('\n').find(line=>line.includes('ux11-journey.mjs:'))?.trim()};process.stderr.write(`Journey failed: ${report.failure.message}\n${report.failure.location??''}\n`);process.exitCode=1;}
finally{
  report.source_hashes=loader.hashes;
  for(const cleanup of cleanups)cleanup();
  await bridge.close();await rm(directory,{recursive:true,force:true});
  const output=process.env.CAMPUSFLOW_JOURNEY_REPORT;
  if(output){await mkdir(path.dirname(path.resolve(output)),{recursive:true});await writeFile(output,JSON.stringify(report,null,2)+'\n');}
  process.stdout.write(JSON.stringify({status:report.status,steps:report.steps.length,requests:report.requests.length,report:output??null})+'\n');
}
