import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { registerHooks } from 'node:module';
import { fileURLToPath } from 'node:url';

// Allow Vite-style `.json` imports (without `with { type: 'json' }`) in web/src/i18n.js under Node.
registerHooks({
  load(url, context, nextLoad) {
    if (url.endsWith('.json')) {
      return {
        format: 'module',
        shortCircuit: true,
        source: `export default ${readFileSync(fileURLToPath(url), 'utf8')};`,
      };
    }
    return nextLoad(url, context);
  },
});

// Minimal canvas stub so floorMesh() in three/kit.js can run headlessly under Node.
const noopCtx = {
  fillStyle: '',
  strokeStyle: '',
  fillRect() {},
  beginPath() {},
  moveTo() {},
  lineTo() {},
  stroke() {},
};
globalThis.document = {
  documentElement: { lang: 'en' },
  createElement(tag) {
    if (tag === 'canvas') return { width: 0, height: 0, getContext: () => noopCtx };
    return {};
  },
};

const { normalize, WINDOW_SASHES } = await import('../src/config.js');
const { buildHouse } = await import('../src/three/house.js');
const { applyOperations, replacePlan, PlanEditError } = await import('../src/agent/plan-edit.js');

const basePlan = (openings = [], rooms = [{ id: 'r1', name: 'Room', rect: [0, 0, 4, 3], floor: 'oak' }]) => ({
  name: 'Test',
  wallHeight: 2.6,
  interiorWallHeight: 1.25,
  rooms,
  openings,
});

function collectMeshes(root) {
  const meshes = [];
  root.traverse((obj) => {
    if (obj.isMesh) meshes.push(obj);
  });
  return meshes;
}

function meshBounds(mesh) {
  mesh.geometry.computeBoundingBox();
  const bb = mesh.geometry.boundingBox;
  return {
    minX: mesh.position.x + bb.min.x,
    maxX: mesh.position.x + bb.max.x,
    minY: mesh.position.y + bb.min.y,
    maxY: mesh.position.y + bb.max.y,
    minZ: mesh.position.z + bb.min.z,
    maxZ: mesh.position.z + bb.max.z,
  };
}

const approx = (actual, expected, eps = 1e-4) => Math.abs(actual - expected) <= eps;

test('WINDOW_SASHES exports the supported styles', () => {
  assert.deepEqual(WINDOW_SASHES, ['fixed', 'casement', 'upperSliding']);
});

test('normalize() preserves opening defaults and new window/door fields', () => {
  const cfg = normalize(basePlan([
    { type: 'door', from: [1, 0], to: [2, 0] },
    { type: 'door', from: [2.5, 0], to: [3.3, 0], head: 2.1 },
    { type: 'open', from: [0, 1], to: [0, 2] },
    { type: 'window', from: [0.5, 3], to: [1.5, 3] },
    { type: 'window', from: [2, 3], to: [3.5, 3], sill: 0.9, head: 2.2, sash: 'casement', frosted: true, panes: 1 },
    { type: 'window', from: [4, 0.5], to: [4, 2.0], sash: 'upperSliding', panes: 2 },
    { type: 'window', from: [4, 2.1], to: [4, 2.8], sash: 'bogus', frosted: 1 },
  ]));

  assert.equal(cfg.openings[0].head, undefined);
  assert.equal(cfg.openings[0].sill, 0.85);
  assert.equal(cfg.openings[0].sash, 'fixed');
  assert.equal(cfg.openings[0].frosted, false);
  assert.equal(cfg.openings[0].panes, undefined);

  assert.equal(cfg.openings[1].head, 2.1);
  assert.equal(cfg.openings[2].head, undefined);

  assert.equal(cfg.openings[3].sill, 0.85);
  assert.equal(cfg.openings[3].head, 2.1);
  assert.equal(cfg.openings[3].sash, 'fixed');
  assert.equal(cfg.openings[3].frosted, false);

  assert.equal(cfg.openings[4].sill, 0.9);
  assert.equal(cfg.openings[4].head, 2.2);
  assert.equal(cfg.openings[4].sash, 'casement');
  assert.equal(cfg.openings[4].frosted, true);
  assert.equal(cfg.openings[4].panes, 1);

  assert.equal(cfg.openings[5].sash, 'upperSliding');
  assert.equal(cfg.openings[5].panes, 2);

  assert.equal(cfg.openings[6].sash, 'fixed');
  assert.equal(cfg.openings[6].frosted, true);
});

