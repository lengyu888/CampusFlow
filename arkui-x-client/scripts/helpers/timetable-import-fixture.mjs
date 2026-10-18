import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';

const source = name => readFileSync(new URL(`../../entry/src/main/ets/utils/${name}.ets`, import.meta.url), 'utf8')
  .replace(/^import [^\n]+;\r?\n/gm, '');
const load = async text => import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(text)).toString('base64')}`);
export const timetableRules = await load(source('OnboardingTimetable'));
const dependencies = { normalizeTimetableEntry:timetableRules.normalizeTimetableEntry,
  validateTimetableEntry:timetableRules.validateTimetableEntry, validateTimetableList:timetableRules.validateTimetableList };
// Executes the actual production functions; no response-shape stubs or UI emulation.
export const importReview = new Function(...Object.keys(dependencies),
  stripTypeScriptTypes(source('TimetableImportReview').replace(/^export /gm, '')) +
  '\nreturn {parseImportReview,classifyImportRows,assembleSelectedImport};')(...Object.values(dependencies));
