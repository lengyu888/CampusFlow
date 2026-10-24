import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';

const models = readFileSync(new URL('../entry/src/main/ets/model/ApiModels.ets', import.meta.url), 'utf8');
const drafts = readFileSync(new URL('../entry/src/main/ets/utils/DraftStore.ets', import.meta.url), 'utf8');
const aliases = [
  ['TimetableEntry', 'DraftCourse'],
  ['CampusMapSummary', 'DraftCampusMap'],
  ['CampusPlaceImport', 'DraftCampusPlace']
];

test('wire model to local draft aliases are one-way, with no recursive base types after branch integration', () => {
  // This is an offline contract preflight, not a substitute for ArkTS compilation.
  // UX11 aliases draft shapes to API models; retaining the older reverse
  // inheritance on merge creates Model -> DraftAlias -> Model recursion.
  for (const [wire, draft] of aliases) {
    assert.match(drafts, new RegExp(`export type ${draft} = ${wire};`));
    const declaration = models.match(new RegExp(`export interface ${wire}([^\\{]*)\\{`));
    assert.ok(declaration, `Missing API interface ${wire}`);
    assert.equal(declaration[1].trim(), '', `${wire} must not inherit back from its draft alias`);
  }
  assert.doesNotMatch(models, /from\s+['"]\.\.\/utils\/DraftStore['"]/);
});

test('standalone wire interfaces retain the exact timetable and campus payload fields', () => {
  const expected = {
    TimetableEntry: ['date: string;', 'title: string;', 'start_time: string;', 'end_time: string;', 'location: string;', 'teacher: string;'],
    CampusMapSummary: ['campus_name: string;', 'places: CampusPlaceImport[];', 'warnings: string[];'],
    CampusPlaceImport: ['name: string;', 'category: string;', 'zone: string;', 'aliases: string[];']
  };
  for (const [name, fields] of Object.entries(expected)) {
    const body = models.match(new RegExp(`export interface ${name}[^\\{]*\\{([^}]+)\\}`))?.[1];
    assert.ok(body, `Missing payload ${name}`);
    assert.deepEqual(body.trim().split(/\r?\n/).map(line => line.trim()), fields);
  }
});
