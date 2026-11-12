import './helpers/theme-fixture.mjs';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripThemeTypeScriptTypes as strip } from './helpers/theme-fixture.mjs';
import { test } from 'node:test';
const read = path => readFileSync(new URL(`../entry/src/main/ets/${path}.ets`,import.meta.url),'utf8');
const clean = text => strip(text.replace(/^import [^\n]+;\r?\n/gm,'').replace(/^export /gm,''));
const normalize = new Function(clean(read('utils/SessionPersistence'))+'\nreturn normalizeServiceBaseUrl;')();
const helpers = new Function('normalizeServiceBaseUrl',clean(read('utils/RouteMapBridge'))+'\nreturn {routeMapUrl,trustedMapDocument,mapStateScript};')(normalize);
const source = read('components/RouteMap');
const controller=source.slice(0,source.indexOf('\n  build()')).replace(/^import [^\n]+;\r?\n/gm,'').replace(/^@Component\r?\n/gm,'')
 .replace(/@(State|Prop)\s+|@Watch\('[^']+'\)\s*/g,'').replace('export struct RouteMap','class RouteMap')+'\n}';
const managedUrl = base => `${base}/static/baidu-map.html?v=3&managed=1`;
const config = {browser_ak:'BROWSER_FIXTURE',configured:true,route_configured:true,city:'杭州',campus_query:'校区'};
function setup(fetchConfig=async()=>config){const calls=[],fetches=[],loads=[];let url=managedUrl('https://service');
 class Controller { getUrl(){return url;} loadUrl(next){loads.push(next);url=next;} runJavaScript(script){calls.push(script);return Promise.resolve('');} onActive(){} onInactive(){} }
 class Api { constructor(base,token){fetches.push([base,token]);} baiduMapConfig(){return fetchConfig();} }
 const mapConfigScript = new Function('normalizeServiceBaseUrl',clean(read('utils/RouteMapBridge'))+'\nreturn mapConfigScript;')(normalize);
 const Component=new Function('webview','CampusFlowApi','routeMapUrl','trustedMapDocument','mapStateScript','mapConfigScript',strip(controller)+'\nreturn RouteMap;')(
  {WebviewController:Controller},Api,helpers.routeMapUrl,helpers.trustedMapDocument,helpers.mapStateScript,mapConfigScript);
 const map=new Component();map.baseUrl='https://service';map.token='NATIVE_SECRET';map.active=true;map.aboutToAppear();
 return {map,calls,fetches,loads,navigate:next=>url=next};}
const lastState = calls => {let result;new Function('window',calls.at(-1))({CampusFlowMap:{setConfig:()=>{},setState:value=>result=value,clear:()=>result='clear'}});return result;};
test('map keeps latest props until trusted page finishes loading and pushes config before state without a token',async()=>{
 const {map,calls}=setup();map.origin={place_id:'a',name:'A',token:'SECRET'};map.stateChanged();assert.equal(calls.length,0);
 map.origin={place_id:'b',name:'B'};await map.pageFinished(managedUrl('https://service'));
 assert.equal(lastState(calls).origin.place_id,'b');assert.equal(calls.join('').includes('SECRET'),false);
 assert.ok(calls[0].indexOf('.setConfig(')<calls[0].indexOf('.setState('));assert.match(calls[0],/BROWSER_FIXTURE/);
});
test('hide and unmount clear the page while late load events cannot restore selection or route',async()=>{
 const {map,calls}=setup();await map.pageFinished(managedUrl('https://service'));map.active=false;map.stateChanged();
 assert.equal(lastState(calls).active,false);map.aboutToDisappear();const count=calls.length;
 await map.pageFinished(managedUrl('https://service'));assert.equal(calls.length,count);
});
test('service changes and arbitrary redirects cannot receive map data, and a new trusted document can',async()=>{
 const {map,calls,navigate,fetches}=setup();await map.pageFinished('https://evil/static/baidu-map.html');assert.equal(calls.length,0);
 navigate('https://evil/static/baidu-map.html');await map.pageFinished(managedUrl('https://service'));assert.equal(calls.length,0);assert.equal(fetches.length,0);
 map.baseUrl='https://new-service';map.sourceChanged();map.stateChanged();assert.equal(calls.length,0);
 navigate(managedUrl('https://new-service'));await map.pageFinished(managedUrl('https://new-service'));assert.equal(lastState(calls).active,true);
 assert.deepEqual(fetches,[['https://new-service','NATIVE_SECRET']]);
});
test('account replacement reloads the document and rejects a late browser key',async()=>{
 let resolve;
 const old=new Promise(done=>{resolve=done;});let requests=0;
 const {map,calls,loads}=setup(()=>requests++===0?old:Promise.resolve(config));
 const pending=map.pageFinished(managedUrl('https://service'));
 map.token='NEW_ACCOUNT';map.tokenChanged();
 assert.deepEqual(loads,[managedUrl('https://service')]);
 resolve({...config,browser_ak:'OLD_BROWSER_SECRET'});await pending;assert.equal(calls.length,0);
 await map.pageFinished(managedUrl('https://service'));assert.equal(lastState(calls).active,true);
 assert.doesNotMatch(calls.join(''),/OLD_BROWSER_SECRET|NEW_ACCOUNT/);
});
test('native Web container blocks top-level foreign navigation and disables file access',()=>{
 assert.match(source,/\.onLoadIntercept\(/);assert.match(source,/\.fileAccess\(false\)/);
 assert.doesNotMatch(source,/Image\(|Canvas\(|javaScriptProxy|Authorization|geolocationAccess\(true\)/);
});
