import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { readFileSync, existsSync } from 'node:fs';
import * as fs from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { stripTypeScriptTypes } from 'node:module';
import { createHash } from 'node:crypto';

export const repository = fileURLToPath(new URL('../../../', import.meta.url));
const ets = path.join(repository, 'arkui-x-client/entry/src/main/ets');
const clean = source => source.replace(/^import \{[\s\S]*?\} from '[^']+';\r?\n/gm, '').replace(/^import [^\n]+;\r?\n/gm, '');
export const tick = () => new Promise(resolve => setImmediate(resolve));
export async function eventually(predicate, label, maximum = 300) {
  for (let index=0; index<maximum; index++) { if (await predicate()) return; await new Promise(resolve=>setTimeout(resolve,10)); }
  throw Error(`Journey condition timed out: ${label}`);
}
export function journeyPython(root = repository, env = process.env, platform = process.platform) {
  if (env.CAMPUSFLOW_TEST_PYTHON) return env.CAMPUSFLOW_TEST_PYTHON;
  const localPython = path.join(root, 'agent-service', '.venv', ...(platform === 'win32' ? ['Scripts', 'python.exe'] : ['bin', 'python']));
  return existsSync(localPython) ? localPython : platform === 'win32' ? 'python' : 'python3';
}
export class JourneyBridge {
  #next=0; #pending=new Map(); #closed=false; #child;
  diagnostics=[];
  constructor() {
    const python=journeyPython();
    this.#child=spawn(python,['-u','tests/ux11_journey_bridge.py'],{cwd:path.join(repository,'agent-service'),
      env:{...process.env,PYTHONPATH:'src',PYTHONUNBUFFERED:'1'},stdio:['pipe','pipe','pipe']});
    createInterface({input:this.#child.stdout}).on('line',line=>{
      let response;try{if(Buffer.byteLength(line)>4*1024*1024)throw Error('large');response=JSON.parse(line);}catch{this.#fail('Invalid bridge response');return;}
      const pending=this.#pending.get(response.id);if(!pending)return;
      this.#pending.delete(response.id);clearTimeout(pending.timer);
      if(response.ok)pending.resolve(response.result);else{const error=Error(response.error?.code??'BRIDGE_ERROR');error.code=response.error?.code??'BRIDGE_ERROR';pending.reject(error);}
    });
    // Retain only coarse diagnostics. Never save a raw line that might contain a payload.
    this.#child.stderr.on('data',()=>{if(!this.diagnostics.includes('bridge emitted stderr'))this.diagnostics.push('bridge emitted stderr');});
    this.#child.on('error',()=>this.#fail('Bridge process could not start'));
    this.#child.on('exit',(code)=>this.#fail(`Bridge process exited (${code ?? 'signal'})`));
  }
  #fail(message){this.#closed=true;for(const value of this.#pending.values()){clearTimeout(value.timer);value.reject(Error(message));}this.#pending.clear();}
  rpc(method,params={}){
    if(this.#closed)return Promise.reject(Error('Bridge is closed'));
    const id=++this.#next;return new Promise((resolve,reject)=>{
      const timer=setTimeout(()=>{this.#pending.delete(id);reject(Error(`Bridge timeout (${method})`));},30000);
      this.#pending.set(id,{resolve,reject,timer});
      this.#child.stdin.write(JSON.stringify({id,method,params})+'\n');
    });
  }
  async close(){if(!this.#closed){try{await this.rpc('shutdown');}catch{}this.#child.stdin.end();}this.#child.kill();}
}

// Production modules share ONE CampusFlowRequestError class and one frozen business
// Date. Timers/setImmediate remain real, so neither RPC nor runtime cancellation freezes.
export function loadJourneyModules(now){
  const nativeDate=Date;
  class BusinessDate extends nativeDate{constructor(...args){super(...(args.length?args:[now()]));}static now(){return now();}}
  const shared={Date:BusinessDate};const hashes={};
  function load(relative,dependencies={}){
    const source=readFileSync(path.join(ets,relative+'.ets'),'utf8');hashes[relative]=createHash('sha256').update(source).digest('hex');
    const exports=[...source.matchAll(/^export\s+(?:async\s+)?(?:function|class|const)\s+(\w+)/gm)].map(match=>match[1]);
    const deps={...shared,...dependencies};
    return new Function(...Object.keys(deps),stripTypeScriptTypes(clean(source).replace(/^export /gm,''))+`\nreturn {${exports.join(',')}};`)(...Object.values(deps));
  }
  for(const name of ['AgentFeedback','DailyAgenda','OnboardingTimetable','PlanPresentation','DraftStore','LocalHistoryStore','QuickCaptureParser','TimetableImportReview',
    'CourseReview','ActionReliability','PlanningAction','PlanningReplan','TimetableMaintenance','AgentRun','TaskStatusValidation','TaskStatusController',
    'FocusDigest','FocusValidation','FocusTimer','FocusStore','FocusController','ReviewTime','ReviewValidation','ReviewController','ReviewSummary'])Object.assign(shared,load(`utils/${name}`));
  return {module:shared,hashes,load,
    api(bridge,journal){
      const http={RequestMethod:{GET:'GET',POST:'POST',PUT:'PUT',DELETE:'DELETE',PATCH:'PATCH'},HttpDataType:{STRING:'string'},createHttp(){return {
        async request(url,options){const parsed=new URL(url);if(parsed.origin!=='https://journey.invalid')throw Error('External transport forbidden');
          const entry={method:options.method,path:parsed.pathname,status:null};journal.push(entry);
          try{const result=await bridge.rpc('http',{method:options.method,path:parsed.pathname+parsed.search,headers:options.header,body:options.extraData});entry.status=result.status;
            return {responseCode:result.status,result:result.body,header:result.headers};}
          catch(error){entry.transport_error=error.code??'BRIDGE_TRANSPORT';throw error;}
        },destroy(){}};}};
      return load('services/CampusFlowApi',{http}).CampusFlowApi;
    },
    page(name,dependencies={}){
      const source=readFileSync(path.join(ets,'pages',name+'.ets'),'utf8');hashes[`pages/${name}`]=createHash('sha256').update(source).digest('hex');
      const end=source.indexOf('\n  @Builder');if(end<0)throw Error(`No page method boundary: ${name}`);
      const methods=clean(source.slice(0,end)).replace(/^@Component\r?\n/gm,'').replace(/@(State|Prop|StorageLink|Link)\('[^']+'\)\s*|@(State|Prop|StorageLink|Link)\s*|@Watch\('[^']+'\)\s*/g,'')
        .replace(`export struct ${name}`,`class ${name}`)+'\n}';
      const deps={...shared,...dependencies};return new Function(...Object.keys(deps),stripTypeScriptTypes(methods)+`\nreturn ${name}`)(...Object.values(deps));
    }};
}

export async function localFiles(loader,directory){
  await fs.mkdir(directory,{recursive:true});const handles=new Map();let failure=false;let beforeRename=null;
  const wrap=async callback=>{try{return await callback();}catch(error){if(error.code==='ENOENT')throw {code:13900002};throw error;}};
  const shim={OpenMode:{WRITE_ONLY:1,CREATE:2,TRUNC:4},stat:p=>wrap(()=>fs.stat(p)),readText:p=>wrap(()=>fs.readFile(p,'utf8')),
    open:async p=>{const handle=await fs.open(p,'w');handles.set(handle.fd,handle);return {fd:handle.fd};},
    write:async(fd,text)=>(await handles.get(fd).write(Buffer.from(text,'utf8'))).bytesWritten,fsync:fd=>handles.get(fd).sync(),
    close:async file=>{await handles.get(file.fd).close();handles.delete(file.fd);},
    rename:async(a,b)=>{if(beforeRename)await beforeRename();if(failure)throw Error('Injected local persistence failure');await fs.rename(a,b);},unlink:p=>wrap(()=>fs.unlink(p))};
  const {FileDraftDriver}=loader.load('services/LocalDrafts',{fs:shim});const draftDriver=new FileDraftDriver();draftDriver.configure(directory);
  const {FileFocusDriver}=loader.load('services/LocalFocus',{fs:shim});const focusDriver=new FileFocusDriver();focusDriver.configure(directory);
  return {draftDriver,focusDriver,setFailure:value=>{failure=value;},setBeforeRename:value=>{beforeRename=value;},
    read:async name=>JSON.parse(await fs.readFile(path.join(directory,name),'utf8'))};
}
export class JourneyScheduler {
  jobs=new Map();serial=0;
  constructor(clock=()=>Date.now()){this.clock=clock;}
  now(){return this.clock();}
  set(callback){return this.setTimeout(callback);}
  clear(id){this.clearTimeout(id);}
  setTimeout(callback){const id=++this.serial;this.jobs.set(id,callback);return id;}
  clearTimeout(id){this.jobs.delete(id);}
  async step(){const jobs=[...this.jobs.values()];this.jobs.clear();for(const job of jobs)job();await tick();}
}
