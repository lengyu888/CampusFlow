import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { test } from 'node:test';
import { time, summary, ReviewController, emptyReviewState, reviewNoteKey, DraftStore, DraftMemoryDriver, populatedReview, reviewSnapshot, reviewTask, deferred, tick } from './helpers/review-fixture.mjs';
const read=name=>readFileSync(new URL(`../entry/src/main/ets/${name}.ets`,import.meta.url),'utf8');
const history=await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(read('utils/LocalHistoryStore').replace(/^import [^\n]+;\r?\n/gm,''))).toString('base64')}`);
const presentation=await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(read('utils/PlanPresentation'))).toString('base64')}`);
const source=read('pages/ReviewPage');
const methods=source.slice(0,source.indexOf('\n  @Builder')).replace(/^import [^\n]+;\r?\n/gm,'').replace(/^@Component\r?\n/gm,'').replace(/@(State|Prop)\s+|@Watch\('[^']+'\)\s*/g,'').replace('export struct ReviewPage','class ReviewPage')+'\n}';
async function fixture(options={}){
 const driver=options.driver??new DraftMemoryDriver();const store=new DraftStore(driver,{now:()=>Date.now(),set:()=>1,clear(){}});await store.initialize();const scope=history.historyScope('https://example.test','account-a');const lease=await store.activate(scope);const calls=[],navigation=[];
 class Api{constructor(base,token){this.base=base;this.token=token;}async review(period,anchor){calls.push([this.base,this.token,period,anchor]);return options.review?options.review(period,anchor,this.token):period==='day'&&anchor==='2030-10-19'?populatedReview():reviewSnapshot(period,anchor);}}
 const deps={...time,...summary,...presentation,ReviewController,emptyReviewState,reviewNoteKey,localDrafts:store,historyScope:history.historyScope,CampusFlowApi:Api};
 const Page=new Function(...Object.keys(deps),stripTypeScriptTypes(methods)+'\nreturn ReviewPage')(...Object.values(deps));const page=new Page();Object.assign(page,{baseUrl:'https://example.test',token:'token-a',userId:'account-a',draftLease:lease,accountRevision:7,active:true,initialPeriod:'day',initialAnchor:'2030-10-19'});
 page.onBack=(...args)=>navigation.push(['back',...args]);page.onOpenTask=(...args)=>navigation.push(['task',...args]);page.onOpenFocus=(...args)=>navigation.push(['focus',...args]);page.onOfferSummary=(...args)=>navigation.push(['summary',...args]);
 page.aboutToAppear();await tick();return {page,store,driver,lease,calls,navigation};
}

