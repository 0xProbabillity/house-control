// Which linked devices the last check could not reach. The native side reports the complete
// list with every poll (`update.offline`); this keeps it and says whether it changed, so the
// store only re-renders when something came or went. No DOM, no bridge: test/reachability.test.js.

/** A set of unreachable device ids that is replaced wholesale by each report. */
export function createReachability() {
  let offline = new Set();
  return {
    /** Takes a poll's `offline` list; returns true when the set changed. Ignores a missing list. */
    update(list) {
      if (!Array.isArray(list)) return false;
      const next = new Set(list);
      const changed = next.size !== offline.size || [...next].some((id) => !offline.has(id));
      offline = next;
      return changed;
    },
    /** True when the last check could not reach this device. */
    has(id) { return offline.has(id); },
    get size() { return offline.size; },
  };
}