test('buildHouse() renders door lintels only when head is finite and within wall height', () => {
  const noHead = buildHouse(normalize(basePlan([{ type: 'door', from: [1, 0], to: [2, 0] }])));
  const withHead = buildHouse(normalize(basePlan([{ type: 'door', from: [1, 0], to: [2, 0], head: 2.1 }])));

  const findLintel = (house) => collectMeshes(house.group).filter((m) => {
    const b = meshBounds(m);
    return approx(b.minX, 1) && approx(b.maxX, 2) && approx(m.position.z, 0) && approx(b.minY, 2.1) && approx(b.maxY, 2.6);
  });

  assert.equal(findLintel(noHead).length, 0);
  assert.equal(findLintel(withHead).length, 1);

  // Interior door: wall height is Hi = 1.25. head=1.0 produces a lintel; head=2.1 does not.
  const twoRooms = [
    { id: 'a', name: 'A', rect: [0, 0, 3, 3], floor: 'oak' },
    { id: 'b', name: 'B', rect: [3, 0, 3, 3], floor: 'oak' },
  ];
  const intLow = buildHouse(normalize(basePlan([{ type: 'door', from: [3, 1], to: [3, 2], head: 1.0 }], twoRooms)));
  const intHigh = buildHouse(normalize(basePlan([{ type: 'door', from: [3, 1], to: [3, 2], head: 2.1 }], twoRooms)));

  const findIntLintel = (house) => collectMeshes(house.group).filter((m) => {
    const b = meshBounds(m);
    return approx(m.position.x, 3) && approx(b.minZ, 1) && approx(b.maxZ, 2) && approx(b.minY, 1.0) && approx(b.maxY, 1.25);
  });
  assert.equal(findIntLintel(intLow).length, 1);
  assert.equal(findIntLintel(intHigh).length, 0);
});

test('buildHouse() renders fixed windows with sill ledge, mullion rules, and frosted glazing', () => {
  const narrow = buildHouse(normalize(basePlan([{ type: 'window', from: [1, 0], to: [2, 0] }])));
  const narrowTwoPanes = buildHouse(normalize(basePlan([{ type: 'window', from: [1, 0], to: [2, 0], panes: 2 }])));
  const wideDefault = buildHouse(normalize(basePlan([{ type: 'window', from: [1, 0], to: [2.6, 0] }])));
  const wideOnePane = buildHouse(normalize(basePlan([{ type: 'window', from: [1, 0], to: [2.6, 0], panes: 1 }])));
  const frosted = buildHouse(normalize(basePlan([{ type: 'window', from: [1, 0], to: [2, 0], frosted: true }])));

  const hasMullion = (house, cx) => collectMeshes(house.group).some((m) => {
    const b = meshBounds(m);
    return approx(m.position.x, cx) && approx(m.position.z, 0) && approx(b.maxX - b.minX, 0.05) && approx(b.minY, 0.85) && approx(b.maxY, 2.1);
  });

  assert.equal(hasMullion(narrow, 1.5), false);
  assert.equal(hasMullion(narrowTwoPanes, 1.5), true);
  assert.equal(hasMullion(wideDefault, 1.8), true);
  assert.equal(hasMullion(wideOnePane, 1.8), false);

  // Sill ledge on north wall (z = 0, inside = +1 => shifted to z = +0.015).
  const sillMeshes = collectMeshes(narrow.group).filter((m) => {
    const b = meshBounds(m);
    return approx(m.position.z, 0.015) && approx(b.minY, 0.85 - 0.018) && approx(b.maxY, 0.85 + 0.014);
  });
  assert.equal(sillMeshes.length, 1);

  // Glazing: clear vs frosted.
  const findPane = (house) => collectMeshes(house.group).find((m) => m.castShadow === false && approx(m.position.x, 1.5) && approx(m.position.z, 0));
  const clearPane = findPane(narrow);
  const frostedPane = findPane(frosted);
  assert.ok(clearPane);
  assert.ok(frostedPane);
  assert.equal(clearPane.material.transparent, true);
  assert.equal(frostedPane.material.transparent, false);
  assert.equal(frostedPane.material.color.getHexString(), 'e0e9e8');
  assert.equal(frostedPane.material.roughness, 0.75);
});

