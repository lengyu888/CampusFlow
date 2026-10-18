import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';

import { importReview } from './helpers/timetable-import-fixture.mjs';
import { maximumWarningPreview } from './helpers/timetable-editor-fixture.mjs';
const { parseImportReview, classifyImportRows, assembleSelectedImport } = importReview;
const course = (change={}) => ({ date:'2026-10-19', title:'操作系统', start_time:'08:00', end_time:'09:00', location:'一教 101', teacher:'陈老师', ...change });
const sourceTime = () => ({ start_value:'20261019T080000',end_value:'20261019T090000',start_tzid:'Asia/Shanghai',end_tzid:'Asia/Shanghai',start_value_type:null,end_value_type:null });
const row = (index=0,change={},entry=course()) => ({ source_index:index,status:'ready',input:structuredClone(entry),entry:structuredClone(entry),source_time:sourceTime(),issues:[],...change });
const issue = (change={}) => ({ field:'end_time',code:'END_NOT_AFTER_START',severity:'error',message:'结束时间必须晚于开始时间，请核对这条课程。',...change });
const badRow = (index=0,change={}) => row(index,{ status:'invalid',input:course({end_time:'07:00'}),entry:null,issues:[issue()],...change });
const unsupported = (index=0,change={}) => badRow(index,{status:'unsupported',input:course(),issues:[issue({field:'event',code:'RECURRENCE_UNSUPPORTED',message:'重复系列尚未展开，请核对单次课程。'})],...change});
const preview = (rows,change={}) => { const ready=rows.every(r=>r.status==='ready'); const entries=ready?[...new Map(rows.map(r=>[JSON.stringify(r.entry),r.entry])).values()]:[];return {provider:'hduhelp',calendar_name:'合成课表',event_count:entries.length,entries,warnings:[],diagnostics_version:1,source_event_count:rows.length,timezone_policy:'campus-utc+08:00',rows,...change}; };
const parse = (rows,change={}) => parseImportReview(JSON.stringify(preview(rows,change)));
const choice = (sourceIndex,change={}) => ({sourceIndex,mode:'default',edited:null,sourceIssuesReviewed:false,overlapKey:'',...change});
const identity = entry => JSON.stringify([entry.date,entry.title,entry.start_time,entry.end_time,entry.location,entry.teacher]);
// Actual production helper and form rules, not native UI or network calendar tests.

