// The set of unreachable devices the panel shows. Run with `npm test` (Node's built-in runner).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createReachability } from '../src/reachability.js';

test('each report replaces the set and says whether it changed', () => {
  const r = createReachability();
  assert.equal(r.size, 0);
  assert.equal(r.update(['plug']), true);
  assert.equal(r.has('plug'), true);
  assert.equal(r.update(['plug']), false);            // same set: nothing to re-render
  assert.equal(r.update(['lamp', 'plug']), true);
  assert.equal(r.size, 2);
  assert.equal(r.update([]), true);                   // everything came back
  assert.equal(r.has('plug'), false);
});

test('a report without a list leaves the set alone', () => {
  const r = createReachability();
  r.update(['plug']);
  assert.equal(r.update(undefined), false);
  assert.equal(r.has('plug'), true);
});
