import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { normalize, createWorld, levelsOf } from '@house-control/visuals';
import { normalize as legacyNormalize } from '../src/config.js';
import { createWorld as legacyCreateWorld } from '../src/three/world.js';

test('browser compatibility exports reference the shared implementation', () => {
  assert.equal(legacyNormalize, normalize);
  assert.equal(legacyCreateWorld, createWorld);
});

test('bundled floor plans normalize consistently, including multi-floor plans', async () => {
  for (const name of ['home', 'studio', 'house']) {
    const raw = JSON.parse(await readFile(new URL('../public/plans/' + name + '.json', import.meta.url)));
    const model = normalize(raw);
    assert.equal(model.name, raw.name);
    assert.ok(model.rooms.length > 0);
    assert.ok(model.levels.length > 0);
    assert.deepEqual(model.levels.map(l => l.id), levelsOf(raw).map(l => l.id));
  }
});

test('a caller can import the renderer without browser globals', () => {
  assert.equal(typeof createWorld, 'function');
});
