import './helpers/theme-fixture.mjs';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripThemeTypeScriptTypes as stripTypeScriptTypes } from './helpers/theme-fixture.mjs';
import { test } from 'node:test';
import { planningPageDependencies, dependencyPrefix, agenda, timetableSnapshot, preferenceSnapshot } from './helpers/planning-overview-fixture.mjs';
import { draftFixture } from './helpers/local-draft-fixture.mjs';
import { PlanningActionController, editedPlanningTime, validPlanningDate, planningTimestamp, CampusFlowRequestError,
  sampleTask, candidate, presentation, deferred, quickCapture, courseReview } from './helpers/planning-action-fixture.mjs';
const source = readFileSync(new URL('../entry/src/main/ets/pages/PlanCenterPage.ets', import.meta.url), 'utf8');
const boundary = source.indexOf('\n  @Builder');
assert.ok(boundary > 0);
const methods = source.slice(0, boundary).replace(/^import \{[\s\S]*?\} from '[^']+';\r?\n/gm, '').replace(/^import [^\n]+;\r?\n/gm, '')
  .replace(/^@Component\r?\n/m, '').replace(/@(Prop|State)\s+|@Watch\('[^']+'\)\s*/g, '')
  .replace('export struct PlanCenterPage', 'class PlanCenterPage') + '\n}\n';
const empty = () => ({plans:[],tasks:[],total_tasks:0,completed_tasks:0,due_today:0,overdue_tasks:0,progress:0});
const course = (extra = {}) => ({date:'2026-10-20',title:'软件工程',start_time:'08:00',end_time:'09:00',location:'第4教学楼',teacher:'甲',...extra});
const task = (id, extra={}) => sampleTask(id,{start_at:'2026-10-20T10:00:00+08:00',end_at:'2026-10-20T11:00:00+08:00',...extra});
async function fixture(handlers={}) {
  const drafts=await draftFixture(); const calls=[];
  class Api {
    constructor(base,token) {this.base=base;this.token=token;}
    async timetable() {calls.push(['timetable',this.base,this.token]);return handlers.timetable ? handlers.timetable(this) : timetableSnapshot([]);}
    async planning() {calls.push(['planning',this.base,this.token]);return handlers.planning ? handlers.planning(this) : empty();}
    async learningPreferences() {calls.push(['preferences',this.base,this.token]);return handlers.preferences ? handlers.preferences(this) : preferenceSnapshot();}
  }
  class Scroll {offset=0;scrollTo(value){this.offset=value.yOffset;}}
  const deps={CampusFlowApi:Api,TextInputController:class {stopEditing(){}},Scroller:Scroll,AppTheme:{motion:()=>0},Curve:{EaseOut:''},
    shanghaiDate:agenda.shanghaiDate,buildDailyAgenda:agenda.buildDailyAgenda,localDrafts:drafts.store,
    formatPlanDateTime:presentation.formatPlanDateTime,PlanningActionController,editedPlanningTime,validPlanningDate,planningTimestamp,CampusFlowRequestError,
    parseQuickCapture:quickCapture.parseQuickCapture,captureEndAt:quickCapture.captureEndAt,validCourseAcknowledgements:courseReview.validCourseAcknowledgements,planningPageDependencies};
  const Page=new Function(...Object.keys(deps),dependencyPrefix+stripTypeScriptTypes(methods)+'\nreturn PlanCenterPage;')(...Object.values(deps));
  const page=new Page();page.baseUrl='https://one.invalid';page.token='first';page.draftLease=drafts.lease;page.draftScopeChanged();
  page.selectedDate='2026-10-20';page.getUIContext=()=>({animateTo:(_options,update)=>update()});
  return {page,calls,drafts};
}

test('105 matched tasks paginate without loss or duplicate titles becoming keys',async()=>{
  const {page}=await fixture();page.overview.tasks=Array.from({length:105},(_,i)=>task(`id-${String(i).padStart(3,'0')}`,{title:'同名待办'}));
  assert.equal(page.queryResult().matched,105);const ids=[];
  for(let i=0;i<6;i++){ids.push(...page.visibleTasks().map(item=>item.task_id));page.moveQueryPage(1);}
  assert.equal(ids.length,105);assert.equal(new Set(ids).size,105);assert.equal(page.currentQueryPage(),5);assert.equal(page.visibleTasks().length,5);
  page.queryText='没有这个标题';assert.equal(page.currentQueryPage(),0);assert.deepEqual(page.visibleTasks(),[]);
});

test('search, status and date are intersected; clearing preserves selected date and unsent draft',async()=>{
  const {page}=await fixture();page.title='还没提交';page.draftTaskDate='2026-11-03';
  page.overview.tasks=[task('hit',{title:'练习题',location:'图书馆'}),task('done',{location:'图书馆',status:'completed'}),
    task('other-day',{location:'图书馆',start_at:'2026-10-22T10:00:00+08:00',end_at:null}),task('other-place',{location:'宿舍'})];
  page.queryText='图书';page.selectTaskFilter('pending');page.selectQueryDate('day');
  assert.deepEqual(page.filteredTasks().map(item=>item.task_id),['hit']);
  page.clearQuery();assert.equal(page.filteredTasks().length,4);assert.equal(page.selectedDate,'2026-10-20');
  assert.equal(page.title,'还没提交');assert.equal(page.draftTaskDate,'2026-11-03');
});

test('range validation never falls back to today; invalid dates remain available in unplaced view',async()=>{
  const {page}=await fixture();page.overview.tasks=[task('good'),task('bad',{start_at:'bad'}),task('no-date',{start_at:null,end_at:null})];
  page.selectQueryDate('range');page.queryFromDate='2026-02-30';page.queryToDate='2026-10-20';
  assert.equal(page.queryResult().valid,false);assert.equal(page.filteredTasks().length,0);
  page.selectQueryDate('undated');assert.deepEqual(page.filteredTasks().map(item=>item.task_id).sort(),['bad','no-date']);assert.equal(page.queryResult().invalidDateCount,1);
});

test('sort and exact task detail return preserve combined filters, page, and scroller',async()=>{
  const {page}=await fixture();page.overview.tasks=[task('old',{created_at:'2026-10-01T08:00:00+08:00'}),task('new',{created_at:'2026-10-02T08:00:00+08:00'})];
  page.currentView='tasks';page.querySort='created';page.queryText='复习';page.queryDateMode='day';page.tasksScroller.offset=440;
  assert.deepEqual(page.filteredTasks().map(item=>item.task_id),['new','old']);
  page.openDetails('task','new');assert.equal(page.focusedTasks()[0].task_id,'new');page.closeDetails();
  assert.equal(page.queryText,'复习');assert.equal(page.queryDateMode,'day');assert.equal(page.tasksScroller.offset,440);
});

test('week spans Monday through Sunday, keeps overlapping rows and separates all-day/undated',async()=>{
  const {page}=await fixture();page.selectedDate='2026-10-25';page.timetableRevision='a'.repeat(64);
  page.timetable=[course({date:'2026-10-19'}),course({date:'2026-10-25'})];
  page.overview.tasks=[task('overlap',{start_at:'2026-10-19T08:30:00+08:00',end_at:'2026-10-19T09:30:00+08:00'}),
    task('all',{start_at:'2026-10-25T23:59:00+08:00',end_at:null}),task('undated',{start_at:null,end_at:null})];
  const week=page.week();assert.equal(week.startDate,'2026-10-19');assert.equal(week.endDate,'2026-10-25');assert.equal(week.days.length,7);
  assert.equal(week.days[0].rows.length,2);assert.equal(week.days[6].allDay[0].task_id,'all');assert.equal(week.undated[0].task_id,'undated');
  assert.equal(page.timelineFor('2026-10-19').length,2);assert.equal(page.weekDays()[0].date,'2026-10-19');
});

test('week navigation and selected day assistant prompt never mutate the task draft or auto-send',async()=>{
  const {page,calls}=await fixture();page.draftTaskDate='2026-12-01';page.draftTaskTime='18:30';page.title='仍是这份草稿';
  page.scheduleMode='week';page.moveWeek(1);assert.equal(page.selectedDate,'2026-10-27');page.openWeekDay('2026-10-30');assert.equal(page.scheduleMode,'day');
  assert.match(page.reviewPrompt(),/2026-10-30/);assert.match(page.planPrompt(),/2026-10-26.*2026-11-01/);
  assert.deepEqual([page.draftTaskDate,page.draftTaskTime,page.title],['2026-12-01','18:30','仍是这份草稿']);assert.deepEqual(calls,[]);
});

test('course selection uses full fields, duplicate occurrence and revision; stale detail remains read only',async()=>{
  const {page,calls}=await fixture();page.timetableRevision='a'.repeat(64);page.timetableState='ready';
  page.timetable=[course(),course(),course({teacher:'乙',location:'另一栋楼'})];page.timetableEvidence=[{source_id:'fixture'}];
  const rows=page.dayTimeline();assert.equal(new Set(rows.map(item=>item.key)).size,3);
  const second=rows.find(item=>item.courseRef.occurrence===2);page.openTimeline(second);
  assert.equal(page.detailKind,'course');assert.equal(page.courseFor(page.detailId)[0].reference.occurrence,2);
  assert.equal(page.courseCurrent(second.courseRef),true);
  page.timetableRevision='b'.repeat(64);assert.equal(page.courseCurrent(second.courseRef),false);
  assert.equal(page.courseFor(page.detailId)[0].reference.course.teacher,'甲');assert.equal(page.courseFor(page.detailId)[0].evidence[0].source_id,'fixture');
  assert.deepEqual(calls,[]);page.closeDetails();assert.equal(page.detailKind,'');
});

test('task source succeeds independently when timetable fails; old timetable is not claimed current',async()=>{
  const {page}=await fixture({timetable:()=>Promise.reject(new Error('credential URL must not display')),planning:()=>({...empty(),tasks:[task('fresh')]})});
  page.timetable=[course()];page.timetableRevision='a'.repeat(64);await page.reload(true);
  assert.equal(page.planningState,'ready');assert.equal(page.overview.tasks[0].task_id,'fresh');assert.equal(page.timetableState,'error');
  assert.equal(page.timetable.length,1);assert.equal(page.sourcesComplete(),false);assert.match(page.sourceLabel(page.timetableState,'课表'),/失败/);
  assert.doesNotMatch(page.errorText,/credential/);
});

test('course source updates independently while failed planning retains old task data and explicit error',async()=>{
  const {page}=await fixture({planning:()=>Promise.reject(new Error('raw')),timetable:()=>timetableSnapshot([course({title:'新课'})])});
  page.overview.tasks=[task('old')];await page.reload(true);assert.equal(page.timetableState,'ready');assert.equal(page.timetable[0].title,'新课');
  assert.equal(page.planningState,'error');assert.equal(page.overview.tasks[0].task_id,'old');assert.equal(page.sourcesComplete(),false);assert.match(page.errorText,/读取失败/);
});

test('noncanonical or partial timetable response preserves prior snapshot and never asserts complete data',async()=>{
  for(const snapshot of [timetableSnapshot([course({start_time:' 08:00 '})]),{entries:[],revision:'short'},timetableSnapshot([{title:'missing fields'}])]) {
    const {page}=await fixture({timetable:()=>snapshot});page.timetable=[course()];page.timetableRevision='a'.repeat(64);await page.reload(true);
    assert.equal(page.timetableState,'error');assert.equal(page.timetable.length,1);assert.equal(page.sourcesComplete(),false);
  }
});

test('all three independent sources reject older generation and hidden responses',async()=>{
  const gates=[deferred(),deferred(),deferred()];let cycle=0;
  const {page}=await fixture({planning:()=>cycle===0?gates[0].promise:{...empty(),tasks:[task('new')]},
    timetable:()=>cycle===0?gates[1].promise:{...timetableSnapshot([course({title:'新课'})]),revision:'b'.repeat(64)},
    preferences:()=>cycle===0?gates[2].promise:preferenceSnapshot()});
  const old=page.reload(true);cycle=1;await page.reload(true);gates[0].resolve({...empty(),tasks:[task('stale')]});gates[1].resolve(timetableSnapshot([course()]));gates[2].resolve(preferenceSnapshot({enabled:true}));await old;
  assert.equal(page.overview.tasks[0].task_id,'new');assert.equal(page.timetableRevision,'b'.repeat(64));assert.equal(page.preferences.enabled,false);
  const late=deferred();const hidden=await fixture({timetable:()=>late.promise});const read=hidden.page.reload(true);hidden.page.active=false;hidden.page.activityChanged();late.resolve(timetableSnapshot([course()]));await read;
  assert.deepEqual(hidden.page.timetable,[]);assert.notEqual(hidden.page.timetableState,'ready');
});

test('connection change drops account query/data/controller and late old service reads cannot restore them',async()=>{
  const gate=deferred();const {page}=await fixture({timetable:api=>api.base.includes('one')?gate.promise:timetableSnapshot([])});
  page.queryText='私有标题';page.queryFromDate='2026-01-01';page.queryPage=4;page.overview.tasks=[task('private')];let disposed=0;page.actionController={dispose(){disposed++;}};
  const old=page.reload(true);page.baseUrl='https://two.invalid';page.token='second';page.connectionChanged();
  assert.equal(page.queryText,'');assert.equal(page.queryFromDate,'');assert.equal(page.queryPage,0);assert.deepEqual(page.overview.tasks,[]);assert.equal(disposed,1);
  gate.resolve(timetableSnapshot([course({title:'旧账号课表'})]));await old;await new Promise(resolve=>setImmediate(resolve));assert.deepEqual(page.timetable,[]);
});

test('lease generation change clears filters and old course detail while keeping new scope isolated',async()=>{
  const {page,drafts}=await fixture();page.queryText='旧标题';page.querySort='created';page.scheduleMode='week';page.openDetails('task','old');
  page.draftLease=await drafts.store.activate('new-scope');page.draftScopeChanged();
  assert.equal(page.queryText,'');assert.equal(page.querySort,'schedule');assert.equal(page.scheduleMode,'day');assert.deepEqual(page.detailStack,[]);
});

test('candidate before/after load replaces exact task once without mutating live overview',async()=>{
  const {page}=await fixture();page.overview.tasks=[task('edit'),task('same-title',{start_at:'2026-10-20T12:00:00+08:00',end_at:'2026-10-20T13:00:00+08:00'})];
  const draft={title:'复习操作系统',start_at:'2026-10-20T10:00:00+08:00',end_at:'2026-10-20T12:00:00+08:00',reminder_minutes:null,location:''};
  page.actionState={phase:'review',message:'',action:candidate({operation:'update_task',task_id:'edit',task:draft})};
  assert.equal(page.dayLoad('2026-10-20').taskMinutes,120);assert.equal(page.candidateLoad().taskMinutes,180);
  assert.equal(page.projectedTasks().length,2);assert.equal(page.overview.tasks[0].end_at,'2026-10-20T11:00:00+08:00');
  page.actionState.action.target_task_id='removed';assert.equal(page.projectedTasks(),null);
});

test('manual 23:59 create stays all-day; exact edit retains original source and task ID',async()=>{
  const {page}=await fixture();const draft={title:'全天事项',start_at:'2026-10-20T23:59:00+08:00',end_at:null,reminder_minutes:null,location:''};
  page.actionState={phase:'review',message:'',action:candidate({operation:'create_task',task:draft})};page.actionState.action.payload.source='manual';
  assert.equal(page.candidateLoad().allDayCount,1);assert.equal(page.candidateLoad().incompleteTaskCount,0);assert.equal(page.candidateLoad().taskMinutes,0);
  page.overview.tasks=[task('exact',{source:'manual'})];page.actionState.action=candidate({operation:'update_task',task_id:'exact',task:draft});page.actionState.action.payload.source='agent';
  assert.equal(page.projectedTasks()[0].source,'manual');assert.equal(page.projectedTasks()[0].task_id,'exact');assert.equal(page.candidateLoad().allDayCount,1);
});

test('only saved enabled preference compares task minutes, never course occupancy or a default target',async()=>{
  const {page}=await fixture();page.timetableState='ready';page.planningState='ready';page.preferencesState='ready';page.timetable=[course({start_time:'08:00',end_time:'12:00'})];page.overview.tasks=[task('one')];
  const load=page.dayLoad('2026-10-20');assert.equal(load.courseMinutes,240);assert.equal(load.taskMinutes,60);
  page.preferences=preferenceSnapshot({enabled:true,daily_minutes:30});assert.equal(page.loadTargetMessage(load),'');
  page.preferences=preferenceSnapshot({enabled:true,daily_minutes:120,revision:1,updated_at:'2026-10-18T09:00:00+08:00'});
  assert.doesNotMatch(page.loadTargetMessage(load),/高于/);page.preferences.daily_minutes=30;assert.match(page.loadTargetMessage(load),/高于/);
  page.preferences.enabled=false;assert.equal(page.loadTargetMessage(load),'');page.preferences.enabled=true;page.timetableState='error';assert.equal(page.loadTargetMessage(load),'');
});

test('incomplete/all-day/undated times are disclosed rather than assigned a fake duration',async()=>{
  const {page}=await fixture();page.overview.tasks=[task('no-end',{end_at:null}),task('all',{start_at:'2026-10-20T23:59:00+08:00',end_at:null}),task('undated',{start_at:null,end_at:null})];
  const load=page.dayLoad('2026-10-20');assert.equal(load.taskMinutes,0);assert.equal(load.incompleteTaskCount,1);assert.equal(load.allDayCount,1);assert.equal(load.undatedCount,1);
  assert.match(page.loadExclusions(load),/1 项全天、1 项无日期、1 项缺结束时间/);
});

// Actual production methods plus real pure helpers and mocked I/O; not native Builder, font or device verification.

test('overnight week rows show only their daily segment and retain full original range',async()=>{
  const {page}=await fixture();page.selectedDate='2026-10-20';page.overview.tasks=[task('overnight',{start_at:'2026-10-19T23:30:00+08:00',end_at:'2026-10-21T01:00:00+08:00'})];
  assert.equal(page.timelineFor('2026-10-19')[0].time,'23:30–24:00');assert.equal(page.timelineFor('2026-10-20')[0].time,'00:00–24:00');
  assert.equal(page.timelineFor('2026-10-21')[0].time,'00:00–01:00');assert.match(page.timelineFor('2026-10-20')[0].detail,/2026-10-19 23:30 至 2026-10-21 01:00/);
  assert.equal(page.timelineFor('2026-10-20')[0].taskId,'overnight');
});


test('day unplaced shortcut selects a real pending/date combination; status changes keep date condition',async()=>{
  const {page}=await fixture();page.queryText='旧搜索';page.openUndated();
  assert.equal(page.taskFilter,'pending');assert.equal(page.query().dateMode,'undated');assert.equal(page.queryText,'');
  page.selectTaskFilter('completed');assert.equal(page.query().status,'completed');assert.equal(page.query().dateMode,'undated');
});
