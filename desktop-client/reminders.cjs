const { isHistoryId } = require('./history.cjs');

const DAY = 86_400_000;
const MAX_TIMEOUT = 2_147_483_647;

function createReminderQueue(deliver) {
  const pending = new Map();

  function clear() {
    for (const timer of pending.values()) clearTimeout(timer);
    pending.clear();
  }

  function schedule(entry) {
    const remaining = entry.at - Date.now();
    const timer = setTimeout(() => {
      if (entry.at > Date.now()) { schedule(entry); return; }
      pending.delete(entry.id);
      deliver(entry.title);
    }, Math.min(MAX_TIMEOUT, Math.max(0, remaining)));
    pending.set(entry.id, timer);
  }

  function replace(entries) {
    if (!Array.isArray(entries) || entries.length > 100) return false;
    const ids = new Set();
    for (const item of entries) {
      if (!item || !isHistoryId(item.id) || ids.has(item.id) || typeof item.title !== 'string' ||
          !item.title.trim() || [...item.title].length > 120 || !Number.isSafeInteger(item.at)) return false;
      ids.add(item.id);
    }
    clear();
    const now = Date.now();
    for (const item of entries) {
      if (item.at > now && item.at <= now + 366 * DAY) schedule(item);
    }
    return true;
  }

  return { clear, replace, get size() { return pending.size; } };
}

module.exports = { createReminderQueue };
