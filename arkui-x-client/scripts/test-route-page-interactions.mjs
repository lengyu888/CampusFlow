import './helpers/theme-fixture.mjs';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripThemeTypeScriptTypes as stripTypeScriptTypes } from './helpers/theme-fixture.mjs';
import { test } from 'node:test';
const source=readFileSync(new URL('../entry/src/main/ets/pages/RoutePage.ets',import.meta.url),'utf8');
const controller=source.slice(0,source.indexOf('\n  @Builder')).replace(/^import [^\n]+;\r?\n/gm,'').replace(/^@Component\r?\n/gm,'')
 .replace(/@(State|Prop)\s+|@Watch\('[^']+'\)\s*/g,'').replace('export struct RoutePage','class RoutePage')+'\n}';
const matcher=readFileSync(new URL('../entry/src/main/ets/utils/CourseRouteIntent.ets',import.meta.url),'utf8').replace(/^import [^\n]+;\r?\n/gm,'');
const {matchCoursePlace}=await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(matcher)).toString('base64')}`);
const create=new Function('CampusFlowApi','Scroller','matchCoursePlace',stripTypeScriptTypes(controller)+'\nreturn RoutePage;');
const places=[{place_id:'a',name:'图书馆',aliases:['校图书馆'],zone:'教学区'},
 {place_id:'b',name:'第7教研楼（信博楼）',aliases:['7教','第七教研楼'],zone:'教学区'},
 {place_id:'c',name:'操场',aliases:['东操场'],zone:'教学区'}];
const data=(rows=places)=>({places:rows,package:{package_id:'hdu-xiasha',version:'fixture',school:'杭州电子科技大学',campus:'下沙校区',evidence:[]}});
const route=(a,b)=>({package_id:'hdu-xiasha',package_version:'fixture',origin:places.find(x=>x.place_id===a),destination:places.find(x=>x.place_id===b),path:[],steps:[]});
const intent=(location,requestId=1)=>({requestId,school:'杭州电子科技大学',campus:'下沙校区',timetableRevision:'a'.repeat(64),evidence:[],
 course:{date:'2026-10-19',title:'同名课程',start_time:'08:00',end_time:'09:40',location,teacher:'教师'}});
const tick=()=>new Promise(resolve=>setImmediate(resolve));
function choosePair(page){page.choosePlace(0,true);page.choosePlace(1,false);}
const deferred=()=>{let resolve,reject;const promise=new Promise((a,b)=>{resolve=a;reject=b;});return {resolve,reject,promise};};
function setup(overrides={}){
 const calls=[];const hooks={campusData:async()=>data(),campusRoute:async(a,b)=>route(a,b),...overrides};
 class Api{campusData(){calls.push(['data']);return hooks.campusData();}campusRoute(...args){calls.push(['route',...args]);return hooks.campusRoute(...args);}}
 const Page=create(Api,class Scroller{},matchCoursePlace);const page=new Page();page.baseUrl='https://fixture.invalid';page.token='account';
 page.routeScope='fixture-account';page.accountChanged();page.applyContext();return{page,calls,hooks};
}
test('places load does not presume a current location and refresh preserves explicit choices by ID',async()=>{
 const {page,hooks,calls}=setup();await page.loadPlaces();assert.equal(page.destinationIndex,-1);assert.equal(page.originIndex,-1);
 await page.createRoute();assert.equal(calls.some(call=>call[0]==='route'),false);
 page.choosePlace(0,true);page.choosePlace(2,false);hooks.campusData=async()=>data([places[2],places[0],places[1]]);await page.loadPlaces();
 assert.equal(page.places[page.originIndex].place_id,'a');assert.equal(page.places[page.destinationIndex].place_id,'c');
});
test('route request uses exact IDs and selection change rejects old route without changing new draft',async()=>{
 const pending=deferred();const {page,calls}=setup({campusRoute:()=>pending.promise});await page.loadPlaces();choosePair(page);const read=page.createRoute();
 page.choosePlace(2,false);pending.resolve(route('a','b'));await read;
 assert.equal(page.route,null);assert.equal(page.destinationIndex,2);assert.equal(page.routeLoading,false);
 assert.deepEqual(calls.find(call=>call[0]==='route'),['route','a','b']);
});
test('swap invalidates pending route and repeat taps do not dispatch duplicate calls',async()=>{
 const pending=deferred();const {page,calls}=setup({campusRoute:()=>pending.promise});await page.loadPlaces();choosePair(page);const read=page.createRoute();await page.createRoute();
 assert.equal(calls.filter(x=>x[0]==='route').length,1);page.swap();pending.reject(Error('secret'));await read;
 assert.equal(page.errorText,'');assert.equal(page.originIndex,1);assert.equal(page.destinationIndex,0);
});
test('same origin, unavailable endpoints and invalid selections cannot request routes',async()=>{
 const {page,calls}=setup();await page.loadPlaces();page.choosePlace(0,true);page.choosePlace(0,false);await page.createRoute();assert.ok(page.errorText);
 page.choosePlace(-1,true);page.choosePlace(50,true);page.choosePlace(NaN,false);assert.equal(page.originIndex,0);
 assert.equal(calls.filter(x=>x[0]==='route').length,0);
});
test('hidden or disposed page rejects delayed private data and late failures',async()=>{
 for(const disappear of [false,true]){const pending=deferred();const {page}=setup({campusData:()=>pending.promise});const read=page.loadPlaces();
 if(disappear)page.aboutToDisappear();else{page.active=false;page.activeChanged();}
 pending.resolve(data());await read;assert.deepEqual(page.places,[]);assert.equal(page.loading,false);}
});
test('route failure preserves chosen places and can retry without exposing raw exception',async()=>{
 const {page,hooks}=setup({campusRoute:async()=>{throw Error('secret');}});await page.loadPlaces();page.choosePlace(0,true);page.choosePlace(2,false);await page.createRoute();
 assert.ok(page.errorText);assert.ok(!page.errorText.includes('secret'));assert.equal(page.destinationIndex,2);
 hooks.campusRoute=async()=>route('a','b');await page.createRoute();assert.equal(page.route,null);
 hooks.campusRoute=async()=>({...route('a','c'),package_version:'old'});await page.createRoute();assert.equal(page.route,null);
 hooks.campusRoute=async()=>route('a','c');await page.createRoute();assert.equal(page.route.destination.name,'操场');assert.equal(page.errorText,'');
});

test('a unique course preselects only the destination and still requires explicit origin',async()=>{
 const {page,calls}=setup();page.courseIntent=intent('第7教研楼北406');page.applyContext();await page.loadPlaces();
 assert.equal(page.destinationIndex,1);assert.equal(page.originIndex,-1);assert.equal(page.courseMatch.remainingRoomText,'北406');
 await page.createRoute();assert.equal(calls.some(call=>call[0]==='route'),false);
 page.choosePlace(0,true);await page.createRoute();assert.equal(page.route.destination.place_id,'b');
});
test('ambiguous and unmatched places retain original text without picking the first candidate',async()=>{
 const {page}=setup();page.courseIntent=intent('图书馆/7教');page.applyContext();await page.loadPlaces();
 assert.equal(page.courseMatch.status,'ambiguous');assert.equal(page.destinationIndex,-1);
 assert.deepEqual(page.candidatePlaces().map(place=>place.place_id),['a','b']);page.selectCandidate('b');assert.equal(page.destinationIndex,1);
 page.courseIntent=intent('不认识的教室',2);page.applyContext();assert.equal(page.courseMatch.originalLocation,'不认识的教室');assert.equal(page.destinationIndex,-1);
});
test('choices survive hiding and each navigation root restores its course and manual endpoints',async()=>{
 const {page}=setup();page.courseIntent=intent('7教');page.applyContext();await page.loadPlaces();page.choosePlace(0,true);
 page.active=false;page.activeChanged();page.active=true;page.activeChanged();await tick();assert.equal(page.originIndex,0);assert.equal(page.destinationIndex,1);
 page.courseIntent=null;page.contextChanged();page.routeContextKey='8';page.contextChanged();await tick();
 assert.equal(page.originIndex,-1);assert.equal(page.destinationIndex,-1);page.choosePlace(2,true);page.choosePlace(0,false);
 page.courseIntent=intent('7教');page.contextChanged();page.routeContextKey='0';page.contextChanged();await tick();
 assert.equal(page.originIndex,0);assert.equal(page.destinationIndex,1);assert.equal(page.visibleCourse.course.location,'7教');
 page.courseIntent=null;page.contextChanged();page.routeContextKey='8';page.contextChanged();await tick();
 assert.equal(page.originIndex,2);assert.equal(page.destinationIndex,0);assert.equal(page.visibleCourse,null);
});
test('changing course during a places refresh cannot restore the previous destination',async()=>{
 const {page,hooks}=setup();page.courseIntent=intent('7教');page.applyContext();await page.loadPlaces();page.choosePlace(0,true);
 const pending=deferred();hooks.campusData=()=>pending.promise;const refresh=page.loadPlaces();
 page.courseIntent=intent('操场',2);page.contextChanged();await tick();pending.resolve(data());await refresh;
 assert.equal(page.destinationIndex,2);assert.equal(page.originIndex,-1);
});
test('account invalidation clears course and cached choices and rejects late responses',async()=>{
 const {page,hooks}=setup();page.courseIntent=intent('7教');page.applyContext();await page.loadPlaces();page.choosePlace(0,true);
 const pending=deferred();hooks.campusRoute=()=>pending.promise;const read=page.createRoute();
 page.active=false;page.activeChanged();page.routeScope='';page.accountChanged();
 assert.equal(page.visibleCourse,null);assert.deepEqual(page.selections,[]);assert.deepEqual(page.places,[]);
 pending.resolve(route('a','b'));await read;assert.equal(page.route,null);
});
test('a malformed refreshed source cannot be used to generate a route from stale choices',async()=>{
 const {page,hooks,calls}=setup();await page.loadPlaces();choosePair(page);
 hooks.campusData=async()=>data([places[0],places[0]]);await page.loadPlaces();assert.ok(page.placesError);
 await page.createRoute();assert.equal(calls.some(call=>call[0]==='route'),false);
});
// Actual production methods with offline transport doubles; no ArkUI/native rendering is asserted.
