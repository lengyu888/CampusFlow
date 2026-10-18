import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { courseReview, reliability } from './course-review-fixture.mjs';

const source = name => readFileSync(new URL(`../../entry/src/main/ets/utils/${name}.ets`, import.meta.url), 'utf8')
  .replace(/^import \{[\s\S]*?\} from '[^']+';\r?\n/gm, '');
const load = async name => import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source(name))).toString('base64')}`);
const plan = await load('PlanPresentation');
const evidence = await load('EvidencePresentation');
const drafts = await load('DraftStore');
const dependencies = { formatPlanDateTime: plan.formatPlanDateTime, normalizeEvidence: evidence.normalizeEvidence,
  courseCandidates: courseReview.courseCandidates, validReliableAction: reliability.validReliableAction,
  sameActionCandidate: reliability.sameActionCandidate };
// Actual production helpers with real dependency functions, not shape-only stubs.
export const presentation = new Function(...Object.keys(dependencies),
  stripTypeScriptTypes(source('ConversationPresentation').replace(/^export /gm, '')) +
  '\nreturn { conversationTitle, proposalOverview, proposalSources, validSessionContext, samePermissionReplacement };')(...Object.values(dependencies));
export const assistantDraftKey = drafts.assistantDraftKey;
export const courseCandidates = courseReview.courseCandidates;
export const validCourseAcknowledgements = courseReview.validCourseAcknowledgements;
export const conversationDependencies = { ...presentation, assistantDraftKey, courseCandidates, validCourseAcknowledgements };
