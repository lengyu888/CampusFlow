import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
const script=fileURLToPath(new URL('./build-native.mjs',import.meta.url));
for(const [platform,target] of [['harmony','hap'],['android','apk'],['ios','ios']]){
 test(`${platform} default is dry-run and never invokes configured fake CLI`,()=>{
  const result=spawnSync(process.execPath,[script,platform],{encoding:'utf8',env:{...process.env,CAMPUSFLOW_ACE_BIN:'/missing-native-cli'}});
  assert.equal(result.status,0);assert.match(result.stdout,new RegExp(`ace build ${target} --debug`));assert.match(result.stdout,/未调用任何原生工具/);
  if(platform==='ios')assert.match(result.stdout,/--nosign/);
 });
}
test('invalid target and unsupported options fail before any tool execution',()=>{
 for(const args of [['deploy'],['android','--install'],['ios','--device']]){
  const result=spawnSync(process.execPath,[script,...args],{encoding:'utf8'});assert.equal(result.status,2);
 }
});
test('explicit execute with missing preconfigured CLI fails without installing anything',()=>{
 const result=spawnSync(process.execPath,[script,'android','--execute'],{encoding:'utf8',env:{...process.env,CAMPUSFLOW_ACE_BIN:'/missing-native-cli'}});
 assert.equal(result.status,2);assert.match(result.stderr,/现有工具不存在/);
});
