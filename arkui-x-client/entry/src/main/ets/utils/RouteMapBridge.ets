import { BaiduMapConfig, CampusDataPlace, CampusGeoPoint, CampusRoute, CampusRouteStep, DataEvidence } from '../model/ApiModels';
import { normalizeServiceBaseUrl } from './SessionPersistence';

export interface RouteMapState {
  active: boolean;
  preview?: boolean;
  route: CampusRoute | null;
  origin: CampusDataPlace | null;
  destination: CampusDataPlace | null;
}

// Navigation caches are scoped to a campus; account history keeps its existing scope.
export function campusRouteScope(accountScope: string, school: string | null, campus: string | null): string {
  if (accountScope.length === 0 || school === null || campus === null || school.trim().length === 0 || campus.trim().length === 0) { return ''; }
  return JSON.stringify([accountScope, school, campus]);
}

// Keep aliases aligned with backend evidence.campus_supported. The shared map
// currently covers HDU Xiasha only; a different campus cannot use its defaults.
export function supportedMapCampus(school: string, campus: string): boolean {
  if (typeof school !== 'string' || typeof campus !== 'string') { return false; }
  const schoolKey = school.toLowerCase().replace(/\s/g, '');
  const campusKey = campus.toLowerCase().replace(/\s/g, '');
  return ['杭州电子科技大学', '杭电', 'hdu'].includes(schoolKey) && ['下沙校区', '下沙', 'xiasha'].includes(campusKey);
}

export function routeMapUrl(baseUrl: string): string {
  const base = normalizeServiceBaseUrl(baseUrl);
  return base === null ? '' : `${base}/static/baidu-map.html?v=6&managed=1`;
}

export function trustedMapDocument(url: string, baseUrl: string): boolean {
  const expected = routeMapUrl(baseUrl);
  return expected.length > 0 && url === expected;
}

export function validCampusGeoPoint(point: CampusGeoPoint | null | undefined): boolean {
  return point !== null && point !== undefined && typeof point.lat === 'number' && typeof point.lng === 'number' &&
    Number.isFinite(point.lat) && Number.isFinite(point.lng) && Math.abs(point.lat) <= 90 && Math.abs(point.lng) <= 180;
}

export function validBaiduRoute(route: CampusRoute | null): boolean {
  if (route === null || typeof route !== 'object') { return false; }
  return route.provider === 'baidu' && route.coordinate_system === 'bd09ll' && Array.isArray(route.path) && route.path.length === 0 &&
    Array.isArray(route.polyline) && route.polyline.length >= 2 && route.polyline.length <= 50000 &&
    route.polyline.every((point: CampusGeoPoint) => validCampusGeoPoint(point)) &&
    typeof route.distance_meters === 'number' && Number.isSafeInteger(route.distance_meters) && route.distance_meters >= 0 &&
    typeof route.duration_seconds === 'number' && Number.isSafeInteger(route.duration_seconds) && route.duration_seconds >= 0 &&
    route.total_minutes === Math.ceil(route.duration_seconds / 60) && route.estimated_distance_meters === route.distance_meters &&
    typeof route.queried_at === 'string' && /^\d{4}-\d{2}-\d{2}T/.test(route.queried_at) && Number.isFinite(Date.parse(route.queried_at)) &&
    typeof route.package_id === 'string' && typeof route.package_version === 'string' && typeof route.note === 'string' &&
    Array.isArray(route.steps) && route.steps.every((step: CampusRouteStep) => step !== null && typeof step === 'object' &&
      Number.isSafeInteger(step.index) && typeof step.instruction === 'string' && Number.isFinite(step.minutes) && step.minutes >= 0) &&
    route.origin !== null && typeof route.origin === 'object' && typeof route.origin.place_id === 'string' && typeof route.origin.name === 'string' &&
    route.destination !== null && typeof route.destination === 'object' && typeof route.destination.place_id === 'string' && typeof route.destination.name === 'string';
}