test('initial props coalesce into one real readonly request; three facts and default note exclusion',async()=>{
 const f=await fixture();assert.equal(f.calls.length,1);assert.deepEqual(f.calls[0].slice(2),['day','2030-10-19']);assert.equal(f.page.state.phase,'ready');assert.equal(f.page.includeNote,false);assert.equal(f.page.savedNotes.length,0);assert.equal(f.page.duration(1500000),'25 分 0 秒');assert.equal(f.page.duration(1),'不足 1 秒');f.page.aboutToDisappear();
});
test('fast date reads are latest-wins and stale errors retain labeled prior snapshot',async()=>{
 const slow=deferred();let fail=false;const f=await fixture({review:async(period,anchor)=>{if(anchor==='2030-10-20')return slow.promise;if(fail)throw Error('private response');return reviewSnapshot(period,anchor);}});
 await f.page.selectPeriod('day','2030-10-20');await f.page.selectPeriod('day','2030-10-21');await tick();slow.resolve(reviewSnapshot('day','2030-10-20'));await tick();assert.equal(f.page.state.anchor,'2030-10-21');assert.equal(f.page.state.snapshot.anchor,'2030-10-21');fail=true;await f.page.controller.refresh();assert.equal(f.page.state.phase,'stale');assert.equal(f.page.state.snapshot.anchor,'2030-10-21');assert.doesNotMatch(f.page.state.message,/private/);f.page.aboutToDisappear();
});
test('saving optional note preserves exact spaces and only then allows date change',async()=>{
 const f=await fixture();f.page.noteChanged('  自己的一句话 🌱  ');await f.page.selectPeriod('week','2030-10-21');await tick();const note=f.store.read(f.lease,reviewNoteKey('day','2030-10-19'));assert.equal(note.payload.text,'  自己的一句话 🌱  ');assert.equal(f.page.state.period,'week');assert.equal(f.page.noteKey.ownerId,'week:2030-10-21');assert.equal(f.page.noteText,'');const reopened=new DraftStore(f.driver);await reopened.initialize();const lease=await reopened.activate(f.lease.scope);assert.equal(reopened.read(lease,note).payload.text,note.payload.text);f.page.aboutToDisappear();
});
test('note write failure blocks system back, date, task/focus navigation and keeps all input',async()=>{
 const f=await fixture();f.driver.failWrite=true;f.page.noteChanged('不得丢失');for(const kind of ['back','task','focus'])await f.page.navigate(kind,'task-a');await f.page.selectPeriod('day','2030-10-20');assert.equal(f.page.state.anchor,'2030-10-19');assert.equal(f.page.noteText,'不得丢失');assert.equal(f.page.noteDirty,true);assert.deepEqual(f.navigation,[]);assert.match(f.page.noteMessage,/尚未保存/);f.driver.failWrite=false;await f.page.navigate('back');assert.deepEqual(f.navigation,[['back',7]]);f.page.aboutToDisappear();
});
test('new input while disk writes remains dirty and cannot silently navigate',async()=>{
 const f=await fixture(),delay=deferred();f.driver.beforeWrite=()=>delay.promise;f.page.noteChanged('先写的一句');const back=f.page.navigate('back');await tick();f.page.noteChanged('写入时补充的新句');delay.resolve();await back;assert.equal(f.page.savedText,'先写的一句');assert.equal(f.page.noteText,'写入时补充的新句');assert.equal(f.page.noteDirty,true);assert.deepEqual(f.navigation,[]);f.driver.beforeWrite=null;assert.equal(await f.page.saveNote(),true);f.page.aboutToDisappear();
});
test('changed account or service while saving cannot emit navigation or overwrite replacement UI',async()=>{
 for(const change of ['account','service']){const f=await fixture(),delay=deferred();f.driver.beforeWrite=()=>delay.promise;f.page.noteChanged('A的私密感受');const back=f.page.navigate('back');await tick();if(change==='account'){f.page.accountRevision++;f.page.userId='account-b';f.page.token='token-b';}else{f.page.baseUrl='https://other.test';}f.page.connectionChanged();await tick();delay.resolve();await back;assert.deepEqual(f.navigation,[]);assert.equal(f.page.noteText,'');assert.equal(f.page.noteBusy,false);f.page.aboutToDisappear();}
});
test('hidden page preserves dirty input if background flush fails; late read does not display',async()=>{
 const delay=deferred();const f=await fixture({review:()=>delay.promise});f.page.noteChanged('保留到回来');f.driver.failWrite=true;f.page.active=false;f.page.activeChanged();await tick();delay.resolve(populatedReview());await tick();assert.equal(f.page.state.snapshot,null);assert.equal(f.page.noteText,'保留到回来');assert.equal(f.page.noteDirty,true);f.page.active=true;f.page.activeChanged();await tick();assert.equal(f.page.noteText,'保留到回来');f.page.aboutToDisappear();
});
test('a changed local revision never silently overwrites another saved version',async()=>{
 const f=await fixture();f.page.noteChanged('本页新输入');f.store.stage(f.lease,reviewNoteKey('day','2030-10-19'),{period:'day',anchor:'2030-10-19',timezone:'Asia/Shanghai',text:'另一个已保存版本'});await f.store.flush(f.lease);assert.equal(await f.page.saveNote(),false);assert.match(f.page.noteMessage,/另一版本/);assert.equal(f.page.noteText,'本页新输入');assert.equal(f.store.read(f.lease,f.page.noteKey).payload.text,'另一个已保存版本');f.page.aboutToDisappear();
});
test('deleting exact saved revision preserves unsaved text; stale delete does not remove newer data',async()=>{
 const f=await fixture();f.page.noteChanged('旧句');await f.page.saveNote();const record=f.page.savedNotes[0];f.page.askDeleteNote(record);f.store.stage(f.lease,f.page.noteKey,{...record.payload,text:'后来的保存'});await f.store.flush(f.lease);await f.page.deleteSavedNote();assert.match(f.page.noteMessage,/发生变化/);const newer=f.store.read(f.lease,f.page.noteKey);f.page.noteChanged('不删除这份新输入');f.page.askDeleteNote(newer);await f.page.deleteSavedNote();assert.equal(f.store.read(f.lease,f.page.noteKey),undefined);assert.equal(f.page.noteText,'不删除这份新输入');assert.equal(f.page.noteRevision,0);assert.equal(f.page.noteDirty,true);assert.equal(await f.page.saveNote(),true);f.page.aboutToDisappear();
});
test('note longer than 500 codepoints is preserved and rejected without truncation',async()=>{
 const f=await fixture();f.page.noteChanged('🌱'.repeat(501));assert.equal(await f.page.saveNote(),false);assert.equal(Array.from(f.page.noteText).length,501);assert.equal(f.store.list(f.lease,'review-note').length,0);assert.match(f.page.noteMessage,/500/);f.page.noteChanged('🌱'.repeat(500));assert.equal(await f.page.saveNote(),true);f.page.aboutToDisappear();
});
test('summary preview excludes private text by default and never sends until explicit handoff',async()=>{
 const f=await fixture();f.page.noteChanged('独有私密句子');f.page.previewSummary();assert.doesNotMatch(f.page.summaryText,/独有私密/);assert.deepEqual(f.navigation,[]);f.page.factChanged('note',true);assert.equal(f.page.summaryText,'');f.page.previewSummary();assert.match(f.page.summaryText,/独有私密/);await f.page.navigate('summary');assert.equal(f.navigation[0][0],'summary');assert.equal(f.navigation[0][2],7);assert.equal(f.calls.length,1);f.page.noteChanged('修改后');assert.equal(f.page.summaryText,'');f.page.aboutToDisappear();
});
test('empty selection does not hand off; period/identity refresh invalidates previous preview',async()=>{
 const f=await fixture();for(const name of ['completed','unscheduled','focus'])f.page.factChanged(name,false);f.page.previewSummary();assert.equal(f.page.summaryText,'');await f.page.navigate('summary');assert.deepEqual(f.navigation,[]);f.page.factChanged('completed',true);f.page.previewSummary();assert.ok(f.page.summaryText);await f.page.selectPeriod('day','2030-10-20');assert.equal(f.page.summaryText,'');f.page.aboutToDisappear();
});
test('all source rows remain reachable through pagination, including zero allocation and un-attributed items',async()=>{
 const f=await fixture();f.page.state.snapshot.completed_tasks=Array.from({length:25},(_,i)=>reviewTask({task_id:`task-${i}`}));f.page.toggleSource('completed');const seen=[];for(let page=0;page<4;page++){f.page.sourcePage=page;seen.push(...f.page.visibleTasks());}assert.equal(new Set(seen.map(t=>t.task_id)).size,25);f.page.toggleSource('focus');f.page.state.snapshot.focus_intervals[0].allocated_elapsed_ms=0;assert.equal(f.page.visibleIntervals().length,1);assert.equal(f.page.visibleIntervals()[0].allocated_elapsed_ms,0);f.page.toggleSource('unattributed');assert.equal(f.page.visibleTasks().length,1);assert.match(f.page.evidenceLabel(f.page.visibleTasks()[0]),/未计入/);f.page.toggleSource('gaps');assert.equal(f.page.visibleGaps().length,1);f.page.aboutToDisappear();
});
test('date invalid or next range overflowing cannot erase note or issue read; week saved notes open canonical date',async()=>{
 const f=await fixture();const count=f.calls.length;f.page.noteChanged('还没保存');for(const day of ['2030-02-30','9999-12-31','not-a-date'])await f.page.selectPeriod('day',day);assert.equal(f.calls.length,count);assert.equal(f.page.noteText,'还没保存');assert.equal(f.store.list(f.lease,'review-note').length,0);await f.page.selectPeriod('week','2030-10-24');await tick();f.page.noteChanged('这一周');await f.page.saveNote();const rec=f.page.savedNotes.find(r=>r.payload.period==='week');assert.equal(rec.payload.anchor,'2030-10-21');await f.page.openSaved(rec);await tick();assert.equal(f.page.state.anchor,'2030-10-21');assert.equal(f.page.noteText,'这一周');f.page.aboutToDisappear();
});

