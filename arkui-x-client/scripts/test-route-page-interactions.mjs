import './helpers/theme-fixture.mjs';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripThemeTypeScriptTypes as stripTypeScriptTypes } from './helpers/theme-fixture.mjs';
import { test } from 'node:test';
const source=readFileSync(new URL('../entry/src/main/ets/pages/RoutePage.ets',import.meta.url),'utf8');
const controller=source.slice(0,source.indexOf('\n  @Builder')).replace(/^import [^\n]+;\r?\n/gm,'').replace(/^@Component\r?\n/gm,'')
 .replace(/@(State|Prop)\s+|@Watch\('[^']+'\)\s*/g,'').replace('export struct RoutePage','class RoutePage')+'\n}';
const matcher=readFileSync(new URL('../entry/src/main/ets/utils/CourseRouteIntent.ets',import.meta.url),'utf8').replace(/^import [^\n]+;\r?\n/gm,'');
const bridgeSource=readFileSync(new URL('../entry/src/main/ets/utils/RouteMapBridge.ets',import.meta.url),'utf8').replace(/^import [^\n]+;\r?\n/gm,'').replace(/^export /gm,'');
const {validBaiduRoute,supportedMapCampus,validCampusGeoPoint}=new Function(stripTypeScriptTypes(bridgeSource)+'\nreturn {validBaiduRoute,supportedMapCampus,validCampusGeoPoint};')();
const matchCoursePlace=new Function('supportedMapCampus',stripTypeScriptTypes(matcher.replace(/^export /gm,''))+'\nreturn matchCoursePlace;')(supportedMapCampus);
const selectionSource=readFileSync(new URL('../entry/src/main/ets/utils/CampusPlaceSelection.ets',import.meta.url),'utf8').replace(/^import [^\n]+;\r?\n/gm,'').replace(/^export /gm,'');
const selectionHelpers=new Function('validCampusGeoPoint',stripTypeScriptTypes(selectionSource)+'\nreturn {candidatePreviewPlace,conflictingParcelBrand,hasPlaceLocation,matchesCampusPlace,validPlaceCandidates,validPlaceSelection};')(validCampusGeoPoint);
const feedbackSource=readFileSync(new URL('../entry/src/main/ets/utils/AgentFeedback.ets',import.meta.url),'utf8').replace(/^import [^\n]+;\r?\n/gm,'');
const {CampusFlowRequestError,requestFailure}=await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(feedbackSource)).toString('base64')}`);
const createPage=new Function('CampusFlowApi','Scroller','Edge','matchCoursePlace','validBaiduRoute','supportedMapCampus','CampusFlowRequestError','requestFailure',...Object.keys(selectionHelpers),stripTypeScriptTypes(controller)+'\nreturn RoutePage;');
const create=(api,scroller,match)=>createPage(api,scroller,{Top:0},match,validBaiduRoute,supportedMapCampus,CampusFlowRequestError,requestFailure,...Object.values(selectionHelpers));
const places=[{place_id:'a',name:'图书馆',aliases:['校图书馆'],zone:'教学区',location:{lat:30.31,lng:120.31}},
 {place_id:'b',name:'第7教研楼（信博楼）',aliases:['7教','第七教研楼'],zone:'教学区',location:{lat:30.32,lng:120.32}},
 {place_id:'c',name:'操场',aliases:['东操场'],zone:'教学区',location:{lat:30.33,lng:120.33}}];
const data=(rows=places)=>({places:rows,package:{package_id:'hdu-xiasha',version:'fixture',school:'杭州电子科技大学',campus:'下沙校区',evidence:[]}});
const route=(a,b)=>({package_id:'hdu-xiasha',package_version:'fixture',origin:places.find(x=>x.place_id===a),destination:places.find(x=>x.place_id===b),path:[],steps:[],
 provider:'baidu',coordinate_system:'bd09ll',polyline:[{lat:30.3,lng:120.3},{lat:30.4,lng:120.4}],distance_meters:123,duration_seconds:121,
 total_minutes:3,estimated_distance_meters:123,queried_at:'2026-11-05T00:00:00Z',note:'百度步行路线'});
const intent=(location,requestId=1)=>({requestId,school:'杭州电子科技大学',campus:'下沙校区',timetableRevision:'a'.repeat(64),evidence:[],
 course:{date:'2026-10-19',title:'同名课程',start_time:'08:00',end_time:'09:40',location,teacher:'教师'}});
const tick=()=>new Promise(resolve=>setImmediate(resolve));
const candidate=(n=1)=>({name:`图书馆入口${n}`,address:`校园路${n}号`,baidu_uid:`uid-${n}`,location:{lat:30.31+n/1000,lng:120.31},selection_token:`private-${n}`});
const candidatePage=(id='a',page=0,query='图书馆')=>({place_id:id,query,page,page_size:20,total:21,has_more:page===0,truncated:false,candidates:[candidate(page+1)],expires_at:'2099-01-01T00:00:00Z'});
const selection=(id='a')=>({place_id:id,name:candidate().name,address:candidate().address,baidu_uid:candidate().baidu_uid,location:candidate().location,confirmed_at:'2026-11-08T00:00:00Z'});
function choosePair(page){page.choosePlace(0,true);page.choosePlace(1,false);}
const deferred=()=>{let resolve,reject;const promise=new Promise((a,b)=>{resolve=a;reject=b;});return {resolve,reject,promise};};
function setup(overrides={}){
 const calls=[];const hooks={campusData:async()=>data(),campusRoute:async(a,b)=>route(a,b),campusPlaceCandidates:async(id,page,query)=>candidatePage(id,page,query),confirmCampusPlaceSelection:async(id)=>selection(id),...overrides};
 class Api{campusData(){calls.push(['data']);return hooks.campusData();}campusRoute(...args){calls.push(['route',...args]);return hooks.campusRoute(...args);}campusPlaceCandidates(...args){calls.push(['candidates',...args]);return hooks.campusPlaceCandidates(...args);}confirmCampusPlaceSelection(...args){calls.push(['confirm',...args]);return hooks.confirmCampusPlaceSelection(...args);}}
 const Page=create(Api,class Scroller{scrollEdge(){}},matchCoursePlace);const page=new Page();page.baseUrl='https://fixture.invalid';page.token='account';
 page.school='杭州电子科技大学';page.campus='下沙校区';
 page.routeScope='fixture-account';page.accountChanged();page.applyContext();return{page,calls,hooks};
}
test('places load does not presume a current location and refresh preserves explicit choices by ID',async()=>{
 const {page,hooks,calls}=setup();await page.loadPlaces();assert.equal(page.destinationIndex,-1);assert.equal(page.originIndex,-1);
 await page.createRoute();assert.equal(calls.some(call=>call[0]==='route'),false);
 page.choosePlace(0,true);page.choosePlace(2,false);hooks.campusData=async()=>data([places[2],places[0],places[1]]);await page.loadPlaces();
 assert.equal(page.places[page.originIndex].place_id,'a');assert.equal(page.places[page.destinationIndex].place_id,'c');
});
test('campus labels use the display alias while entrance search still sends the full POI name',async()=>{
 const library={...places[0],name:'杭州电子科技大学(高教园校区)-图书馆',aliases:['图书馆','校图书馆']};
 const track={...places[2],aliases:[]};
 const {page,calls}=setup({campusData:async()=>data([library,places[1],track])});
 await page.loadPlaces();choosePair(page);
 assert.deepEqual(page.places.map(place=>page.placeLabel(place)),['图书馆','7教','操场']);
 await page.openPlacePicker(true);
 assert.equal(page.candidateQuery,library.name);
 assert.deepEqual(calls.find(call=>call[0]==='candidates'),['candidates','a',0,library.name]);
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
test('native map is shown before calculating a route and accepts current service and explicit endpoints',()=>{
 const map=source.indexOf('RouteMap({');const details=source.indexOf('this.RouteDetails()',map);
 assert.ok(map>=0&&map<details);assert.match(source.slice(map,map+350),/baseUrl: this.baseUrl/);
 const mapBranch=source.slice(source.indexOf('\n  build()'),map);
 assert.match(mapBranch,/if \(this\.choosingEndpoint\.length === 0 && \(this\.candidateEndpoint\.length === 0 \|\| this\.selectedCandidateIndex >= 0\)\)/);
 assert.match(mapBranch,/地图预览 · 尚未生成路线/);
 assert.match(source.slice(map,map+700),/origin: [\s\S]+?this.previewPlace\(this.places\[this.originIndex\]/);
 assert.match(source.slice(map,map+700),/destination: [\s\S]+?this.previewPlace\(this.places\[this.destinationIndex\]/);
});
test('hidden and disposed pages clear already displayed routes while preserving manual choices',async()=>{
 for(const disappear of [false,true]){const {page}=setup();await page.loadPlaces();choosePair(page);await page.createRoute();assert.ok(page.route);
 if(disappear)page.aboutToDisappear();else{page.active=false;page.activeChanged();}
 assert.equal(page.route,null);assert.equal(page.originIndex,0);assert.equal(page.destinationIndex,1);}
});
test('new requests reject reference and malformed coordinate routes without silently using image geometry',async()=>{
 for(const extra of [{provider:'reference'},{polyline:[]},{coordinate_system:'image'},{polyline:[{lat:Infinity,lng:120},{lat:30,lng:120}]}]){
 const {page}=setup({campusRoute:async(a,b)=>({...route(a,b),...extra})});await page.loadPlaces();choosePair(page);await page.createRoute();
 assert.equal(page.route,null);assert.ok(page.errorText);}
});
test('map setup and location errors explain the retry action without displaying upstream text',async()=>{
 const {page}=setup({campusRoute:async()=>{throw new CampusFlowRequestError(503,'MAP_NOT_CONFIGURED','SECRET');}});
 await page.loadPlaces();choosePair(page);await page.createRoute();assert.match(page.errorText,/尚未配置/);assert.doesNotMatch(page.errorText,/SECRET/);
});
test('map activation waits for current campus data, and unsupported campus never displays the public default map',async()=>{
 const pending=deferred();const {page}=setup({campusData:()=>pending.promise});
 const read=page.loadPlaces();assert.equal(page.mapActive(),false);pending.reject(Error('404 unsupported'));await read;
 assert.equal(page.mapActive(),false);assert.equal(page.snapshot,null);assert.equal(page.placesLoaded,false);
});
test('profile campus props immediately disqualify an old snapshot even before scope watcher runs',async()=>{
 const {page,hooks}=setup();await page.loadPlaces();choosePair(page);await page.createRoute();assert.equal(page.mapActive(),true);
 page.campus='临安校区';assert.equal(page.mapActive(),false);
 const pending=deferred();hooks.campusData=()=>pending.promise;page.routeScope='same-account-new-campus';page.accountChanged();const read=page.loadPlaces();
 assert.equal(page.snapshot,null);assert.equal(page.route,null);assert.deepEqual(page.places,[]);
 pending.resolve(data());await read;assert.equal(page.mapActive(),false);assert.equal(page.snapshot,null);assert.ok(page.placesError);
});
test('a failed campus refresh removes cached map eligibility and invalidates old route',async()=>{
 const {page,hooks}=setup();await page.loadPlaces();choosePair(page);await page.createRoute();assert.equal(page.mapActive(),true);
 hooks.campusData=async()=>{throw Error('404');};await page.loadPlaces();
 assert.equal(page.mapActive(),false);assert.equal(page.snapshot,null);assert.equal(page.route,null);assert.equal(page.placesLoaded,false);
});
test('late campus response cannot restore map after school changes within the same account',async()=>{
 const pending=deferred();const {page}=setup({campusData:()=>pending.promise});const read=page.loadPlaces();
 page.school='另一学校';page.accountChanged();pending.resolve(data());await read;
 assert.equal(page.mapActive(),false);assert.equal(page.snapshot,null);assert.deepEqual(page.places,[]);
});
test('supported profile aliases accept canonical campus data without admitting another campus',async()=>{
 for(const [school,campus] of [['杭电','下沙'],[' HDU ',' Xiasha '],['杭州电子科技大学','下沙校区']]){
 const {page}=setup();page.school=school;page.campus=campus;page.accountChanged();await page.loadPlaces();
 assert.equal(page.mapActive(),true,`${school}/${campus}`);assert.equal(page.placesError,'');}
 for(const [school,campus] of [['其他大学','下沙'],['杭电','临安校区']]){
 const {page}=setup();page.school=school;page.campus=campus;page.accountChanged();await page.loadPlaces();assert.equal(page.mapActive(),false);}
});

test('candidate choice previews only; explicit confirmation refreshes user snapshot and preserves endpoint IDs',async()=>{
 const {page,hooks,calls}=setup();await page.loadPlaces();choosePair(page);await page.openPlacePicker(true);
 assert.equal(page.selectedCandidateIndex,-1);assert.equal(calls.filter(x=>x[0]==='confirm').length,0);
 page.previewCandidate(0);const preview=page.previewPlace(page.places[page.originIndex],true);
 assert.equal(preview.location.lat,candidate().location.lat);assert.equal(preview.name,candidate().name);
 assert.equal(JSON.stringify(preview).includes('private-'),false);assert.equal(page.places[0].selection,undefined);
 hooks.campusData=async()=>data([{...places[2]},{...places[1]},{...places[0],selection:selection(),location:selection().location}]);
 await page.confirmCandidate();assert.deepEqual(calls.find(x=>x[0]==='confirm'),['confirm','a','private-1']);
 assert.equal(page.places[page.originIndex].place_id,'a');assert.equal(page.places[page.destinationIndex].place_id,'b');
 assert.equal(page.places[page.originIndex].selection.baidu_uid,'uid-1');assert.equal(page.candidates.length,0);
 assert.equal(page.candidateEndpoint,'');assert.match(page.placeSelectionStatus(page.places[page.originIndex]),/已确认/);
});

test('unconfirmed endpoints open the picker before route dispatch while globally configured locations remain reusable',async()=>{
 const {page,calls}=setup({campusData:async()=>data(places.map(p=>({...p,location:null})))});await page.loadPlaces();choosePair(page);await page.createRoute();
 assert.equal(calls.some(x=>x[0]==='route'),false);assert.equal(page.candidateEndpoint,'origin');assert.equal(page.selectedCandidateIndex,-1);
});

test('candidate paging is user triggered and an empty page with more results is not treated as final',async()=>{
 const {page,calls,hooks}=setup({campusPlaceCandidates:async(id,p,q)=>({...candidatePage(id,p,q),candidates:p===0?[]:[candidate(2)]})});
 await page.loadPlaces();choosePair(page);await page.openPlacePicker(false);assert.equal(page.candidates.length,0);assert.equal(page.candidateHasMore,true);
 assert.equal(calls.filter(x=>x[0]==='candidates').length,1);await page.loadCandidates(true);assert.equal(page.candidates.length,1);assert.equal(page.candidatePage,1);
 page.previewCandidate(0);page.candidateQueryChanged('新入口');assert.equal(page.candidates.length,0);assert.equal(page.selectedCandidateIndex,-1);
 hooks.campusPlaceCandidates=async(id,p,q)=>candidatePage(id,p,q);await page.loadCandidates(false);assert.equal(page.candidatePage,0);
 assert.deepEqual(calls.at(-1),['candidates','b',0,'新入口']);
});

test('query, endpoint, context, account and hiding invalidate late candidate pages and confirmations',async()=>{
 for(const change of [p=>p.candidateQueryChanged('新查询'),p=>p.choosePlace(2,false),p=>{p.routeContextKey='new';p.contextChanged();},p=>{p.token='new';p.accountChanged();},p=>{p.baseUrl='https://new.invalid';p.accountChanged();},p=>{p.campus='临安校区';p.accountChanged();},p=>{p.active=false;p.activeChanged();},p=>p.aboutToDisappear()]){
 const pending=deferred();const {page}=setup({campusPlaceCandidates:()=>pending.promise});await page.loadPlaces();choosePair(page);const read=page.openPlacePicker(true);change(page);
 pending.resolve(candidatePage());await read;assert.deepEqual(page.candidates,[]);assert.equal(page.candidateLoading,false);
 }
 for(const change of [p=>p.choosePlace(2,false),p=>{p.active=false;p.activeChanged();},p=>{p.token='new';p.accountChanged();}]){
 const pending=deferred();const {page,calls}=setup({confirmCampusPlaceSelection:()=>pending.promise});await page.loadPlaces();choosePair(page);await page.openPlacePicker(true);page.previewCandidate(0);
 const save=page.confirmCandidate();change(page);await tick();const before=calls.filter(x=>x[0]==='data').length;pending.resolve(selection());await save;
 assert.equal(calls.filter(x=>x[0]==='data').length,before + (page.active ? 1 : 0));
 assert.equal(page.candidateSaving,false);assert.equal(page.candidates.length,0);
 }
});

test('malformed and expired candidates cannot preview or persist and failed searches can retry safely',async()=>{
 const {page,hooks,calls}=setup({campusPlaceCandidates:async(id,p,q)=>({...candidatePage(id,p,q),candidates:[{...candidate(),location:{lat:Infinity,lng:120}}]})});
 await page.loadPlaces();choosePair(page);await page.openPlacePicker(true);assert.equal(page.candidates.length,0);assert.ok(page.candidateError);
 hooks.campusPlaceCandidates=async(id,p,q)=>candidatePage(id,p,q);await page.loadCandidates(false);page.previewCandidate(0);page.candidateExpiresAt='2000-01-01T00:00:00Z';await page.confirmCandidate();
 assert.equal(calls.some(x=>x[0]==='confirm'),false);assert.match(page.candidateError,/过期/);assert.equal(page.candidates.length,0);
 hooks.campusPlaceCandidates=async()=>{throw new CampusFlowRequestError(503,'MAP_NOT_CONFIGURED','SECRET');};await page.loadCandidates(false);
 assert.match(page.candidateError,/尚未配置/);assert.doesNotMatch(page.candidateError,/SECRET/);
 hooks.campusPlaceCandidates=async(id,p,q)=>candidatePage(id,p,q);await page.loadCandidates(false);assert.equal(page.candidates.length,1);
});

test('loading more retains the earliest credential expiry across every displayed page',async()=>{
 const {page}=setup({campusPlaceCandidates:async(id,p,q)=>({...candidatePage(id,p,q),expires_at:p===0?'2098-01-01T00:00:00Z':'2099-01-01T00:00:00Z'})});
 await page.loadPlaces();choosePair(page);await page.openPlacePicker(true);await page.loadCandidates(true);
 assert.equal(page.candidateExpiresAt,'2098-01-01T00:00:00Z');
});

test('changed credentials immediately block route dispatch before the account watcher has run',async()=>{
 const {page,calls}=setup();await page.loadPlaces();choosePair(page);page.token='new-account-token';await page.createRoute();
 assert.equal(calls.some(x=>x[0]==='route'),false);
});

test('short custom searches accept the server effective campus-prefixed query',async()=>{
 const {page,hooks}=setup();await page.loadPlaces();choosePair(page);await page.openPlacePicker(true);page.candidateQueryChanged('图书馆北门');
 hooks.campusPlaceCandidates=async(id,p,q)=>({...candidatePage(id,p,q),query:`杭州电子科技大学 下沙校区 ${q}`});
 await page.loadCandidates(false);assert.equal(page.candidates.length,1);assert.equal(page.candidateError,'');
});

test('failed pagination preserves the first page expiry and permits confirming a displayed candidate',async()=>{
 const {page,calls}=setup({campusPlaceCandidates:async(id,p,q)=>{
   if(p>0)throw Error('offline');
   return candidatePage(id,p,q);
 }});
 await page.loadPlaces();choosePair(page);await page.openPlacePicker(true);
 const expiry=page.candidateExpiresAt;
 await page.loadCandidates(true);
 assert.equal(page.candidates.length,1);assert.equal(page.candidateExpiresAt,expiry);
 assert.match(page.candidatePageError,/暂时无法读取/);
 page.previewCandidate(0);await page.confirmCandidate();
 assert.deepEqual(calls.find(x=>x[0]==='confirm'),['confirm','a','private-1']);
});

test('closing a saving picker blocks more writes and routes until its result has been re-read',async()=>{
 const pending=deferred();
 const {page,calls,hooks}=setup({confirmCampusPlaceSelection:()=>pending.promise});
 await page.loadPlaces();choosePair(page);await page.openPlacePicker(true);page.previewCandidate(0);
 const saving=page.confirmCandidate();
 page.closePlacePicker();page.choosePlace(2,false);
 assert.equal(page.candidateSaving,true);
 await page.openPlacePicker(true);await page.confirmCandidate();await page.createRoute();
 assert.equal(calls.filter(x=>x[0]==='candidates').length,1);
 assert.equal(calls.filter(x=>x[0]==='confirm').length,1);
 assert.equal(calls.some(x=>x[0]==='route'),false);
 hooks.campusData=async()=>data([{...places[0],selection:selection(),location:selection().location},places[1],places[2]]);
 pending.resolve(selection());await saving;
 assert.equal(page.candidateSaving,false);assert.equal(page.places[page.originIndex].selection.baidu_uid,'uid-1');
 await page.createRoute();
 assert.deepEqual(calls.find(x=>x[0]==='route'),['route','a','c']);
});

test('native route summary discloses provider walking instructions when present',()=>{
 const {page}=setup();
 assert.equal(page.walkingInstructions([{index:1,instruction:'向北步行',minutes:2},{index:2,instruction:'右转',minutes:0}]),
  '1. 向北步行（约 2 分钟）\n2. 右转');
 assert.match(source,/if \(this\.route\.steps\.length > 0\)\s*\{\s*InfoDisclosure\(\{ title: '分段步行指引', message: this\.walkingInstructions\(this\.route\.steps\)/);
});

test('endpoint search accepts aliases and areas and excludes the opposite endpoint', async () => {
 const {page}=setup();
 await page.loadPlaces();
 page.choosePlace(1,false);
 page.openEndpointList(true);
 page.placeQuery='校图书馆 教学区';
 assert.deepEqual(page.matchingPlaces().map(place=>place.place_id),['a']);
 page.placeQuery='7教';
 assert.deepEqual(page.matchingPlaces(),[]);
 page.backPressed();
 assert.equal(page.choosingEndpoint,'');
 assert.equal(page.destinationIndex,1);
});

test('the text input echoing the preset keyword does not cancel the first candidate search', async () => {
 const pending=deferred();
 const {page}=setup({campusPlaceCandidates:()=>pending.promise});
 await page.loadPlaces();choosePair(page);
 const read=page.openPlacePicker(true);
 page.candidateQueryChanged(page.candidateQuery);
 assert.equal(page.candidateLoading,true);
 pending.resolve(candidatePage());await read;
 assert.equal(page.candidates.length,1);
});

test('parcel brand conflicts need explicit acknowledgment for new and saved entrances', async () => {
 const differentBrand={...candidate(),name:'京东快递（学源街店）'};
 const stored={...selection('c'),name:differentBrand.name};
 const station={...places[2],name:'菜鸟驿站',aliases:['快递驿站'],location:stored.location,selection:stored};
 const {page,calls}=setup({campusData:async()=>data([places[0],places[1],station]),
   campusPlaceCandidates:async(id,p,q)=>({...candidatePage(id,p,q),candidates:[differentBrand]}),
   confirmCampusPlaceSelection:async()=>stored});
 await page.loadPlaces();
 page.choosePlace(0,true);
 page.choosePlace(2,false);
 await page.createRoute();
 assert.equal(calls.some(call=>call[0]==='route'),false);
 assert.equal(page.routeActionLabel(),'按已保存入口规划');
 await page.performRouteAction();
 assert.equal(calls.filter(call=>call[0]==='route').length,1);
 assert.ok(page.route);
 assert.equal(page.routeFormExpanded,false);

 await page.openPlacePicker(false);
 page.previewCandidate(0);
 await page.confirmCandidate();
 assert.equal(calls.some(call=>call[0]==='confirm'),false);
 page.candidateAcknowledged=true;
 page.backPressed();
 page.previewCandidate(0);
 assert.equal(page.candidateAcknowledged,false);
 page.candidateAcknowledged=true;
 await page.confirmCandidate();
 assert.deepEqual(calls.find(call=>call[0]==='confirm'),['confirm','c','private-1']);
 assert.equal(selectionHelpers.conflictingParcelBrand(places[1],'信博楼东门'),false);
});
