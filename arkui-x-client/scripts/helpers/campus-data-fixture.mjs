import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';

const readHelper = name => stripTypeScriptTypes(readFileSync(new URL(`../../entry/src/main/ets/utils/${name}.ets`, import.meta.url), 'utf8')
  .replace(/^import [^\n]+\r?\n/gm, '').replace(/^export /gm, ''));
export const { CampusFlowRequestError, requestFailure } = new Function(readHelper('AgentFeedback') +
  '\nreturn { CampusFlowRequestError, requestFailure };')();
export const campusPresentation = new Function('CampusFlowRequestError', readHelper('CampusDataPresentation') +
  '\nreturn { campusSectionsWithStatus, campusStatusFailure, previousCampusStatuses, replaceCampusResourceStatus };')(CampusFlowRequestError);
