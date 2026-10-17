import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { test } from 'node:test';
const source=readFileSync(new URL('../entry/src/main/ets/pages/RoutePage.ets',import.meta.url),'utf8');
const controller=source.slice(0,source.indexOf('\n  @Builder')).replace(/^import [^\n]+;\r?\n/gm,'').replace(/^@Component\r?\n/gm,'')
 .replace(/@(State|Prop)\s+|@Watch\('[^']+'\)\s*/g,'').replace('export struct RoutePage','class RoutePage')+'\n}';
const create=new Function('CampusFlowApi','Scroller',stripTypeScriptTypes(controller)+'\nreturn RoutePage;');
const places=[{place_id:'a',name:'图书馆'},{place_id:'b',name:'食堂'},{place_id:'c',name:'操场'}];
const deferred=()=>{let resolve,reject;const promise=new Promise((a,b)=>{resolve=a;reject=b;});return {resolve,reject,promise};};
function setup(overrides={}){
 const calls=[];const hooks={campusData:async()=>({places,package:{}}),campusRoute:async(a,b)=>({origin:a,destination:b}),...overrides};
 class Api{campusData(){calls.push(['data']);return hooks.campusData();}campusRoute(...args){calls.push(['route',...args]);return hooks.campusRoute(...args);}}
 const Page=create(Api,class Scroller{});const page=new Page();page.baseUrl='https://fixture.invalid';page.token='account';return{page,calls,hooks};
}
test('places load gives distinct defaults and refresh preserves selection by place ID',async()=>{
 const {page,hooks}=setup();await page.loadPlaces();assert.equal(page.destinationIndex,1);
 page.choosePlace(2,false);hooks.campusData=async()=>({places:[places[2],places[0],places[1]],package:{}});await page.loadPlaces();
 assert.equal(page.places[page.originIndex].place_id,'a');assert.equal(page.places[page.destinationIndex].place_id,'c');
});
test('route request uses selected names and selection change rejects old route without changing new draft',async()=>{
 const pending=deferred();const {page,calls}=setup({campusRoute:()=>pending.promise});await page.loadPlaces();const read=page.createRoute();
 page.choosePlace(2,false);pending.resolve({destination:'食堂'});await read;
 assert.equal(page.route,null);assert.equal(page.destinationIndex,2);assert.equal(page.routeLoading,false);
 assert.deepEqual(calls[1],['route','图书馆','食堂']);
});
test('swap invalidates pending route and repeat taps do not dispatch duplicate calls',async()=>{
 const pending=deferred();const {page,calls}=setup({campusRoute:()=>pending.promise});await page.loadPlaces();const read=page.createRoute();await page.createRoute();
 assert.equal(calls.filter(x=>x[0]==='route').length,1);page.swap();pending.reject(Error('secret'));await read;
 assert.equal(page.errorText,'');assert.equal(page.originIndex,1);assert.equal(page.destinationIndex,0);
});
test('same origin, unavailable endpoints and invalid selections cannot request routes',async()=>{
 const {page,calls}=setup();await page.loadPlaces();page.choosePlace(0,false);await page.createRoute();assert.ok(page.errorText);
 page.choosePlace(-1,true);page.choosePlace(50,true);page.choosePlace(NaN,false);assert.equal(page.originIndex,0);
 assert.equal(calls.filter(x=>x[0]==='route').length,0);
});
test('hidden or disposed page rejects delayed private data and late failures',async()=>{
 for(const disappear of [false,true]){const pending=deferred();const {page}=setup({campusData:()=>pending.promise});const read=page.loadPlaces();
 if(disappear)page.aboutToDisappear();else{page.active=false;page.activeChanged();}
 pending.resolve({places});await read;assert.deepEqual(page.places,[]);assert.equal(page.loading,false);}
});
test('route failure preserves chosen places and can retry without exposing raw exception',async()=>{
 const {page,hooks}=setup({campusRoute:async()=>{throw Error('secret');}});await page.loadPlaces();page.choosePlace(2,false);await page.createRoute();
 assert.ok(page.errorText);assert.ok(!page.errorText.includes('secret'));assert.equal(page.destinationIndex,2);
 hooks.campusRoute=async()=>({destination:'操场'});await page.createRoute();assert.equal(page.route.destination,'操场');assert.equal(page.errorText,'');
});
