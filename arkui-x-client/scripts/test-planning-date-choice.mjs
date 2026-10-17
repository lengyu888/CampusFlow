import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { test } from 'node:test';

const agendaSource = readFileSync(new URL('../entry/src/main/ets/utils/DailyAgenda.ets', import.meta.url), 'utf8').replace(/^import [^\n]+;\r?\n/gm, '');
const agenda = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(agendaSource)).toString('base64')}`);

const source = readFileSync(new URL('../entry/src/main/ets/pages/PlanCenterPage.ets', import.meta.url), 'utf8');
const firstBuilder = source.indexOf('\n  @Builder');
assert.ok(firstBuilder > 0, 'the non-UI method boundary must exist');
// Exercise production selection state, not a copied implementation or a simulated native layout.
const controllerSource = source.slice(0, firstBuilder)
  .replace(/^import \{[\s\S]*?\} from '\.\.\/model\/ApiModels';\r?\n/, '')
  .replace(/^import [^\n]+;\r?\n/gm, '')
  .replace(/^@Component\r?\n/m, '')
  .replace(/@(Prop|State)\s+|@Watch\('[^']+'\)\s*/g, '')
  .replace('export struct PlanCenterPage', 'class PlanCenterPage') + '\n}\n';
const createController = new Function('TextInputController', 'AppTheme', 'Curve', 'Scroller', 'shanghaiDate', 'buildDailyAgenda',
  stripTypeScriptTypes(controllerSource) + '\nreturn PlanCenterPage;');

function page() {
  const Controller = createController(class TextInputController {}, { motion: () => 0 }, { EaseOut: 'ease-out' }, class {}, agenda.shanghaiDate, agenda.buildDailyAgenda);
  const instance = new Controller();
  instance.getUIContext = () => ({ animateTo: (_options, update) => update() });
  return instance;
}

test('today and calendar can resolve to the same date without both appearing selected', () => {
  const instance = page();
  const date = instance.relativeDate(0);
  instance.selectedDate = date;
  instance.selectDraftDate(date, 'today');
  assert.equal(instance.dateChoiceSelected('today', date), true);
  assert.equal(instance.dateChoiceSelected('calendar', date), false);
  instance.selectDraftDate(date, 'calendar');
  assert.equal(instance.dateChoiceSelected('today', date), false);
  assert.equal(instance.dateChoiceSelected('calendar', date), true);
  assert.equal(instance.draftTaskDate, date, 'the actual date remains unchanged');
});

test('browsing to another calendar date does not change the date already applied to a draft', () => {
  const instance = page();
  instance.selectedDate = '2026-10-17';
  instance.selectDraftDate(instance.selectedDate, 'calendar');
  instance.selectedDate = '2026-10-18';
  assert.equal(instance.draftTaskDate, '2026-10-17');
  assert.equal(instance.dateChoiceSelected('calendar', instance.selectedDate), false);
  instance.selectDraftDate(instance.selectedDate, 'calendar');
  assert.equal(instance.draftTaskDate, '2026-10-18');
  assert.equal(instance.dateChoiceSelected('calendar', instance.selectedDate), true);
});

test('no-date and explicit-time selection preserve existing date/time business rules', () => {
  const instance = page();
  instance.draftTaskTime = '18:30';
  instance.selectDraftDate('', 'none');
  assert.equal(instance.draftTaskTime, '');
  assert.equal(instance.dateChoiceSelected('none', ''), true);
  instance.selectDraftTime('08:00');
  assert.equal(instance.draftTaskDate, instance.relativeDate(0));
  assert.equal(instance.draftTaskTime, '08:00');
  assert.equal(instance.dateChoiceSelected('today', instance.relativeDate(0)), true);
  assert.equal(instance.dateChoiceSelected('none', ''), false);
  assert.equal(instance.dateChoiceSelected('calendar', instance.relativeDate(0)), false);
});
