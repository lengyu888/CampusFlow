import { CampusDataPlace, CampusPlaceCandidate, CampusPlaceCandidates, CampusPlaceSelection } from '../model/ApiModels';
import { validCampusGeoPoint } from './RouteMapBridge';

export function validPlaceSelection(value: CampusPlaceSelection | null | undefined, placeId: string): boolean {
  return value !== null && value !== undefined && typeof value === 'object' && value.place_id === placeId &&
    typeof value.name === 'string' && value.name.trim().length > 0 && typeof value.address === 'string' &&
    typeof value.baidu_uid === 'string' && value.baidu_uid.length > 0 && validCampusGeoPoint(value.location) &&
    typeof value.confirmed_at === 'string' && Number.isFinite(Date.parse(value.confirmed_at));
}

export function validPlaceCandidate(value: CampusPlaceCandidate): boolean {
  return value !== null && typeof value === 'object' && typeof value.name === 'string' && value.name.trim().length > 0 &&
    typeof value.address === 'string' && typeof value.baidu_uid === 'string' && value.baidu_uid.length > 0 &&
    validCampusGeoPoint(value.location) && typeof value.selection_token === 'string' && value.selection_token.length > 0;
}

export function validPlaceCandidates(value: CampusPlaceCandidates, placeId: string, page: number): boolean {
  return value !== null && typeof value === 'object' && value.place_id === placeId && value.page === page &&
    typeof value.query === 'string' && value.page_size === 20 &&
    Number.isSafeInteger(value.total) && value.total >= 0 && typeof value.has_more === 'boolean' &&
    typeof value.truncated === 'boolean' && Array.isArray(value.candidates) && value.candidates.length <= 20 &&
    value.candidates.every((candidate: CampusPlaceCandidate) => validPlaceCandidate(candidate)) &&
    typeof value.expires_at === 'string' && Number.isFinite(Date.parse(value.expires_at)) && Date.parse(value.expires_at) > Date.now();
}

export function hasPlaceLocation(place: CampusDataPlace): boolean {
  return validCampusGeoPoint(place.location) || validPlaceSelection(place.selection, place.place_id);
}

function normalizedPlaceText(value: string): string {
  return value.trim().toLowerCase().replace(/[\s（）()·—\-]+/g, '');
}

export function matchesCampusPlace(place: CampusDataPlace, query: string): boolean {
  const terms = query.trim().split(/\s+/).map((term: string) => normalizedPlaceText(term));
  const label = normalizedPlaceText([place.name, ...place.aliases, place.zone].join(' '));
  return terms.every((term: string) => label.includes(term));
}

export function conflictingParcelBrand(place: CampusDataPlace, mapName: string): boolean {
  const label = normalizedPlaceText([place.name, ...place.aliases].join(' '));
  const candidate = normalizedPlaceText(mapName);
  const parcelTerms = /快递|驿站|物流|邮政|自提|丰巢|兔喜/;
  if (!parcelTerms.test(label) || !parcelTerms.test(candidate)) { return false; }
  const brands = ['菜鸟', '京东', '顺丰', '中通', '圆通', '申通', '韵达', '邮政', '极兔', '兔喜', '丰巢'];
  const expected = brands.filter((brand: string) => label.includes(brand));
  const actual = brands.filter((brand: string) => candidate.includes(brand));
  return expected.length > 0 && actual.length > 0 && !actual.some((brand: string) => expected.includes(brand));
}

// Candidate credentials remain in the private picker. Only public place data reaches the map.
export function candidatePreviewPlace(place: CampusDataPlace, candidate: CampusPlaceCandidate): CampusDataPlace {
  return { place_id: place.place_id, name: candidate.name, category: place.category, zone: place.zone,
    aliases: [], open_now: place.open_now, open_hours: place.open_hours,
    location: { lat: candidate.location.lat, lng: candidate.location.lng }, baidu_uid: candidate.baidu_uid, evidence: [] };
}
