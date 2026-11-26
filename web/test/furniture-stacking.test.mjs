import test from 'node:test';
import assert from 'node:assert/strict';
import { registerHooks } from 'node:module';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import * as THREE from 'three';
import {
  FURNITURE_TYPES,
  FURNITURE_VARIANTS,
  footprint,
  surfaceHeight,
  isWallMounted,
  buildFurniture,
} from '../src/three/furniture.js';
import {
  pointInFootprint,
  supportElevation,
  stackedRiders,
} from '../src/editor/stacking.js';

// Allow Node to load Vite-style bare JSON imports in i18n.js (imported transitively by plan-edit.js -> config.js).
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

const { applyOperations, PlanEditError } = await import('../src/agent/plan-edit.js');

function meshCount(group) {
  let n = 0;
  group.traverse((o) => { if (o.isMesh) n++; });
  return n;
}

test('FURNITURE_VARIANTS contract and default-first ordering', () => {
  assert.deepEqual(FURNITURE_VARIANTS, {
    tv: ['console', 'wall'],
    vanity: ['cabinet', 'pedestal'],
    coffeeTable: ['modern', 'woodShelf'],
    sofa: ['pillowed', 'plain'],
  });
  assert.ok(FURNITURE_TYPES.includes('pillow'));
});

test('isWallMounted handles variant and legacy wallMounted boolean', () => {
  assert.equal(isWallMounted({ type: 'tv' }), false);
  assert.equal(isWallMounted({ type: 'tv', variant: 'console' }), false);
  assert.equal(isWallMounted({ type: 'tv', variant: 'wall' }), true);
  assert.equal(isWallMounted({ type: 'tv', wallMounted: true }), true);
  assert.equal(isWallMounted({ type: 'sofa', wallMounted: true }), false);
});

test('surfaceHeight returns expected heights and null for non-supports', () => {
  assert.equal(surfaceHeight({ type: 'sofa' }), 0.47);
  assert.equal(surfaceHeight({ type: 'armchair' }), 0.47);
  assert.equal(surfaceHeight({ type: 'bed' }), 0.48);
  assert.equal(surfaceHeight({ type: 'coffeeTable' }), 0.4);
  assert.equal(surfaceHeight({ type: 'coffeeTable', height: 0.45 }), 0.45);
  assert.equal(surfaceHeight({ type: 'sideboard' }), 0.76);
  assert.equal(surfaceHeight({ type: 'diningSet' }), 0.76);
  assert.equal(surfaceHeight({ type: 'island' }), 0.93);
  assert.equal(surfaceHeight({ type: 'kitchen' }), 0.9);
  assert.equal(surfaceHeight({ type: 'kitchen', height: 0.95 }), 0.95);
  assert.equal(surfaceHeight({ type: 'fridge' }), 1.92);
  assert.equal(surfaceHeight({ type: 'nightstand' }), 0.5);
  assert.equal(surfaceHeight({ type: 'dresser' }), 0.84);
  assert.equal(surfaceHeight({ type: 'dresser', height: 1.0 }), 1.0);
  assert.equal(surfaceHeight({ type: 'desk' }), 0.76);
  assert.equal(surfaceHeight({ type: 'desk', height: 0.8 }), 0.8);
  assert.equal(surfaceHeight({ type: 'bookshelf' }), 1.8);
  assert.equal(surfaceHeight({ type: 'bookshelf', height: 2.0 }), 2.0);
  assert.equal(surfaceHeight({ type: 'wardrobe' }), 2.1);
  assert.equal(surfaceHeight({ type: 'wardrobe', height: 2.3 }), 2.3);
  assert.equal(surfaceHeight({ type: 'tv' }), 0.46);
  assert.equal(surfaceHeight({ type: 'tv', variant: 'console' }), 0.46);
  assert.equal(surfaceHeight({ type: 'tv', variant: 'wall' }), null);
  assert.equal(surfaceHeight({ type: 'tv', wallMounted: true }), null);

  for (const t of ['rug', 'plant', 'bathtub', 'toilet', 'stairs', 'pillow']) {
    assert.equal(surfaceHeight({ type: t }), null, `${t} should not be a support`);
  }
});

