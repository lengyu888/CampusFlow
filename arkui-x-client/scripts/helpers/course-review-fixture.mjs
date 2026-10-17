import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';

// Run the actual dependency graph. Legacy action/UI tests must not replace course policy with a stub.
const source = name => readFileSync(new URL(`../../entry/src/main/ets/utils/${name}.ets`, import.meta.url), 'utf8')
  .replace(/^import \{[\s\S]*?\} from '[^']+';\r?\n/gm, '');
const moduleUrl = value => `data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(value)).toString('base64')}`;
const courseUrl = moduleUrl(source('CourseReview'));
export const courseReview = await import(courseUrl);
export const reliability = await import(moduleUrl(
  `import {validCoursePolicy, validCourseReceipt, sameCoursePolicy, sameCourseReceipt} from '${courseUrl}';\n` + source('ActionReliability')));