test('mixed ready/invalid/unsupported source rows remain complete although the legacy list is empty', () => {
  const rows=[row(0),badRow(1),unsupported(2)],payload=preview(rows);assert.equal(payload.entries.length,0);
  const result=parseImportReview(JSON.stringify(payload));assert.equal(result.valid,true);assert.equal(result.sourceCount,3);
  assert.deepEqual(result.rows.map(r=>r.source_index),[0,1,2]);assert.deepEqual(result.rows.map(r=>r.status),['ready','invalid','unsupported']);assert.equal(classifyImportRows(result.rows,[]).unresolvedCount,2);
});
test('unknown diagnostics, count/index mismatch and 501 events reject the entire preview', () => {
  for(const change of [{diagnostics_version:undefined},{diagnostics_version:2},{timezone_policy:'device-local'},{source_event_count:0},{source_event_count:2},{source_event_count:1.5},{rows:[row(1)]},{rows:[row(0),row(0)],source_event_count:2},{rows:Array.from({length:501},(_,i)=>row(i)),source_event_count:501},{provider:'untrusted'}]) {
    const result=parse([row()],change);assert.equal(result.valid,false,JSON.stringify(change).slice(0,100));assert.deepEqual(result.rows,[]);
  }
  for(const json of ['', '{', 'null','[]','"text"']) assert.equal(parseImportReview(json).valid,false);
});
test('missing or null ready entry and nonnumeric source counts fail closed without losing source rows', () => {
  for(const entry of [null,undefined]) {
    const input=preview([row(0,{entry})]);
    const result=parseImportReview(JSON.stringify(input));
    assert.equal(result.valid,false); assert.deepEqual(result.rows,[]); assert.equal(input.rows.length,1);
  }
  for(const sourceCount of [undefined,null,'1',true,-1,0,1.5,NaN,Infinity,501]) {
    const result=parse([row()],{source_event_count:sourceCount});
    assert.equal(result.valid,false,`invalid source count ${String(sourceCount)}`); assert.deepEqual(result.rows,[]);
  }
  const valid=parse([row()]);
  assert.equal(valid.valid,true); assert.equal(valid.sourceCount,1); assert.deepEqual(valid.rows.map(item=>item.source_index),[0]);
});
test('ready entries require exact normalized fields and no errors; bad rows require null entry with an error', () => {
  for(const r of [row(0,{entry:course({teacher:'另一个老师'})}),row(0,{input:course({title:'😀'.repeat(101)})}),row(0,{issues:[issue()]}),badRow(0,{entry:course()}),badRow(0,{issues:[]}),unsupported(0,{issues:[issue({severity:'warning'})]}),row(0,{status:'unchecked'}),row(0,{input:{...course(),location:undefined}}),row(0,{entry:{...course(),teacher:undefined}})]) assert.equal(parse([r]).valid,false);
  assert.equal(parse([row(0,{input:course({title:' 操作系统 ',teacher:' 陈老师 '})})]).valid,true);
});
test('source times and issue shapes are strict; future error codes never become ready', () => {
  for(const r of [row(0,{source_time:null}),row(0,{source_time:{...sourceTime(),start_tzid:undefined}}),row(0,{source_time:{...sourceTime(),end_value:8}}),row(0,{issues:[issue({field:'token',severity:'warning'})]}),row(0,{issues:[issue({message:'',severity:'warning'})]})]) assert.equal(parse([r]).valid,false);
  const r=badRow(0,{issues:[issue({code:'FUTURE_SOURCE_DIAGNOSTIC'})]});assert.equal(parse([r]).valid,true);assert.equal(classifyImportRows([r],[]).rows[0].category,'invalid');
});
test('compatibility entries cannot omit, modify or duplicate facts, or claim partial success with bad rows', () => {
  const a=row(),b=row(1,{},course({teacher:'李老师'}));
  for(const change of [{entries:[a.entry],event_count:1},{entries:[a.entry,a.entry],event_count:2},{entries:[a.entry,course({teacher:'周老师'})],event_count:2},{event_count:99}]) assert.equal(parse([a,b],change).valid,false);
  assert.equal(parse([a,b],{entries:[b.entry,a.entry],event_count:2}).valid,true);assert.equal(parse([a,badRow(1)],{entries:[a.entry],event_count:1}).valid,false);assert.equal(parse([a,row(1)],{entries:[a.entry],event_count:1}).valid,true);
});
test('parse whitelists independent copies and preserves long invalid text and raw times without truncation', () => {
  const long='😀'.repeat(101),r=badRow(0,{input:course({title:long}),source_time:{...sourceTime(),start_value:'original-unparsed-value'},private:'secret'});r.input.token='private-input';r.source_time.token='private-time';r.issues[0].token='private-issue';
  const result=parse([r],{warnings:['来源提示'],token:'private-preview'});assert.equal(result.valid,true);assert.equal(result.rows[0].input.title,long);assert.equal(result.rows[0].source_time.start_value,'original-unparsed-value');assert.equal(JSON.stringify(result).includes('private'),false);result.rows[0].input.title='changed';assert.equal(r.input.title,long);assert.equal(result.sourceWarnings[0].message,'来源提示');
});
test('same-name new courses append without overwriting or mutating original inputs', () => {
  const draft=[course()],rows=[row(0,{},course({start_time:'10:00',end_time:'11:00',teacher:'李老师'}))],before=JSON.stringify({draft,rows});const c=classifyImportRows(rows,draft);assert.equal(c.addCount,1);assert.equal(c.rows[0].category,'new');
  const result=assembleSelectedImport(rows,draft);assert.equal(result.valid,true);assert.equal(result.entries.length,2);assert.equal(result.entries[0].teacher,'陈老师');assert.equal(result.entries[1].teacher,'李老师');assert.equal(JSON.stringify({draft,rows}),before);result.entries[0].title='changed';assert.equal(draft[0].title,'操作系统');
});
test('duplicates use all six normalized fields and remain individually visible', () => {
  const rows=[row(0),row(1,{input:course({title:' 操作系统 '})}),row(2,{},course({teacher:'李老师'})),row(3,{},course({location:'二教'}))],c=classifyImportRows(rows,[]);assert.equal(c.rows.length,4);assert.equal(c.duplicateCount,1);assert.equal(c.rows[1].selected,false);assert.deepEqual(c.rows.map(r=>r.category),['overlap','duplicate','overlap','overlap']);
  const current=classifyImportRows([row()],[course()]);assert.equal(current.duplicateCount,1);assert.equal(current.unresolvedCount,0);assert.equal(assembleSelectedImport([row()],[course()],[choice(0,{mode:'include'})]).valid,false);
});
test('excluding an earlier duplicate promotes the next eligible source row', () => {
  const rows=[row(0),row(1)],choices=[choice(0,{mode:'exclude'})],c=classifyImportRows(rows,[],choices);assert.equal(c.excludedCount,1);assert.equal(c.duplicateCount,0);assert.equal(c.rows[1].category,'new');const result=assembleSelectedImport(rows,[],choices);assert.equal(result.valid,true);assert.equal(result.addedEntries.length,1);assert.match(result.warnings.at(-1).message,/明确排除 1 行/);
});
test('half-open overlaps show every full counterpart and need explicit current-key acknowledgement', () => {
  const draft=[course({title:'A',start_time:'08:00',end_time:'09:00'}),course({title:'B',start_time:'08:30',end_time:'09:30'})],rows=[row(0,{},course({title:'C',start_time:'08:45',end_time:'09:15'})),row(1,{},course({title:'D',start_time:'09:30',end_time:'10:00'}))],c=classifyImportRows(rows,draft),first=c.rows[0];assert.equal(first.category,'overlap');assert.equal(first.overlaps.length,2);assert.deepEqual(first.overlaps.map(x=>x.entry.title),['A','B']);assert.equal(c.rows[1].category,'new');assert.equal(first.selected,false);
  const accepted=assembleSelectedImport(rows,draft,[choice(0,{mode:'include',overlapKey:first.overlapKey})]);assert.equal(accepted.valid,true);assert.equal(accepted.entries.length,4);assert.equal(assembleSelectedImport(rows,draft,[choice(0,{mode:'include',overlapKey:'made-up'})]).valid,false);
});
test('within-batch overlaps both need acknowledgement unless the counterpart is explicitly excluded', () => {
  const rows=[row(),row(1,{},course({title:'另一门课',start_time:'08:30',end_time:'09:30'}))],c=classifyImportRows(rows,[]);assert.deepEqual(c.rows.map(r=>r.category),['overlap','overlap']);assert.equal(c.unresolvedCount,2);assert.equal(assembleSelectedImport(rows,[],c.rows.map(r=>choice(r.sourceIndex,{mode:'include',overlapKey:r.overlapKey}))).valid,true);
  const excluded=classifyImportRows(rows,[],[choice(1,{mode:'exclude'})]);assert.equal(excluded.rows[0].category,'new');assert.equal(excluded.rows[0].selected,true);assert.equal(assembleSelectedImport(rows,[],[choice(1,{mode:'exclude'})]).valid,true);
});
test('editing acknowledged facts or changing counterparts revokes old overlap confirmation', () => {
  const rows=[row(0,{},course({title:'导入课程'}))],draft=[course()],key=classifyImportRows(rows,draft).rows[0].overlapKey,accepted=choice(0,{mode:'include',overlapKey:key});assert.equal(assembleSelectedImport(rows,draft,[accepted]).valid,true);
  for(const changed of [[course({teacher:'变更老师'})],[course({location:'另一个教室'})],[course({end_time:'09:30'})]]) {assert.equal(classifyImportRows(rows,changed,[accepted]).unresolvedCount,1);assert.equal(assembleSelectedImport(rows,changed,[accepted]).valid,false);}
  assert.equal(assembleSelectedImport(rows,draft,[{...accepted,edited:course({title:'修改后标题'})}]).valid,false);const edited=choice(0,{mode:'include',edited:course({title:'修改后标题'})}),newKey=classifyImportRows(rows,draft,[edited]).rows[0].overlapKey;assert.equal(assembleSelectedImport(rows,draft,[{...edited,overlapKey:newKey}]).valid,true);
});
test('invalid or unsupported source events require correction plus source review, not a bare include checkbox', () => {
  const rows=[unsupported()];for(const c of [choice(0,{mode:'include'}),choice(0,{mode:'include',sourceIssuesReviewed:true}),choice(0,{edited:course()})]) assert.equal(assembleSelectedImport(rows,[],[c]).valid,false);
  const result=assembleSelectedImport(rows,[],[choice(0,{edited:course(),sourceIssuesReviewed:true})]);assert.equal(result.valid,true);assert(result.warnings.some(w=>/重复系列尚未展开/.test(w.message)));assert(result.warnings.some(w=>/单次课程/.test(w.message)));assert.equal(assembleSelectedImport([badRow()],[],[choice(0,{edited:course({end_time:'07:00'}),sourceIssuesReviewed:true})]).valid,false);
});
test('fixing or excluding one row cannot silently ignore another unresolved source event', () => {
  const rows=[row(),badRow(1),unsupported(2)],choices=[choice(1,{edited:course({date:'2026-10-20'}),sourceIssuesReviewed:true})];assert.equal(assembleSelectedImport(rows,[],choices).valid,false);choices.push(choice(2,{mode:'exclude'}));const result=assembleSelectedImport(rows,[],choices);assert.equal(result.valid,true);assert.equal(result.addedEntries.length,2);assert.equal(result.excludedCount,1);
});
test('choices reject missing/wrong indexes, duplicate overrides and malformed values', () => {
  for(const choices of [[choice(-1)],[choice(1)],[choice(0),choice(0)],[choice(0,{mode:'automatic'})],[choice(0,{edited:{...course(),teacher:undefined}})],[choice(0,{sourceIssuesReviewed:'true'})],[choice(0,{overlapKey:true})],[null]]) {assert.equal(classifyImportRows([row()],[],choices).valid,false);assert.equal(assembleSelectedImport([row()],[],choices).valid,false);}
});
test('existing draft errors and combined 501-item limit reject the whole merge without truncation', () => {
  assert.equal(classifyImportRows([row()],[course(),course()]).valid,false);assert.equal(classifyImportRows([row()],[course({date:'2026-02-30'})]).valid,false);const existing=Array.from({length:500},(_,i)=>course({title:`既有 ${i}`})),result=assembleSelectedImport([row(0,{},course({date:'2026-10-20',title:'新增'}))],existing);assert.equal(result.valid,false);assert.match(result.message,/500/);assert.deepEqual(result.entries,[]);assert.deepEqual(result.addedEntries,[]);assert.equal(existing.length,500);
});
test('500 rows remain complete and accepted warnings preserve floating-time interpretation', () => {
  const rows=Array.from({length:500},(_,i)=>row(i,{issues:i===0?[issue({field:'start_time',code:'FLOATING_CAMPUS_TIME',severity:'warning',message:'来源未提供时区，本次按北京时间解释，请核对。'})]:[]},course({title:`课程 ${i}`,date:`${String(2000+i).padStart(4,'0')}-10-19`})));
  const parsed=parse(rows);assert.equal(parsed.valid,true);assert.equal(parsed.rows.length,500);const result=assembleSelectedImport(parsed.rows,[]);assert.equal(result.valid,true);assert.equal(result.entries.length,500);assert.equal(new Set(result.entries.map(identity)).size,500);assert.match(result.warnings[0].message,/来源未提供时区/);
});
test('500 floating minute-precision courses retain all four reasons with counts and exact source ranges', () => {
  const payload=maximumWarningPreview(),before=JSON.stringify(payload),parsed=parseImportReview(before);
  assert.equal(parsed.valid,true);const result=assembleSelectedImport(parsed.rows,[]);
  assert.equal(result.valid,true,result.message);assert.equal(result.entries.length,500);
  assert.equal(result.warnings.length,4);assert.equal(parsed.sourceWarnings.length+result.warnings.length,6);
  for(const warning of result.warnings) {
    assert.equal(warning.index,-1);assert.match(warning.message,/源第 1–500 行，共 500 行、500 处/);
    assert(warning.message.length<=2048);
  }
  assert.equal(result.warnings.filter(w=>w.message.startsWith('开始时间：')).length,2);
  assert.equal(result.warnings.filter(w=>w.message.startsWith('结束时间：')).length,2);
  assert.equal(result.warnings.filter(w=>/时区/.test(w.message)).length,2);
  assert.equal(result.warnings.filter(w=>/分钟精度/.test(w.message)).length,2);
  assert.equal(JSON.stringify(payload),before);assert.deepEqual(result.entries,payload.entries);
});
test('source warning groups preserve nonconsecutive row references, repeated occurrences and distinct reasons', () => {
  const time=issue({field:'start_time',code:'FLOATING_CAMPUS_TIME',severity:'warning',message:'按北京时间解释。'});
  const rows=Array.from({length:6},(_,i)=>row(i,{issues:i===3?[]:[time]},course({date:`2026-10-${20+i}`})));
  rows[0].issues.push(structuredClone(time));
  rows[5].issues.push({...time,field:'end_time'},{...time,code:'OTHER_REASON',message:'另一项来源限制。'});
  const result=assembleSelectedImport(rows,[],[choice(1,{mode:'exclude'})]);
  assert.equal(result.valid,true);assert.equal(result.entries.length,5);
  assert.match(result.warnings[0].message,/源第 1、3、5–6 行，共 4 行、5 处/);
  assert(result.warnings.some(w=>w.message.startsWith('结束时间：')&&/源第 6 行，共 1 行、1 处/.test(w.message)));
  assert(result.warnings.some(w=>/另一项来源限制/.test(w.message)));
});
test('an unpersistable explanation refuses the whole merge without dropping the explanation or courses', () => {
  const rows=[row(0,{issues:[issue({severity:'warning',message:'完整来源'.repeat(700)})]})];
  const result=assembleSelectedImport(rows,[]);assert.equal(result.valid,false);assert.match(result.message,/保存范围/);
  assert.deepEqual(result.entries,[]);assert.deepEqual(result.addedEntries,[]);assert.equal(rows[0].issues[0].message.length,2800);
});
test('no selected additions is an explicit no-op, never empty-table import or save success', () => {
  for(const result of [assembleSelectedImport([row()],[course()]),assembleSelectedImport([badRow()],[],[choice(0,{mode:'exclude'})])]) {assert.equal(result.valid,false);assert.deepEqual(result.entries,[]);assert.match(result.message,/没有选中可新增/);}
});