test('footprint reflects variants and custom depth/width', () => {
  assert.deepEqual(footprint({ type: 'pillow' }), [0.38, 0.16]);
  assert.deepEqual(footprint({ type: 'pillow', width: 0.5 }), [0.5, 0.16]);
  assert.deepEqual(footprint({ type: 'tv' }), [1.7, 0.4]);
  assert.deepEqual(footprint({ type: 'tv', variant: 'wall' }), [1.7, 0.055]);
  assert.deepEqual(footprint({ type: 'tv', wallMounted: true, width: 1.4 }), [1.4, 0.055]);
  assert.deepEqual(footprint({ type: 'coffeeTable', width: 1.2, depth: 0.7 }), [1.2, 0.7]);
  const [bw, bd] = footprint({ type: 'bed', width: 1.8, depth: 2.2 });
  assert.ok(Math.abs(bw - 1.9) < 1e-9);
  assert.equal(bd, 2.2);
  const [dbw, dbd] = footprint({ type: 'bed' });
  assert.ok(Math.abs(dbw - 1.7) < 1e-9);
  assert.equal(dbd, 2.14);
  assert.deepEqual(footprint({ type: 'desk', width: 1.5, depth: 0.8 }), [1.5, 0.8]);
  assert.deepEqual(footprint({ type: 'dresser', width: 1.2, depth: 0.5 }), [1.2, 0.5]);
  assert.deepEqual(footprint({ type: 'kitchen', width: 2.8, depth: 0.65 }), [2.8, 0.65]);
});

test('builders support all variants and backwards-compat boolean aliases', () => {
  const sofaDefault = buildFurniture([{ type: 'sofa', pos: [0, 0] }]);
  const sofaPlain = buildFurniture([{ type: 'sofa', pos: [0, 0], variant: 'plain' }]);
  const sofaLegacyPlain = buildFurniture([{ type: 'sofa', pos: [0, 0], throwPillow: false }]);
  const sofaVariantOverridesLegacy = buildFurniture([{ type: 'sofa', pos: [0, 0], variant: 'pillowed', throwPillow: false }]);
  assert.equal(meshCount(sofaPlain), meshCount(sofaDefault) - 1);
  assert.equal(meshCount(sofaLegacyPlain), meshCount(sofaPlain));
  assert.equal(meshCount(sofaVariantOverridesLegacy), meshCount(sofaDefault));

  const tvConsole = buildFurniture([{ type: 'tv', pos: [0, 0] }]);
  const tvWall = buildFurniture([{ type: 'tv', pos: [0, 0], variant: 'wall', y: 1.0 }]);
  const tvLegacyWall = buildFurniture([{ type: 'tv', pos: [0, 0], wallMounted: true, y: 1.0 }]);
  assert.equal(meshCount(tvWall), meshCount(tvLegacyWall));
  assert.ok(meshCount(tvWall) < meshCount(tvConsole));
  // Verify unlit dark OLED MeshBasicMaterial
  let foundBasicOled = false;
  tvWall.traverse((o) => {
    if (o.isMesh && o.material?.isMeshBasicMaterial && o.material.toneMapped === false) {
      foundBasicOled = true;
    }
  });
  assert.equal(foundBasicOled, true);

  const vanityCabinet = buildFurniture([{ type: 'vanity', pos: [0, 0] }]);
  const vanityPedestal = buildFurniture([{ type: 'vanity', pos: [0, 0], variant: 'pedestal' }]);
  const vanityLegacyPedestal = buildFurniture([{ type: 'vanity', pos: [0, 0], pedestal: true }]);
  assert.equal(meshCount(vanityPedestal), meshCount(vanityLegacyPedestal));
  assert.notEqual(meshCount(vanityPedestal), meshCount(vanityCabinet));

  const tableModern = buildFurniture([{ type: 'coffeeTable', pos: [0, 0] }]);
  const tableShelf = buildFurniture([{ type: 'coffeeTable', pos: [0, 0], variant: 'woodShelf', depth: 0.7, height: 0.45 }]);
  const tableLegacyShelf = buildFurniture([{ type: 'coffeeTable', pos: [0, 0], woodShelf: true }]);
  assert.equal(meshCount(tableShelf), meshCount(tableLegacyShelf));
  assert.notEqual(meshCount(tableShelf), meshCount(tableModern));

  const pillow = buildFurniture([{ type: 'pillow', pos: [1, 2], y: 0.47, color: '#c9553f' }]);
  assert.equal(meshCount(pillow), 1);
  assert.equal(pillow.children[0].position.y, 0.47);

  // Updated builders with depth/height/color
  const extras = buildFurniture([
    { type: 'bed', pos: [0, 0], width: 1.8, depth: 2.2, color: '#6b7fa3' },
    { type: 'desk', pos: [3, 0], width: 1.5, depth: 0.75, height: 0.8 },
    { type: 'dresser', pos: [6, 0], width: 1.2, depth: 0.5, height: 0.9 },
    { type: 'kitchen', pos: [9, 0], width: 2.5, depth: 0.65, height: 0.92 },
    { type: 'wardrobe', pos: [12, 0], width: 1.8, height: 2.2, color: '#d4cfc7' },
  ]);
  assert.equal(extras.children.length, 5);
});

