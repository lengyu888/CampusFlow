import assert from 'node:assert/strict';
import {test} from 'node:test';
import * as fs from 'node:fs/promises';
import {readFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {stripTypeScriptTypes} from 'node:module';
import {stores,FocusStore,focusFixture,uuid} from './helpers/focus-fixture.mjs';
async function driverFixture(){
 const directory=await fs.mkdtemp(path.join(tmpdir(),'campusflow-focus-')),handles=new Map();let failRename=false;
 const wrap=async callback=>{try{return await callback();}catch(error){if(error.code==='ENOENT')throw {code:13900002};throw error;}};
 const bridge={OpenMode:{WRITE_ONLY:1,CREATE:2,TRUNC:4},stat:p=>wrap(()=>fs.stat(p)),readText:p=>wrap(()=>fs.readFile(p,'utf8')),
 open:async p=>{const file=await fs.open(p,'w');handles.set(file.fd,file);return {fd:file.fd};},
 write:async(fd,text)=>(await handles.get(fd).write(Buffer.from(text,'utf8'))).bytesWritten,fsync:fd=>handles.get(fd).sync(),
 close:async file=>{await handles.get(file.fd).close();handles.delete(file.fd);},rename:async(a,b)=>{if(failRename)throw Error('rename');await fs.rename(a,b);},unlink:p=>wrap(()=>fs.unlink(p))};
 let source=readFileSync(new URL('../entry/src/main/ets/services/LocalFocus.ets',import.meta.url),'utf8').replace(/^import [^\n]+;\r?\n/gm,'').replace(/^export /gm,'');
 const {FileFocusDriver}=new Function('fs','FocusStore','MAX_FOCUS_BYTES','focusBytes',stripTypeScriptTypes(source)+'\nreturn {FileFocusDriver};')(bridge,FocusStore,stores.MAX_FOCUS_BYTES,stores.focusBytes);
 const driver=new FileFocusDriver();driver.configure(directory);return {directory,driver,setFailure:value=>{failRename=value;},cleanup:()=>fs.rm(directory,{recursive:true,force:true})};
}
test('actual FileFocusDriver persists UTF-8 via same-directory atomic rename and a new store restores exact queue',async()=>{
 const f=await driverFixture();try{
  const first=await focusFixture({driver:f.driver});await first.controller.start('课程任务📚',null,'offline');await first.scheduler.step(first.clock,5000);await first.controller.mutationTail;first.controller.dispose();
  const before=await fs.readFile(path.join(f.directory,'campusflow-local-focus-v1.json'),'utf8');assert.equal(JSON.parse(before).records[0].anchor.elapsedMs,5000);
  const second=await focusFixture({driver:f.driver,firstId:100});assert.equal(second.state().local.taskId,'课程任务📚');assert.equal(second.state().local.elapsedMs,5000);assert.equal(second.state().local.unknownGapCount,1);
  assert.deepEqual(await fs.readdir(f.directory),['campusflow-local-focus-v1.json']);assert.equal(second.state().pendingOperations.length,2);
 }finally{await f.cleanup();}
});
test('failed actual driver replacement leaves old file intact; clear removes file and invalidates leases',async()=>{
 const f=await driverFixture();try{
  const store=new FocusStore(f.driver);await store.initialize();const lease=await store.activate('scope',uuid(1));const before=await fs.readFile(path.join(f.directory,'campusflow-local-focus-v1.json'),'utf8');
  const next=store.snapshot(lease);next.revision++;f.setFailure(true);await assert.rejects(store.commit(lease,next.revision-1,next));
  assert.equal(await fs.readFile(path.join(f.directory,'campusflow-local-focus-v1.json'),'utf8'),before);assert.equal(store.snapshot(lease).revision,1);assert.deepEqual(await fs.readdir(f.directory),['campusflow-local-focus-v1.json']);
  f.setFailure(false);await store.clear();assert.equal(store.valid(lease),false);assert.deepEqual(await fs.readdir(f.directory),[]);
 }finally{await f.cleanup();}
});