const realFixture=JSON.parse(readFileSync(new URL('./fixtures/timetable-import-asgi-v1.json',import.meta.url),'utf8'));
test('real authenticated ASGI mixed/all-ready/duplicate/unsupported JSON matches the production client parser',()=>{
  assert.match(realFixture.provenance,/Actual local authenticated ASGI/);assert.equal(realFixture.preview_unchanged_timetable,true);
  for(const [name,response] of Object.entries(realFixture.responses)) {
    const result=parseImportReview(JSON.stringify(response));assert.equal(result.valid,true,`${name}: ${result.message}`);assert.equal(result.rows.length,response.source_event_count);
  }
  const mixed=parseImportReview(JSON.stringify(realFixture.responses.mixed));
  assert.deepEqual(classifyImportRows(mixed.rows,realFixture.base_draft).rows.map(r=>r.category),realFixture.expected_mixed_categories_against_base);
  assert.equal(mixed.rows[0].source_time.start_value,'20261018T233000Z');assert.equal(mixed.rows[0].input.date,'2026-10-19');assert.equal(mixed.rows[0].input.start_time,'07:30');
});
test('real mixed JSON can merge only after explicit overlap acknowledgement, one correction and one exclusion',()=>{
  const parsed=parseImportReview(JSON.stringify(realFixture.responses.mixed)),base=structuredClone(realFixture.base_draft);
  const first=classifyImportRows(parsed.rows,base);assert.equal(assembleSelectedImport(parsed.rows,base).valid,false);
  const fixed={...parsed.rows[3].input,date:'2026-10-20',start_time:'10:00',end_time:'11:00'};
  const choices=[choice(2,{mode:'include',overlapKey:first.rows[2].overlapKey}),choice(3,{edited:fixed,sourceIssuesReviewed:true}),choice(4,{mode:'exclude'})];
  const result=assembleSelectedImport(parsed.rows,base,choices);assert.equal(result.valid,true,result.message);assert.equal(result.entries.length,3);assert.equal(result.addedEntries.length,2);assert.equal(result.duplicateCount,2);assert.equal(result.excludedCount,1);assert.deepEqual(base,realFixture.base_draft);
  assert.equal(new Set(result.entries.map(identity)).size,3);assert(result.warnings.some(w=>/单次课程/.test(w.message)));assert(result.warnings.some(w=>/明确排除 1 行.*重复未新增 2 行/.test(w.message)));
});