test('pointInFootprint matches Three.js Object3D.rotation.y for rot 0, 90, -90, 45', () => {
  for (const rot of [0, 90, -90, 45]) {
    const target = { type: 'sofa', pos: [3.5, 2.2], rot, width: 2.4 }; // footprint [2.4, 0.95]
    const obj = new THREE.Object3D();
    obj.position.set(target.pos[0], 0, target.pos[1]);
    obj.rotation.y = THREE.MathUtils.degToRad(rot);
    obj.updateMatrixWorld(true);

    // Local points inside the 2.4 x 0.95 box: near corners along +x/-x and +z/-z
    const insideLocals = [
      [0, 0],
      [1.15, 0.42],
      [-1.15, -0.42],
      [1.15, -0.42],
      [-1.15, 0.42],
    ];
    for (const [lx, lz] of insideLocals) {
      const world = new THREE.Vector3(lx, 0, lz).applyMatrix4(obj.matrixWorld);
      assert.equal(
        pointInFootprint([world.x, world.z], target),
        true,
        `rot=${rot} local (${lx}, ${lz}) -> world (${world.x.toFixed(3)}, ${world.z.toFixed(3)}) should be inside`,
      );
    }

    // Local points outside the 2.4 x 0.95 box (e.g. just past depth edge at z=0.6 or width edge at x=1.3)
    const outsideLocals = [
      [0, 0.6],
      [0, -0.6],
      [1.3, 0],
      [-1.3, 0],
    ];
    for (const [lx, lz] of outsideLocals) {
      const world = new THREE.Vector3(lx, 0, lz).applyMatrix4(obj.matrixWorld);
      assert.equal(
        pointInFootprint([world.x, world.z], target),
        false,
        `rot=${rot} local (${lx}, ${lz}) -> world (${world.x.toFixed(3)}, ${world.z.toFixed(3)}) should be outside`,
      );
    }
  }
});

test('supportElevation handles single and multi-tier stacking and level isolation', () => {
  const list = [
    { type: 'sofa', pos: [2, 2], variant: 'plain', level: 'ground' }, // top = 0.47
    { type: 'bed', pos: [6, 2], level: 'ground' }, // top = 0.48
    { type: 'dresser', pos: [2, 6], level: 'ground' }, // top = 0.84
    { type: 'tv', pos: [2, 6], y: 0.84, level: 'ground' }, // console TV on dresser, top = 0.84 + 0.46 = 1.30
    { type: 'dresser', pos: [2, 2], level: 'upper' }, // different level
  ];
  const levelOf = (f) => f.level ?? 'ground';

  // Pillow over sofa on ground floor
  assert.equal(supportElevation({ type: 'pillow', pos: [2.3, 2], level: 'ground' }, list, new Set(), levelOf), 0.47);
  // Pillow over bed on ground floor
  assert.equal(supportElevation({ type: 'pillow', pos: [6, 1.5], level: 'ground' }, list, new Set(), levelOf), 0.48);
  // Multi-tier: item over console TV stacked on dresser -> 0.84 + 0.46 = 1.30
  assert.ok(Math.abs(supportElevation({ type: 'plant', pos: [2, 6], level: 'ground' }, list, new Set(), levelOf) - 1.3) < 1e-9);
  // Excluding the TV leaves the dresser at 0.84
  assert.equal(supportElevation({ type: 'plant', pos: [2, 6], level: 'ground' }, list, new Set([3]), levelOf), 0.84);
  // Upper floor only sees upper floor dresser (0.84), not ground sofa
  assert.equal(supportElevation({ type: 'pillow', pos: [2, 2], level: 'upper' }, list, new Set(), levelOf), 0.84);
  // Open floor returns 0
  assert.equal(supportElevation({ type: 'pillow', pos: [10, 10], level: 'ground' }, list, new Set(), levelOf), 0);
});

