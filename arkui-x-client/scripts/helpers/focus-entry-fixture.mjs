import { FocusController, emptyFocusState, FocusStore, FocusMemoryDriver, FakeFocusClock, FocusSchedule } from './focus-fixture.mjs';

// Execute production controller/storage in page harnesses. Only platform clock, disk and scheduling are synthetic.
export function focusEntryFixture(driver = new FocusMemoryDriver()) {
  const localFocus = new FocusStore(driver);
  const ready = localFocus.initialize();
  const clock = new FakeFocusClock();
  const scheduler = new FocusSchedule();
  class EntryFocusController extends FocusController {
    constructor(store, platformClock, changed, makeId) { super(store, platformClock, changed, makeId, scheduler); }
    async configure(...args) { await ready; return super.configure(...args); }
  }
  class PlatformFocusClock { constructor() { return clock; } }
  return { driver, store: localFocus, ready, clock, scheduler,
    dependencies: { FocusController: EntryFocusController, emptyFocusState, localFocus, PlatformFocusClock } };
}
