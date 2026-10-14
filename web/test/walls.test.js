// The wall layout of small plans: which walls are outer, how thick they are, and how far
// their ends reach. Run with `npm test` (Node's built-in test runner; no dependencies).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { planWalls, facesCamera, OUTER_THICKNESS, INNER_THICKNESS } from '../src/three/walls.js';

const room = (x, z, w, d) => ({ x, z, w, d });
const plan = (rooms, openings = []) => planWalls({ rooms, openings });
// The segment on `axis` at `c` that covers `at`.
const wallAt = (walls, axis, c, at) => walls.find((s) => s.axis === axis && Math.abs(s.c - c) < 1e-6 && s.a < at && at < s.b);

test('a shared edge is one inner wall; the outline is outer', () => {
  const walls = plan([room(0, 0, 3, 3), room(3, 0, 2, 3)]);
  const shared = wallAt(walls, 'z', 3, 1.5);
  assert.equal(shared.kind, 'interior');
  assert.equal(shared.thickness, INNER_THICKNESS);
  for (const [axis, c, at] of [['z', 0, 1.5], ['z', 5, 1.5], ['x', 0, 1], ['x', 3, 4]]) {
    const w = wallAt(walls, axis, c, at);
    assert.equal(w.outline, true, `${axis}=${c}`);
    assert.equal(w.thickness, OUTER_THICKNESS, `${axis}=${c}`);
  }
});

test('a wall facing a recess is thin and never cut away for the camera', () => {
  // An L: the missing corner (x 2–4, z 2–4) is a recess, like a stairwell.
  const walls = plan([room(0, 0, 4, 2), room(0, 2, 2, 2)]);
  const recessSide = wallAt(walls, 'z', 2, 3);   // B's east side, x = 2
  const recessTop = wallAt(walls, 'x', 2, 3);    // A's south side beyond B, z = 2
  for (const w of [recessSide, recessTop]) {
    assert.equal(w.kind, 'exterior');
    assert.equal(w.outline, false);
    assert.equal(w.thickness, INNER_THICKNESS);
  }
  // Seen from the south-east, the recess walls face the camera but stay standing.
  assert.equal(facesCamera(recessTop, { x: 0.7, z: 0.7 }), false);
  assert.equal(facesCamera(wallAt(walls, 'x', 4, 1), { x: 0.7, z: 0.7 }), true); // the outline's south side
});

test('a free end reaches the middle of the wall it meets, and no further', () => {
  // A and B side by side, C across both below: the A|B wall ends in a T on the A/B|C wall.
  const walls = plan([room(0, 0, 2, 3), room(2, 0, 2, 3), room(0, 3, 4, 2)]);
  const ab = wallAt(walls, 'z', 2, 1.5);
  assert.equal(ab.to, 3 + INNER_THICKNESS / 2);   // into the inner wall at z = 3
  assert.equal(ab.from, 0 - OUTER_THICKNESS / 2); // into the outer wall at z = 0
});

test('a wall of an open slab (a balcony) is not part of the outline', () => {
  // A balcony slab north of the facade, open on all sides.
  const openings = [
    { type: 'open', from: [0, -1.2], to: [4, -1.2] }, { type: 'open', from: [0, -0.1], to: [4, -0.1] },
    { type: 'open', from: [0, -1.2], to: [0, -0.1] }, { type: 'open', from: [4, -1.2], to: [4, -0.1] },
  ];
  const walls = plan([room(0, 0, 4, 3), room(0, -1.2, 4, 1.1)], openings);
  const facade = wallAt(walls, 'x', 0, 2);
  assert.equal(facade.outline, true);
  assert.equal(facade.thickness, OUTER_THICKNESS);
});

test('only outline walls on the camera side are cut away', () => {
  const walls = plan([room(0, 0, 4, 3)]);
  const south = wallAt(walls, 'x', 3, 2);
  const north = wallAt(walls, 'x', 0, 2);
  assert.equal(facesCamera(south, { x: 0, z: 1 }), true);
  assert.equal(facesCamera(north, { x: 0, z: 1 }), false);
});
