import assert from 'node:assert/strict';
import { test } from 'node:test';
import { entryEditor, importPanel, diagnosticPreview, sourceRow, importReview } from './helpers/timetable-editor-fixture.mjs';
const course = (extra = {}) => ({date:'2026-10-19',title:'操作系统',start_time:'08:05',end_time:'09:40',location:'一教101',teacher:'叶老师',...extra});
const bad = (index, extra = {}) => sourceRow(index, course({end_time:'07:00'}), { status:'invalid',entry:null,
 issues:[{field:'end_time',code:'END_INVALID',severity:'error',message:'结束时间早于开始，请修正。'}],...extra });
const choice = (sourceIndex, extra = {}) => ({sourceIndex,mode:'default',edited:null,sourceIssuesReviewed:false,overlapKey:'',...extra});

test('date picker preserves numeric month zero and leap days, rejects incomplete or impossible callbacks', () => {
 const f=entryEditor(course());f.editor.openDatePicker();f.dateDialogs[0].onAccept({year:2028,month:0,day:3});assert.equal(f.editor.entry.date,'2028-01-03');
 f.editor.openDatePicker();f.dateDialogs[1].onAccept({year:2028,month:1,day:29});assert.equal(f.editor.entry.date,'2028-02-29');
 for(const result of [{year:2027,month:1,day:29},{year:2028,month:12,day:1},{year:2028,day:1}]) {f.editor.openDatePicker();f.dateDialogs.at(-1).onAccept(result);assert.equal(f.editor.entry.date,'2028-02-29');}
 assert.equal(f.changes.length,2);
});
test('manual 0001–9999 dates remain editable without clamping to native picker range', () => {
 for(const date of ['0001-01-01','1899-12-31','9999-12-31']) {const f=entryEditor(course({date}));f.editor.openDatePicker();assert.equal(f.dateDialogs.length,0);assert.equal(f.editor.entry.date,date);assert.match(f.editor.notice,/手动/);}
 const f=entryEditor(course({date:'not-a-date'}));f.editor.openDatePicker();assert.equal(f.dateDialogs[0].selected.getFullYear(),2026);assert.equal(f.editor.entry.date,'not-a-date');
});
test('time picker preserves 00:00, refuses incomplete and out-of-range values, never infers duration', () => {
 const f=entryEditor(course());f.editor.openTimePicker('start_time');f.timeDialogs[0].onAccept({hour:0,minute:0});assert.equal(f.editor.entry.start_time,'00:00');assert.equal(f.editor.entry.end_time,'09:40');
 for(const result of [{hour:24,minute:0},{hour:1,minute:60},{hour:1}]) {f.editor.openTimePicker('end_time');f.timeDialogs.at(-1).onAccept(result);assert.equal(f.editor.entry.end_time,'09:40');}
});
test('cancel, hidden state, new target, raw edits and disposal invalidate late picker results', () => {
 for(const invalidate of [f=>f.dateDialogs[0].onCancel(), f=>{f.editor.active=false;f.editor.contextChanged();}, f=>{f.editor.contextKey='other';f.editor.contextChanged();}, f=>f.editor.changed('title','新草稿'), f=>f.editor.aboutToDisappear()]) {
 const f=entryEditor(course());f.editor.openDatePicker();invalidate(f);f.dateDialogs[0].onAccept({year:2027,month:0,day:1});assert.equal(f.editor.entry.date,'2026-10-19');}
 const f=entryEditor(course());f.editor.openTimePicker('start_time');f.editor.openTimePicker('end_time');f.timeDialogs[0].onAccept({hour:5,minute:0});assert.equal(f.editor.entry.start_time,'08:05');f.timeDialogs[1].onAccept({hour:10,minute:0});assert.equal(f.editor.entry.end_time,'10:00');
});
test('native picker failure leaves raw data intact with manual fallback', () => {
 const f=entryEditor(course(),{pickerFailure:true});f.editor.openDatePicker();f.editor.openTimePicker('end_time');assert.deepEqual(f.editor.entry,course());assert.deepEqual(f.changes,[]);assert.match(f.editor.notice,/直接输入/);
});
test('first error order, optional expansion and focus failure are explicit; each request focuses once', () => {
 const f=entryEditor(course(),{focusSuccess:false});f.editor.errors={title:'必填',date:'坏日期',start_time:'',end_time:'',location:'地点过长',teacher:''};
 f.editor.focusRequested();f.editor.locateError();f.editor.locateError();assert.deepEqual(f.focusCalls,['fixture-title']);assert.equal(f.editor.optionalExpanded,true);assert.match(f.editor.notice,/点选/);
 f.editor.errors.title='';f.editor.focusRequested();f.editor.locateError();assert.equal(f.focusCalls[1],'fixture-date');f.editor.active=false;f.editor.focusRequested();f.editor.locateError();assert.equal(f.focusCalls.length,2);
});
test('500 source rows are reachable across six-row pages with exact global row identity', () => {
 const rows=Array.from({length:500},(_,index)=>sourceRow(index,course({title:`课 ${index}`,date:`${2000+index}-01-01`})));const p=importPanel(rows);const seen=[];
 for(let page=0;page<84;page++){p.pageIndex=page;seen.push(...p.pageRows().map(row=>row.sourceIndex));}assert.deepEqual(seen,Array.from({length:500},(_,i)=>i));
 p.editRow(499);p.updateEditor('title','只修改最后一行');p.saveEdit();assert.equal(p.choices[0].sourceIndex,499);assert.equal(p.classification().rows[499].input.title,'只修改最后一行');assert.equal(p.classification().rows[0].input.title,'课 0');
});
test('editing invalid or unsupported row still needs source review, with explicit exclusion for unresolved rows', () => {
 const rows=[sourceRow(0,course()),bad(1,{input:course({date:'2026-10-20',end_time:'07:00'})}),bad(2,{status:'unsupported',input:course({date:'2026-10-21'}),issues:[{field:'event',code:'RRULE',severity:'error',message:'系列未展开'}]})];
 const p=importPanel(rows);p.editRow(1);p.updateEditor('end_time','10:00');p.saveEdit();assert.equal(p.classification().unresolvedCount,2);p.reviewSource(1);assert.equal(p.classification().unresolvedCount,1);
 assert.equal(importReview.assembleSelectedImport(rows,[],p.choices).valid,false);p.decide(2,false);const out=importReview.assembleSelectedImport(rows,[],p.choices);assert.equal(out.valid,true);assert.equal(out.addedEntries.length,2);assert.equal(out.excludedCount,1);
 p.decide(2,true);assert.equal(p.classification().unresolvedCount,1,'reincluding unsupported source cannot auto-ack');
});
test('overlap acknowledgement binds six fields and reclassification revokes it after draft changes', () => {
 const p=importPanel([sourceRow(0,course({teacher:'另一位教师'}))],[course()]);assert.equal(p.classification().overlapCount,1);assert.equal(p.classification().addCount,0);p.decide(0,true);assert.equal(p.classification().addCount,1);
 p.currentDraft=[course({location:'新教室'})];p.reclassify();assert.equal(p.classification().addCount,0);assert.equal(p.classification().unresolvedCount,1);p.decide(0,true);assert.equal(p.classification().addCount,1);
 p.editRow(0);p.updateEditor('title','改名');p.saveEdit();assert.equal(p.classification().addCount,0,'edited row must explicitly re-acknowledge');
});
test('exclude then reinclude never reuses overlap confirmation; wholly excluded review cannot clear draft', () => {
 const rows=[sourceRow(0,course({teacher:'另一位'}))],draft=[course()],p=importPanel(rows,draft);p.decide(0,true);p.decide(0,false);p.decide(0,true);assert.equal(p.classification().addCount,0);assert.equal(p.classification().unresolvedCount,1);
 p.decide(0,false);assert.equal(importReview.assembleSelectedImport(rows,draft,p.choices).valid,false);assert.deepEqual(p.currentDraft,draft);
});
test('in-progress row edit blocks filter/accept and leaves old row until explicit save; hidden blocks mutation', () => {
 const p=importPanel([sourceRow(0,course())]);let accepts=0;p.onAccept=()=>accepts++;p.editRow(0);p.updateEditor('title','尚未应用');p.selectCategory('invalid');p.accept();assert.equal(p.category,'all');assert.equal(accepts,0);assert.equal(p.choices.length,0);
 p.active=false;p.saveEdit();p.decide(0,false);assert.equal(p.choices.length,0);p.active=true;p.saveEdit();assert.equal(p.choices[0].edited.title,'尚未应用');p.accept();assert.equal(accepts,1);
});
test('scope change clears row editor and selection view; callbacks cannot apply nonexistent source index', () => {
 const p=importPanel([sourceRow(0,course())]);p.editRow(0);p.updateEditor('title','旧账号');p.rows=[];p.choices=[];p.contextKey='new-account';p.contextChanged();assert.equal(p.editingSource,-1);p.saveEdit();p.decide(0,true);assert.equal(p.choices.length,0);assert.equal(p.classification().valid,false);
});