test('buildHouse() renders casement windows with rebate stop, recessed sash, lever handle, and hinges', () => {
  const house = buildHouse(normalize(basePlan([
    { type: 'window', from: [1, 0], to: [2.2, 0], sill: 0.85, head: 2.1, sash: 'casement' },
  ])));
  const meshes = collectMeshes(house.group);

  // North wall has z = 0, inside = +1.
  const atZ = (z) => meshes.filter((m) => approx(m.position.z, z) && m.position.x >= 0.9 && m.position.x <= 2.3);

  assert.equal(atZ(-0.022).length, 4, '4 perimeter rebate stop bars');
  assert.equal(atZ(0.012).length, 5, '1 glazing pane + 4 inner sash bars');
  assert.equal(atZ(0.012).filter((m) => m.castShadow === false).length, 1, 'casement glazing does not cast shadow');
  assert.equal(atZ(0.045).length, 1, 'escutcheon plate');
  assert.equal(atZ(0.058).length, 1, 'handle stem');
  assert.equal(atZ(0.072).length, 1, 'downward lever grip');
  assert.equal(atZ(0.044).length, 2, '2 barrel hinges');

  const lever = atZ(0.072)[0];
  const lb = meshBounds(lever);
  const midY = (0.85 + 2.1) / 2;
  assert.ok(approx(lb.minY, midY - 0.095) && approx(lb.maxY, midY + 0.008));
  assert.equal(lever.material.metalness, 0.75);
});

test('buildHouse() renders upperSliding windows with staggered panes, meeting bar, surround, and sash lift', () => {
  const house = buildHouse(normalize(basePlan([
    { type: 'window', from: [1, 0], to: [2.2, 0], sill: 0.85, head: 2.1, sash: 'upperSliding', frosted: true },
  ])));
  const meshes = collectMeshes(house.group);
  const atZ = (z) => meshes.filter((m) => approx(m.position.z, z) && m.position.x >= 0.9 && m.position.x <= 2.3);

  assert.equal(atZ(-0.016).length, 2, 'lower pane + lower meeting bar');
  assert.equal(atZ(-0.016).filter((m) => m.castShadow === false).length, 1);
  assert.equal(atZ(0.016).length, 5, 'upper pane + 4-bar inner surround');
  assert.equal(atZ(0.016).filter((m) => m.castShadow === false).length, 1);
  assert.equal(atZ(0.042).length, 1, 'centered interior sash lift');

  const lift = atZ(0.042)[0];
  const lb = meshBounds(lift);
  const mid = (0.85 + 2.1) / 2;
  assert.ok(approx(mCenter(lb.minX, lb.maxX), 1.6));
  assert.ok(approx(lb.minY, mid - 0.008) && approx(lb.maxY, mid + 0.012));
  assert.equal(lift.material.metalness, 0.75);
});

const mCenter = (a, b) => (a + b) / 2;

test('applyOperations() validates and preserves opening sash, frosted, panes, and door head', () => {
  const { plan } = applyOperations(basePlan(), [
    { op: 'add_opening', type: 'door', from: [1, 0], to: [2, 0], head: 2.1 },
    { op: 'add_opening', type: 'window', from: [1, 3], to: [2.2, 3], sill: 0.9, head: 2.2, sash: 'casement', frosted: true, panes: 2 },
    { op: 'add_opening', type: 'window', from: [2.5, 3], to: [3.5, 3], sash: 'fixed', frosted: false, panes: 1 },
  ]);

  assert.deepEqual(plan.openings[0], { type: 'door', from: [1, 0], to: [2, 0], head: 2.1 });
  assert.deepEqual(plan.openings[1], {
    type: 'window', from: [1, 3], to: [2.2, 3], head: 2.2, sill: 0.9, sash: 'casement', frosted: true, panes: 2,
  });
  assert.deepEqual(plan.openings[2], { type: 'window', from: [2.5, 3], to: [3.5, 3], panes: 1 });

  assert.throws(
    () => applyOperations(basePlan(), [{ op: 'add_opening', type: 'window', from: [1, 0], to: [2, 0], sash: 'awning' }]),
    PlanEditError,
  );
  assert.throws(
    () => applyOperations(basePlan(), [{ op: 'add_opening', type: 'window', from: [1, 0], to: [2, 0], frosted: 'yes' }]),
    PlanEditError,
  );
  assert.throws(
    () => applyOperations(basePlan(), [{ op: 'add_opening', type: 'window', from: [1, 0], to: [2, 0], panes: 3 }]),
    PlanEditError,
  );
  assert.throws(
    () => applyOperations(basePlan(), [{ op: 'add_opening', type: 'door', from: [1, 0], to: [2, 0], head: 0 }]),
    PlanEditError,
  );

  // replacePlan() also enforces opening validation via check().
  assert.throws(
    () => replacePlan(basePlan(), basePlan([{ type: 'window', from: [1, 0], to: [2, 0], sash: 'invalid' }])),
    PlanEditError,
  );
  assert.throws(
    () => replacePlan(basePlan(), basePlan([{ type: 'window', from: [1, 0], to: [2, 0], panes: 4 }])),
    PlanEditError,
  );
});