function mapEvidence(items: DataEvidence[] | undefined): DataEvidence[] {
  if (!Array.isArray(items)) { return []; }
  return items.filter((item: DataEvidence) => item !== null && typeof item === 'object').map((item: DataEvidence): DataEvidence => {
    return { source_id: typeof item.source_id === 'string' ? item.source_id : '',
      label: typeof item.label === 'string' ? item.label : '', kind: typeof item.kind === 'string' ? item.kind : '',
      status: typeof item.status === 'string' ? item.status : '',
      updated_at: typeof item.updated_at === 'string' ? item.updated_at : null,
      expires_at: typeof item.expires_at === 'string' ? item.expires_at : null,
      url: typeof item.url === 'string' ? item.url : null, note: typeof item.note === 'string' ? item.note : '' };
  });
}

function mapPlace(place: CampusDataPlace | null): CampusDataPlace | null {
  if (place === null || typeof place !== 'object' || typeof place.place_id !== 'string' || typeof place.name !== 'string') { return null; }
  return { place_id: place.place_id, name: place.name,
    category: typeof place.category === 'string' ? place.category : '', zone: typeof place.zone === 'string' ? place.zone : '',
    aliases: Array.isArray(place.aliases) ? place.aliases.filter((item: string) => typeof item === 'string') : [],
    open_now: typeof place.open_now === 'boolean' ? place.open_now : null,
    open_hours: typeof place.open_hours === 'string' ? place.open_hours : '', evidence: mapEvidence(place.evidence),
    location: validCampusGeoPoint(place.location) ? { lat: place.location!.lat, lng: place.location!.lng } : null,
    baidu_uid: typeof place.baidu_uid === 'string' ? place.baidu_uid : null };
}

function mapRoute(route: CampusRoute | null): CampusRoute | null {
  if (!validBaiduRoute(route) || route === null) { return null; }
  return { package_id: route.package_id, package_version: route.package_version,
    origin: mapPlace(route.origin) as CampusDataPlace, destination: mapPlace(route.destination) as CampusDataPlace,
    provider: 'baidu', coordinate_system: 'bd09ll',
    polyline: route.polyline!.map((point: CampusGeoPoint): CampusGeoPoint => { return { lat: point.lat, lng: point.lng }; }),
    distance_meters: route.distance_meters, duration_seconds: route.duration_seconds, queried_at: route.queried_at,
    total_minutes: route.total_minutes, estimated_distance_meters: route.estimated_distance_meters, path: [],
    steps: route.steps.map((step: CampusRouteStep): CampusRouteStep => { return { index: step.index, instruction: step.instruction, minutes: step.minutes }; }),
    note: route.note, is_estimate: route.is_estimate === true, evidence: mapEvidence(route.evidence) };
}

// An explicit projection keeps authentication or unknown API fields out of the Web document.
export function mapStateScript(state: RouteMapState): string {
  const value: RouteMapState = { active: state.active, route: state.active ? mapRoute(state.route) : null,
    origin: state.active ? mapPlace(state.origin) : null, destination: state.active ? mapPlace(state.destination) : null };
  if (state.active && state.preview === true) { value.preview = true; }
  const json = JSON.stringify(value).replace(/\u2028/g, '\\u2028').replace(/\u2029/g, '\\u2029');
  return `if(window.CampusFlowMap){window.CampusFlowMap.setState(${json});}`;
}

export function mapConfigScript(config: BaiduMapConfig): string {
  const value: BaiduMapConfig = {
    configured: config?.configured === true,
    browser_ak: typeof config?.browser_ak === 'string' ? config.browser_ak : '',
    route_configured: config?.route_configured === true,
    campus_query: typeof config?.campus_query === 'string' ? config.campus_query : '',
    city: typeof config?.city === 'string' ? config.city : ''
  };
  const json = JSON.stringify(value).replace(/\u2028/g, '\\u2028').replace(/\u2029/g, '\\u2029');
  return `if(window.CampusFlowMap?.setConfig){window.CampusFlowMap.setConfig(${json});}`;
}
