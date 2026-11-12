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

// Candidate credentials remain in the private picker. Only public place data reaches the map.
export function candidatePreviewPlace(place: CampusDataPlace, candidate: CampusPlaceCandidate): CampusDataPlace {
  return { place_id: place.place_id, name: candidate.name, category: place.category, zone: place.zone,
    aliases: [], open_now: place.open_now, open_hours: place.open_hours,
    location: { lat: candidate.location.lat, lng: candidate.location.lng }, baidu_uid: candidate.baidu_uid, evidence: [] };
}