test('explicit re-entry selects the requested day again; foreground return refreshes own date without losing editor',async()=>{
 const f=await fixture();await f.page.selectPeriod('day','2030-10-18');await tick();f.page.noteChanged('昨天的感受');f.page.active=false;f.page.activeChanged();await tick();f.page.active=true;f.page.activeChanged();await tick();assert.equal(f.page.state.anchor,'2030-10-18');assert.equal(f.page.noteText,'昨天的感受');assert.deepEqual(f.calls.at(-1).slice(2),['day','2030-10-18']);
 f.page.active=false;f.page.activeChanged();f.page.entryRevision++;f.page.initialChanged();f.page.active=true;f.page.activeChanged();await tick();assert.equal(f.page.state.anchor,'2030-10-19');assert.equal(f.page.noteText,'');assert.deepEqual(f.calls.at(-1).slice(2),['day','2030-10-19']);f.page.aboutToDisappear();
});

test('new explicit entry received during an older note flush wins after durable protection',async()=>{
 const f=await fixture(),delay=deferred();f.page.noteChanged('最初日期的感受');f.driver.beforeWrite=()=>delay.promise;const older=f.page.selectPeriod('day','2030-10-20');await tick();f.page.initialPeriod='week';f.page.initialAnchor='2030-10-23';f.page.entryRevision++;f.page.initialChanged();await tick();assert.equal(f.page.noteBusy,true);delay.resolve();await older;await tick();assert.equal(f.page.state.period,'week');assert.equal(f.page.state.anchor,'2030-10-23');assert.equal(f.store.read(f.lease,reviewNoteKey('day','2030-10-19')).payload.text,'最初日期的感受');assert.equal(f.page.noteText,'');f.page.aboutToDisappear();
});

