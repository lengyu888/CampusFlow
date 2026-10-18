import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
const read = name => readFileSync(new URL(`../../entry/src/main/ets/utils/${name}.ets`, import.meta.url), 'utf8');
const clean = s => s.replace(/^import \{[\s\S]*?\} from '[^']+';\r?\n/gm, '').replace(/^import [^\n]+;\r?\n/gm, '');
const module = async name => import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(clean(read(name)))).toString('base64')}`);
export const agenda = await module('DailyAgenda');
export const preferences = await module('LearningPreferences');
const source = clean(read('PlanningOverview')).replace(/^export /gm, '');
export const overview = new Function(...Object.keys(agenda), stripTypeScriptTypes(source) + '\nreturn {filterPlanningTasks,buildPlanningWeek,resolvePlanningCourse,dailyPlannedLoad,projectPlanningCandidate,validPlanningTimetable};')(...Object.values(agenda));
export const planningPageDependencies = { ...overview, validPreferenceSnapshot: preferences.validPreferenceSnapshot };
export const dependencyPrefix = `const {${Object.keys(planningPageDependencies).join(',')}} = planningPageDependencies;\n`;
export const timetableSnapshot = entries => ({ entries, revision: 'a'.repeat(64), evidence: [] });
export const preferenceSnapshot = (extra = {}) => ({ enabled: false, session_minutes: 50, break_minutes: 10,
  preferred_period: 'any', daily_minutes: 120, revision: 0, updated_at: null, ...extra });
