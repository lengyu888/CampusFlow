import { CampusDataPlace, CampusDataSnapshot, DataEvidence, TimetableEntry } from '../model/ApiModels';

export interface CourseRouteIntent {
  requestId: number;
  school: string;
  campus: string;
  course: TimetableEntry;
  timetableRevision: string;
  evidence: DataEvidence[];
}

export interface CoursePlaceMatch {
  status: string;
  candidateIds: string[];
  originalLocation: string;
  matchedLabel: string;
  remainingRoomText: string;
}

function normalized(value: string): string {
  return value.trim().toLowerCase().replace(/[\s\u3000]/g, '').replace(/（/g, '(').replace(/）/g, ')');
}

function placeLabels(place: CampusDataPlace): string[] {
  const names = [place.name, ...place.aliases];
  const main = place.name.split('（')[0].split('(')[0];
  if (main.length > 0) { names.push(main); }
  return names.map((name: string) => normalized(name)).filter((name: string) => name.length > 0);
}

function roomSuffix(value: string): boolean {
  return /^[东西南北]?(?:楼)?[0-9]{1,4}(?:[-—–至][0-9]{1,4})?(?:教室|室)?$/.test(value);
}

export function matchCoursePlace(intent: CourseRouteIntent, data: CampusDataSnapshot): CoursePlaceMatch {
  const result: CoursePlaceMatch = { status: 'missing', candidateIds: [], originalLocation: intent.course.location,
    matchedLabel: '', remainingRoomText: '' };
  const school = normalized(intent.school); const campus = normalized(intent.campus);
  if (school.length === 0 || campus.length === 0 || school !== normalized(data.package.school) || campus !== normalized(data.package.campus)) {
    result.status = 'unsupported'; return result;
  }
  let location = normalized(intent.course.location);
  if (location.length === 0) { return result; }
  // The selected campus package owns its full map labels, including Baidu's campus wording.
  // Match those labels before removing school prefixes from legacy course descriptions.
  const named = data.places.filter((place: CampusDataPlace) => [place.name, ...place.aliases]
    .some((name: string) => normalized(name).length > 0 && (location === normalized(name) ||
      location.startsWith(normalized(name)) && roomSuffix(location.substring(normalized(name).length)))));
  if (named.length > 0) {
    result.candidateIds = named.map((place: CampusDataPlace) => place.place_id);
    result.status = named.length === 1 ? 'unique' : 'ambiguous';
    if (named.length === 1) {
      result.matchedLabel = named[0].name;
      const label = [named[0].name, ...named[0].aliases].map((name: string) => normalized(name))
        .find((name: string) => name.length > 0 && (location === name || location.startsWith(name) && roomSuffix(location.substring(name.length))));
      result.remainingRoomText = label === undefined ? '' : location.substring(label.length);
    }
    return result;
  }
  // Per-course campuses are not stored. An explicit different campus must not be ignored.
  if (location.includes('校区') && !location.includes(campus)) { result.status = 'unsupported'; return result; }
  if (location.includes('大学') && !location.includes(school)) { result.status = 'unsupported'; return result; }
  if (location.startsWith(school)) { location = location.substring(school.length); }
  if (location.startsWith(campus)) { location = location.substring(campus.length); }
  location = location.replace(/^[:：·-]+/, '');
  const exact = data.places.filter((place: CampusDataPlace) => placeLabels(place).includes(location));
  let candidates: CampusDataPlace[] = exact;
  let suffix = '';
  let unresolvedPart = false;
  if (exact.length === 0) {
    const parts = location.split(/[、/，,;；]/).filter((part: string) => part.length > 0);
    candidates = [];
    parts.forEach((part: string) => {
      let matched = false;
      data.places.forEach((place: CampusDataPlace) => {
        const label = placeLabels(place).find((name: string) => part === name ||
          (part.startsWith(name) && roomSuffix(part.substring(name.length))));
        if (label !== undefined) {
          matched = true;
          if (!candidates.some((candidate: CampusDataPlace) => candidate.place_id === place.place_id)) { candidates.push(place); }
          if (parts.length === 1) { suffix = part.substring(label.length); }
        }
      });
      if (!matched) { unresolvedPart = true; }
    });
  }
  result.candidateIds = candidates.map((place: CampusDataPlace) => place.place_id)
    .filter((id: string, index: number, ids: string[]) => ids.indexOf(id) === index);
  if (result.candidateIds.length > 1) { result.status = 'ambiguous'; }
  else if (result.candidateIds.length === 1 && !unresolvedPart) {
    result.status = 'unique'; result.matchedLabel = candidates[0].name; result.remainingRoomText = suffix;
  }
  return result;
}