test('all 20 slots occupied by other drafts has explicit current-version discard exit and deletes none',async()=>{
 const f=await fixture();for(let i=0;i<20;i++)f.store.stage(f.lease,{kind:'assistant',ownerId:`session:s-${i}`},{text:`other-${i}`,sessionId:`s-${i}`,anchorDate:'2030-10-19',timezone:'Asia/Shanghai'});await f.store.flush(f.lease);const original=f.store.list(f.lease,'assistant');f.page.noteChanged('容量不足的这句');assert.equal(await f.page.saveNote(),false);assert.equal(f.page.savedNotes.length,0);await f.page.navigate('back');assert.deepEqual(f.navigation,[]);f.page.discardNoteText=f.page.noteText;f.page.noteChanged('刚刚又写了新句');await f.page.discardUnsaved();assert.equal(f.page.noteText,'刚刚又写了新句');assert.equal(f.page.noteDirty,true);f.page.discardNoteText=f.page.noteText;await f.page.discardUnsaved();assert.equal(f.page.noteText,'');assert.equal(f.page.noteDirty,false);assert.deepEqual(f.store.list(f.lease,'assistant'),original);await f.page.navigate('back');assert.deepEqual(f.navigation,[['back',7]]);f.page.aboutToDisappear();
});
test('discard of staged failed write must durably restore prior text before navigation',async()=>{
 const f=await fixture();f.page.noteChanged('原已保存');await f.page.saveNote();f.driver.failWrite=true;f.page.noteChanged('后来失败的版本');assert.equal(await f.page.saveNote(),false);f.page.discardNoteText=f.page.noteText;await f.page.discardUnsaved();assert.equal(f.page.noteText,'后来失败的版本');assert.equal(f.page.noteDirty,true);f.driver.failWrite=false;await f.page.discardUnsaved();assert.equal(f.page.noteText,'原已保存');assert.equal(f.page.noteDirty,false);assert.equal(f.store.read(f.lease,f.page.noteKey).payload.text,'原已保存');f.page.aboutToDisappear();
});

test('old back/task/summary callback cannot close a new explicit entry during note flush',async()=>{
 for(const kind of ['back','task','focus','summary']){const f=await fixture(),delay=deferred();f.page.noteChanged('旧页需要保护');f.page.previewSummary();f.driver.beforeWrite=()=>delay.promise;const leaving=f.page.navigate(kind,'task-a');await tick();f.page.initialPeriod='week';f.page.initialAnchor='2030-10-23';f.page.entryRevision++;f.page.initialChanged();await tick();delay.resolve();await leaving;await tick();assert.deepEqual(f.navigation,[]);assert.equal(f.page.state.period,'week');assert.equal(f.page.state.anchor,'2030-10-23');f.page.aboutToDisappear();}
});

test('main reading time is natural fixed campus time and exact ISO/digest remain opt-in evidence',async()=>{
 const f=await fixture();f.page.state.snapshot.as_of='2030-10-19T23:05:12.123456Z';assert.equal(f.page.readingTime(),'2030年10月20日 07:05（校园时间）');assert.equal(f.page.expandedEvidence.includes('snapshot'),false);f.page.toggleEvidence('snapshot');assert.equal(f.page.expandedEvidence.includes('snapshot'),true);assert.equal(f.page.state.snapshot.as_of,'2030-10-19T23:05:12.123456Z');assert.equal(f.page.state.snapshot.snapshot_digest,'a'.repeat(64));f.page.aboutToDisappear();
});
