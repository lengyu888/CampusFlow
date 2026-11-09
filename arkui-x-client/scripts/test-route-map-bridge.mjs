import './helpers/theme-fixture.mjs';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripThemeTypeScriptTypes as strip } from './helpers/theme-fixture.mjs';
import { test } from 'node:test';
const read = name => readFileSync(new URL(`../entry/src/main/ets/${name}.ets`, import.meta.url), 'utf8');
const clean = text => strip(text.replace(/^import [^\n]+;\r?\n/gm, '').replace(/^export /gm, ''));
const normalize = new Function(clean(read('utils/SessionPersistence')) + '\nreturn normalizeServiceBaseUrl;')();
const bridge = new Function('normalizeServiceBaseUrl', clean(read('utils/RouteMapBridge')) +
  '\nreturn { routeMapUrl, trustedMapDocument, validBaiduRoute, mapStateScript, mapConfigScript, campusRouteScope };')(normalize);
const place = id => ({ place_id:id, name:`地点${id}`, category:'教学',zone:'教学区',aliases:[],open_now:null,open_hours:'',location:{lat:30.3,lng:120.3} });
const route = () => ({ package_id:'hdu', package_version:'v1',origin:place('a'),destination:place('b'),provider:'baidu',
  coordinate_system:'bd09ll',polyline:[{lat:30.3,lng:120.3},{lat:30.4,lng:120.4}],distance_meters:123,duration_seconds:121,
  queried_at:'2026-11-05T00:00:00Z',total_minutes:3,estimated_distance_meters:123,path:[],steps:[],note:'百度步行',is_estimate:true });
test('map document URL comes only from normalized current service, never credentials or arbitrary navigation', () => {
  assert.equal(bridge.routeMapUrl('HTTP://127.0.0.1:8000/'), 'http://127.0.0.1:8000/static/baidu-map.html?v=3&managed=1');
  for(const value of ['javascript:alert(1)','https://u:p@host','https://host/?token=x','https://host/#x','https://host/../x']) assert.equal(bridge.routeMapUrl(value),'');
  const url=bridge.routeMapUrl('https://host/prefix');
  assert.equal(bridge.trustedMapDocument(url,'https://host/prefix'),true);
  for(const other of [url+'&x',url+'#x','https://host/prefix/static/baidu-map.html','https://other/static/baidu-map.html?v=2','https://host/static/baidu-map.html?v=2']) assert.equal(bridge.trustedMapDocument(other,'https://host/prefix'),false);
});
test('map config bridge passes only browser configuration as inert data', () => {
  const config={configured:true,browser_ak:"abc'); window.hacked(); //",route_configured:true,campus_query:'校区',city:'杭州'};
  let result;let hacked=false;
  const script=bridge.mapConfigScript({...config,server_ak:'SERVER_SECRET',token:'ACCESS_SECRET'});
  new Function('window',script)({hacked:()=>hacked=true,CampusFlowMap:{setConfig:value=>result=value}});
  assert.deepEqual(result,config);assert.equal(hacked,false);assert.doesNotMatch(script,/SERVER_SECRET|ACCESS_SECRET/);
});
test('real route validation rejects image routes, malformed paths, impossible coordinates and inconsistent units', () => {
  assert.equal(bridge.validBaiduRoute(route()),true);
  for(const extra of [{provider:'reference'},{coordinate_system:'image'},{path:[{x:30,y:120}]},{polyline:[]},
    {polyline:[{lat:91,lng:120},{lat:30,lng:120}]},{polyline:[{lat:30,lng:Infinity},{lat:30,lng:120}]},
    {distance_meters:null},{duration_seconds:-1},{duration_seconds:1.5},{total_minutes:121},{estimated_distance_meters:1},
    {queried_at:null},{queried_at:'bad'}]) assert.equal(bridge.validBaiduRoute({...route(),...extra}),false,JSON.stringify(extra));
});
test('bridge transports only a whitelisted data projection, and hides all route/selection data when inactive', () => {
  const state={active:true,route:{...route(),token:'SECRET'},origin:{...place('a'),token:'SECRET'},destination:place('b')};
  let received;
  new Function('window',bridge.mapStateScript(state))({CampusFlowMap:{setState:value=>received=value}});
  assert.equal(received.route.polyline.length,2);assert.deepEqual(received.route.path,[]);assert.equal(JSON.stringify(received).includes('SECRET'),false);
  new Function('window',bridge.mapStateScript({...state,active:false}))({CampusFlowMap:{setState:value=>received=value}});
  assert.deepEqual(received,{active:false,route:null,origin:null,destination:null});
});
test('bridge rejects legacy routes and quote-like input remains inert serialized data', () => {
  let received;let called=false;
  const origin={...place('a'),name:"'); window.hacked(); //"};
  new Function('window',bridge.mapStateScript({active:true,route:{...route(),provider:'reference'},origin,destination:null}))({hacked:()=>called=true,CampusFlowMap:{setState:value=>received=value}});
  assert.equal(called,false);assert.equal(received.route,null);assert.equal(received.origin.name,origin.name);
});
test('malformed route steps and labels never reach the Web serializer or throw during updates',()=>{
  for(const extra of [{steps:null},{steps:[null]},{steps:[{index:1,instruction:{token:'SECRET'},minutes:1}]},
    {origin:{place_id:'a'}},{note:{token:'SECRET'}}]) {
    const value={...route(),...extra};assert.equal(bridge.validBaiduRoute(value),false);
    assert.doesNotThrow(()=>bridge.mapStateScript({active:true,route:value,origin:null,destination:null}));
  }
});
test('campus route scope includes school and campus without changing account history scope',()=>{
 const account='https://service|same-user';const scope=bridge.campusRouteScope(account,'杭州电子科技大学','下沙校区');
 assert.ok(scope);assert.notEqual(scope,bridge.campusRouteScope(account,'杭州电子科技大学','临安校区'));
 assert.notEqual(scope,bridge.campusRouteScope(account,'其他学校','下沙校区'));
 for(const [school,campus] of [[null,'下沙校区'],['杭州电子科技大学',null],['','下沙校区']]) assert.equal(bridge.campusRouteScope(account,school,campus),'');
 const index=read('pages/Index');const block=index.slice(index.indexOf('RoutePage({'),index.indexOf('CampusServicesPage({'));
 const expression=/routeScope: ([^\n]+)/.exec(block)[1].trim().replace(/,$/,'');
 const binding=new Function('campusRouteScope','historyScope',`return ${expression};`);
 const view={token:'fixture',baseUrl:'https://service',serviceBaseUrl:()=> 'https://service',user:{user_id:'same-user',school:'杭州电子科技大学',campus:'下沙校区'}};
 const historyScope=()=>account;const before=binding.call(view,bridge.campusRouteScope,historyScope);
 view.user={...view.user,campus:'临安校区'};
 assert.notEqual(binding.call(view,bridge.campusRouteScope,historyScope),before);
});
