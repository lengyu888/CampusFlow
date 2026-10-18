import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
export { DraftStore, DraftMemoryDriver, draftFixture } from './local-draft-fixture.mjs';
const read = name => readFileSync(new URL(`../../entry/src/main/ets/utils/${name}.ets`, import.meta.url), 'utf8');
const clean = s => s.replace(/^import \{[\s\S]*?\} from '[^']+';\r?\n/gm, '').replace(/^import [^\n]+;\r?\n/gm, '');
const module = async name => import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(clean(read(name)))).toString('base64')}`);
const agenda = await module('DailyAgenda');
const feedback = await module('AgentFeedback');
export const { CampusFlowRequestError } = feedback;
const load = (name, dependencies, names) => new Function(...Object.keys(dependencies), stripTypeScriptTypes(clean(read(name)).replace(/^export /gm, '')) + `\nreturn {${names.join(',')}};`)(...Object.values(dependencies));
export const validation = load('TaskStatusValidation', agenda, ['taskStatusUuid','validTaskStatusRequest','validTaskStatusOperation','sameTaskStatusCandidate','requiredTaskStatusAcknowledgements','validTaskStatusAcknowledgements','taskStatusCanConfirm']);
export const { TaskStatusController } = load('TaskStatusController', { ...validation, CampusFlowRequestError }, ['TaskStatusController']);
export const statusIds = {
 complete: '10000000-0000-4000-8000-000000000001', restore: '10000000-0000-4000-8000-000000000002',
 other: '10000000-0000-4000-8000-000000000003', ack: '10000000-0000-4000-8000-000000000004'
};
export const statusNow = Date.parse('2030-10-19T07:00:00+08:00');
export const statusTask = (extra = {}) => ({ task_id:'task-a', plan_id:null, milestone_id:null, title:'复习操作系统',
 start_at:'2030-10-19T09:00:00+08:00', end_at:'2030-10-19T10:00:00+08:00', reminder_minutes:10,
 location:'图书馆', status:'pending', source:'manual', created_at:'2030-10-18T12:00:00+08:00',
 completed_at:null, task_version:1, allow_during_course:false, completion_operation_id:null, ...extra });
export function completeOperation(task = statusTask(), request = { operation_id:statusIds.complete,kind:'complete',expected_revision:task.task_version }, extra = {}) {
 const applied='2030-10-19T06:00:00+08:00';
 return {contract_version:1,user_id:'account-a',operation_id:request.operation_id,task_id:task.task_id,kind:'complete',state:'applied',expected_revision:request.expected_revision,
 source_operation_id:null,created_at:applied,expires_at:null,preview:null,
 receipt:{operation_id:request.operation_id,task_id:task.task_id,kind:'complete',source_operation_id:null,
 before_revision:request.expected_revision,after_revision:request.expected_revision+1,before_status:'pending',after_status:'completed',before_completed_at:null,after_completed_at:applied,applied_at:applied,
 candidate_id:null,course_acknowledgement_ids:[],course_acknowledgements:[]},...extra};
}
export const completedTask = (extra = {}) => statusTask({ status:'completed',task_version:2,completed_at:'2030-10-19T06:00:00+08:00',completion_operation_id:statusIds.complete,...extra });
export function restoreOperation(task = completedTask(), request = { operation_id:statusIds.restore,kind:'restore',expected_revision:task.task_version,source_operation_id:task.completion_operation_id }, extra = {}) {
 const candidate='status:'+request.operation_id;
 return {contract_version:1,user_id:'account-a',operation_id:request.operation_id,task_id:task.task_id,kind:'restore',state:'pending',expected_revision:request.expected_revision,
 source_operation_id:request.source_operation_id,created_at:'2030-10-19T07:00:00+08:00',expires_at:'2030-10-19T07:15:00+08:00',receipt:null,
 preview:{task:structuredClone(task),from_status:'completed',to_status:'pending',candidate_id:candidate,state_version:{timetable:1,planning:2},conflicts:[],warnings:[],
 course_review:{candidate_id:candidate,task_id:task.task_id,allow_during_course:task.allow_during_course,state:'none',review_digest:'a'.repeat(64),requires_acknowledgement:false,revoke_only:false,
 school:'杭州电子科技大学',campus:'下沙校区',timezone:'Asia/Shanghai',timetable_version:1,planning_version:2,task_version:task.task_version,candidate_digest:'b'.repeat(64),overlaps:[]}},...extra};
}
export function overlappingRestore() {
 const result=restoreOperation(completedTask({allow_during_course:true,course_overlap:{state:'accepted'}}));
 Object.assign(result.preview.course_review,{state:'needs_review',requires_acknowledgement:true,overlaps:[{course_key:'c'.repeat(64),
 course:{date:'2030-10-19',title:'上课',start_time:'09:30',end_time:'10:30',location:'教学楼',teacher:'教师'},
 overlap_start_at:'2030-10-19T09:30:00+08:00',overlap_end_at:'2030-10-19T10:00:00+08:00'}]});return result;
}
export function appliedRestore(preview=restoreOperation()) {
 const result=structuredClone(preview);result.state='applied';
 const needs=result.preview.course_review.requires_acknowledgement;
 result.receipt={operation_id:result.operation_id,task_id:result.task_id,kind:'restore',source_operation_id:result.source_operation_id,
 before_revision:result.expected_revision,after_revision:result.expected_revision+1,before_status:'completed',after_status:'pending',
 before_completed_at:result.preview.task.completed_at,after_completed_at:null,applied_at:'2030-10-19T07:01:00+08:00',candidate_id:result.preview.candidate_id,
 course_acknowledgement_ids:needs?[statusIds.ack]:[],course_acknowledgements:needs?[{candidate_id:result.preview.candidate_id,acknowledgement_id:statusIds.ack}]:[]};return result;
}
export function deferred() { let resolve,reject;const promise=new Promise((a,b)=>{resolve=a;reject=b});return {promise,resolve,reject}; }
export const tick=async()=>{for(let i=0;i<12;i++)await Promise.resolve();};
