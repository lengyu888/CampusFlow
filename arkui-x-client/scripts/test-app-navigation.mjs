import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { test } from 'node:test';

// Exercise production navigation transitions; page lifecycle/rendering remains native QA.
const source = readFileSync(new URL('../entry/src/main/ets/utils/AppNavigation.ets', import.meta.url), 'utf8');
const { createNavigation, currentRoute, selectRoot, openSecondary, backNavigation, isRootRoute, hasBack } =
  await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source)).toString('base64')}`);

test('the four root identifiers preserve existing route numbers and independent initial stacks', () => {
  const state = createNavigation();
  assert.equal(state.root, 0);
  assert.equal(currentRoute(state), 0);
  assert.equal(hasBack(state), false);
  assert.deepEqual(state.stacks, [
    { root: 0, routes: [0] }, { root: 1, routes: [1] },
    { root: 2, routes: [2] }, { root: 8, routes: [8] }
  ]);
  assert.deepEqual(Array.from({ length: 9 }, (_, index) => index).filter(isRootRoute), [0, 1, 2, 8]);
});

test('root selection restores each saved secondary stack without resetting another root', () => {
  let state = openSecondary(createNavigation(), 4);
  state = openSecondary(selectRoot(state, 1), 5);
  state = openSecondary(selectRoot(state, 2), 6);
  state = openSecondary(selectRoot(state, 8), 3);
  assert.equal(currentRoute(selectRoot(state, 0)), 4);
  assert.equal(currentRoute(selectRoot(state, 1)), 5);
  assert.equal(currentRoute(selectRoot(state, 2)), 6);
  assert.equal(currentRoute(selectRoot(state, 8)), 3);
  assert.equal(currentRoute(selectRoot(state, 8)), currentRoute(state), 'reselecting the active root does not reset it');
});

test('explicit cross-page root targeting resets only its destination stack', () => {
  let state = openSecondary(createNavigation(), 4);
  state = openSecondary(selectRoot(state, 2), 6);
  state = openSecondary(selectRoot(state, 1), 5);
  const destination = selectRoot(state, 2, true);
  assert.equal(destination.root, 2);
  assert.equal(currentRoute(destination), 2);
  assert.equal(hasBack(destination), false);
  assert.equal(currentRoute(selectRoot(destination, 0)), 4);
  assert.equal(currentRoute(selectRoot(destination, 1)), 5);
  assert.equal(currentRoute(selectRoot(state, 2)), 6, 'the old state remains a usable snapshot');
});

test('secondary navigation pushes and back pops one frame while preserving the root', () => {
  let state = selectRoot(createNavigation(), 8);
  state = openSecondary(state, 7);
  state = openSecondary(state, 4);
  assert.equal(currentRoute(state), 4);
  assert.equal(hasBack(state), true);
  state = backNavigation(state);
  assert.equal(currentRoute(state), 7);
  assert.equal(state.root, 8);
  assert.equal(hasBack(state), true);
  state = backNavigation(state);
  assert.equal(currentRoute(state), 8);
  assert.equal(hasBack(state), false);
  assert.deepEqual(backNavigation(state), state, 'back at a root never exits or underflows its stack');
});

test('duplicate taps do not grow a stack and unsupported routes do not alter navigation', () => {
  const state = openSecondary(createNavigation(), 5);
  assert.deepEqual(openSecondary(state, 5), state);
  for (const route of [-1, 9, NaN, 0, 1, 2, 8]) assert.deepEqual(openSecondary(state, route), state);
  for (const route of [-1, 9, NaN, 3, 4, 5, 6, 7]) assert.deepEqual(selectRoot(state, route, true), state);
});

test('every transition returns independent objects and never mutates frozen input state', () => {
  const state = openSecondary(createNavigation(), 4);
  const snapshot = JSON.stringify(state);
  state.stacks.forEach((stack) => { Object.freeze(stack.routes); Object.freeze(stack); });
  Object.freeze(state.stacks); Object.freeze(state);
  const nextStates = [selectRoot(state, 1), selectRoot(state, 0, true), openSecondary(state, 5),
    backNavigation(state), selectRoot(state, -1), openSecondary(state, 4)];
  for (const next of nextStates) {
    assert.notEqual(next, state);
    assert.notEqual(next.stacks, state.stacks);
    for (let index = 0; index < next.stacks.length; index++) {
      assert.notEqual(next.stacks[index], state.stacks[index]);
      assert.notEqual(next.stacks[index].routes, state.stacks[index].routes);
    }
  }
  assert.equal(JSON.stringify(state), snapshot);
});

test('authentication reset discards all prior account stacks without affecting their snapshots', () => {
  let previous = openSecondary(createNavigation(), 4);
  previous = openSecondary(selectRoot(previous, 1), 5);
  previous = openSecondary(selectRoot(previous, 8), 7);
  const fresh = createNavigation();
  for (const root of [0, 1, 2, 8]) {
    assert.equal(currentRoute(selectRoot(fresh, root)), root);
    assert.equal(hasBack(selectRoot(fresh, root)), false);
  }
  assert.equal(currentRoute(previous), 7);
  assert.equal(currentRoute(selectRoot(previous, 1)), 5);
});