test('stackedRiders finds direct and transitive riders and ignores other levels and wall-mounted TVs', () => {
  const list = [
    { type: 'dresser', pos: [2, 2], level: 'ground' }, // 0: base, top = 0.84
    { type: 'tv', pos: [2, 2], y: 0.84, level: 'ground' }, // 1: direct rider, top = 1.30
    { type: 'plant', pos: [2.1, 2], y: 1.3, level: 'ground' }, // 2: transitive rider on TV console
    { type: 'pillow', pos: [2, 2], y: 0.84, level: 'upper' }, // 3: different level (not a rider)
    { type: 'tv', pos: [2, 2], y: 0.84, variant: 'wall', level: 'ground' }, // 4: wall-mounted TV (not a rider)
    { type: 'pillow', pos: [5, 5], y: 0.84, level: 'ground' }, // 5: outside footprint
  ];
  const levelOf = (f) => f.level ?? 'ground';

  const riders = stackedRiders(0, list, levelOf);
  assert.deepEqual([...riders].sort(), [1, 2]);
});

test('applyOperations validates y, variant, and pillow in plan-edit.js', () => {
  const basePlan = {
    name: 'Test',
    rooms: [{ id: 'living', name: 'Living', rect: [0, 0, 6, 5], floor: 'oak' }],
    openings: [],
    furniture: [],
    lights: [],
    acs: [],
    scenes: [],
  };

  // Valid add_furniture with y, variant, and pillow
  const res = applyOperations(basePlan, [
    {
      op: 'add_furniture',
      items: [
        { type: 'sofa', pos: [2, 2], variant: 'plain' },
        { type: 'pillow', pos: [2, 2], y: 0.47, color: '#d9b98a' },
        { type: 'tv', pos: [2, 0.2], variant: 'wall', y: 1.0 },
        { type: 'vanity', pos: [4, 1], variant: 'cabinet', y: 0 }, // default variant and y:0 stripped
      ],
    },
  ]);

  assert.equal(res.plan.furniture.length, 4);
  assert.equal(res.plan.furniture[0].variant, 'plain');
  assert.equal(res.plan.furniture[1].type, 'pillow');
  assert.equal(res.plan.furniture[1].y, 0.47);
  assert.equal(res.plan.furniture[2].variant, 'wall');
  assert.equal(res.plan.furniture[2].y, 1.0);
  assert.equal('variant' in res.plan.furniture[3], false);
  assert.equal('y' in res.plan.furniture[3], false);

  // Invalid variant rejected
  assert.throws(
    () => applyOperations(basePlan, [{ op: 'add_furniture', item: { type: 'tv', pos: [1, 1], variant: 'bogus' } }]),
    PlanEditError,
  );
  // Variant on unsupported type rejected
  assert.throws(
    () => applyOperations(basePlan, [{ op: 'add_furniture', item: { type: 'bed', pos: [1, 1], variant: 'plain' } }]),
    PlanEditError,
  );
  // Invalid y rejected (negative or >= 12)
  assert.throws(
    () => applyOperations(basePlan, [{ op: 'add_furniture', item: { type: 'pillow', pos: [1, 1], y: -0.2 } }]),
    PlanEditError,
  );
  assert.throws(
    () => applyOperations(basePlan, [{ op: 'add_furniture', item: { type: 'pillow', pos: [1, 1], y: 12 } }]),
    PlanEditError,
  );
});
