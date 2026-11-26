// Turns the rooms + openings of a plan into floors, walls and windows.
import * as THREE from 'three';
import { box, mat, at, floorMesh } from './kit.js';
import { SLAB } from '../config.js';

const EXT_T = 0.2;   // exterior wall thickness
const INT_T = 0.1;   // interior wall thickness
const CURB = 0.14;   // height of the cut-away walls on the camera side
const EPS = 1e-4;
const NEAR = 0.15;   // how squarely an outer wall must face the camera to be cut away
const NEAR_BAND = 0.05; // ...and how far past that before it changes its mind
const WALL_TIME = 0.28; // seconds for a wall to sink or rise

const key = (v) => Math.round(v * 1000);

// Splits every room edge into wall segments, classifying each as exterior / interior
// and attaching the opening (door, window, ...) that covers it, if any.
function wallSegments(config) {
  const lines = new Map();
  const line = (axis, c) => {
    const k = `${axis}:${key(c)}`;
    if (!lines.has(k)) lines.set(k, { axis, c, edges: [], openings: [] });
    return lines.get(k);
  };

  for (const r of config.rooms) {
    line('x', r.z).edges.push({ a: r.x, b: r.x + r.w, inside: 1 });
    line('x', r.z + r.d).edges.push({ a: r.x, b: r.x + r.w, inside: -1 });
    line('z', r.x).edges.push({ a: r.z, b: r.z + r.d, inside: 1 });
    line('z', r.x + r.w).edges.push({ a: r.z, b: r.z + r.d, inside: -1 });
  }
  for (const o of config.openings) {
    const alongX = o.from[1] === o.to[1];
    const k = alongX ? `x:${key(o.from[1])}` : `z:${key(o.from[0])}`;
    const l = lines.get(k);
    if (!l) continue; // opening that is not on any wall: ignore
    const p = alongX ? [o.from[0], o.to[0]] : [o.from[1], o.to[1]];
    l.openings.push({ ...o, a: Math.min(...p), b: Math.max(...p) });
  }

  const segments = [];
  for (const l of lines.values()) {
    const pts = [...new Set([...l.edges, ...l.openings].flatMap((e) => [key(e.a), key(e.b)]))]
      .sort((p, q) => p - q).map((p) => p / 1000);
    const run = [];
    for (let i = 0; i < pts.length - 1; i++) {
      const mid = (pts[i] + pts[i + 1]) / 2;
      const covering = l.edges.filter((e) => e.a < mid && mid < e.b);
      if (!covering.length) continue;
      const seg = {
        axis: l.axis, c: l.c, a: pts[i], b: pts[i + 1],
        kind: covering.length > 1 ? 'interior' : 'exterior',
        inside: covering[0].inside,
        opening: l.openings.find((o) => o.a < mid && mid < o.b) || null,
      };
      const prev = run[run.length - 1];
      if (prev && Math.abs(prev.b - seg.a) < EPS && prev.kind === seg.kind
        && prev.inside === seg.inside && prev.opening === seg.opening) prev.b = seg.b;
      else run.push(seg);
    }
    // Free ends get a small extension so corners close up.
    run.forEach((s, i) => {
      s.freeA = !(run[i - 1] && Math.abs(run[i - 1].b - s.a) < EPS);
      s.freeB = !(run[i + 1] && Math.abs(run[i + 1].a - s.b) < EPS);
    });
    segments.push(...run);
  }
  return segments;
}

// One floor of the home, standing on y = 0: `level` is one of config.levels. The lowest
// stands on a plinth; a floor above it rests on a slab under each of its rooms.
// The outer walls facing the camera sink to a curb so the rooms stay in view: `view()` says
// where the camera is, `update()` moves the walls and reports when they have stopped.
export function buildHouse(config, level = config.levels[0]) {
  const group = new THREE.Group();
  const floors = [];
  const H = level.wallHeight;
  const Hi = Math.min(config.interiorWallHeight, H);
  const rooms = config.rooms.filter((r) => r.level === level.id);
  const openings = config.openings.filter((o) => o.level === level.id);
  const { minX, minZ, maxX, maxZ } = level.bounds;

  if (level.elevation === 0) {
    // Plinth the model stands on.
    const plinth = box(maxX - minX + 0.7, 0.3, maxZ - minZ + 0.7, mat('#141927', { rough: 0.9 }), { r: 0.12 });
    at(plinth, (minX + maxX) / 2, -0.305, (minZ + maxZ) / 2);
    plinth.receiveShadow = true;
    group.add(plinth);
  } else {
    const slab = mat('#1d2232', { rough: 0.9 });
    for (const r of rooms) {
      const s = box(r.w + EXT_T, SLAB - 0.01, r.d + EXT_T, slab, { r: 0 });
      at(s, r.x + r.w / 2, -SLAB, r.z + r.d / 2);
      s.receiveShadow = true;
      group.add(s);
    }
  }

  for (const room of rooms) {
    const floor = floorMesh(room, room.floor);
    floor.userData = { kind: 'room', id: room.id };
    floors.push(floor);
    group.add(floor);
  }

  const wallBody = mat('#e7e3db', { rough: 0.95 });
  const wallCap = mat('#262b3a', { rough: 0.8 });
  const wallMats = [wallBody, wallBody, wallCap, wallBody, wallBody, wallBody];
  const blocker = new THREE.MeshBasicMaterial({ colorWrite: false, depthWrite: false });
  const glass = new THREE.MeshStandardMaterial({
    color: '#9cc0ff', roughness: 0.08, transparent: true, opacity: 0.22,
    emissive: '#3d5fae', emissiveIntensity: 0.5,
  });
  const frostedGlass = mat('#e0e9e8', { rough: 0.75 });
  const frame = mat('#2c3142', { rough: 0.6 });
  const sashFrame = mat('#363c50', { rough: 0.55 });
  const sillLedge = mat('#d9d5cd', { rough: 0.75 });
  const hardware = mat('#c2c7cf', { metal: 0.75, rough: 0.28 });

  const shiftSeg = (s, offset) => ({ ...s, c: s.c + s.inside * offset });

  // A wall piece running from a..b along its axis, between heights y0..y1.
  const piece = (s, a, b, y0, y1, t, materials = wallMats, parent = group) => {
    const len = b - a;
    const geo = s.axis === 'x' ? new THREE.BoxGeometry(len, y1 - y0, t) : new THREE.BoxGeometry(t, y1 - y0, len);
    const m = new THREE.Mesh(geo, materials);
    const mid = (a + b) / 2;
    m.position.set(s.axis === 'x' ? mid : s.c, (y0 + y1) / 2, s.axis === 'x' ? s.c : mid);
    m.castShadow = m.receiveShadow = true;
    parent.add(m);
    return m;
  };

  // The four sides of the floor, each with its outer walls standing and cut away.
  const sides = new Map();
  const sideOf = (nx, nz) => {
    const k = `${nx},${nz}`;
    if (!sides.has(k)) {
      const side = { nx, nz, tall: new THREE.Group(), curb: new THREE.Group(), near: null, up: 1 };
      group.add(side.tall, side.curb);
      sides.set(k, side);
    }
    return sides.get(k);
  };

  for (const s of wallSegments({ rooms, openings })) {
    const exterior = s.kind === 'exterior';
    const t = exterior ? EXT_T : INT_T;
    const a = s.a - (s.freeA ? EXT_T / 2 : 0);
    const b = s.b + (s.freeB ? EXT_T / 2 : 0);
    const type = s.opening?.type;
    let parent = group;

    if (exterior) {
      // Outward normal of an exterior wall points away from its room.
      const side = sideOf(s.axis === 'z' ? -s.inside : 0, s.axis === 'x' ? -s.inside : 0);
      if (type !== 'door') piece(s, a, b, 0, CURB, t, wallMats, side.curb);
      parent = side.tall;
    }
    const height = exterior ? H : Hi;
    if (type === 'door') {
      if (Number.isFinite(s.opening.head) && s.opening.head > 0 && s.opening.head < height) {
        piece(s, a, b, s.opening.head, height, t, wallMats, parent);
      }
      continue;
    }
    if (type === 'open') continue;

    if (type === 'window' && exterior) {
      const { sill, head } = s.opening;
      piece(s, a, b, 0, sill, t, wallMats, parent);
      piece(s, a, b, Math.min(head, H), H, t, wallMats, parent);
      piece(shiftSeg(s, 0.015), a - 0.02, b + 0.02, sill - 0.018, sill + 0.014, t + 0.05, sillLedge, parent);
      const fw = 0.05;
      for (const [fa, fb, y0, y1] of [
        [a, a + fw, sill, head],
        [b - fw, b, sill, head],
        [a, b, sill, sill + fw],
        [a, b, head - fw, head],
      ]) piece(s, fa, fb, y0, y1, 0.09, frame, parent);

      const glazing = s.opening.frosted ? frostedGlass : glass;
      if (s.opening.sash === 'upperSliding') {
        const mid = (sill + head) / 2;
        const sw = 0.024;
        const cx = (a + b) / 2;
        const lowerSeg = shiftSeg(s, -0.016);
        const lowerPane = piece(lowerSeg, a + fw, b - fw, sill + fw, mid + 0.008, 0.018, glazing, parent);
        lowerPane.castShadow = false;
        piece(lowerSeg, a + fw, b - fw, mid - 0.006, mid + 0.014, 0.026, sashFrame, parent);

        const upperSeg = shiftSeg(s, 0.016);
        const upperPane = piece(upperSeg, a + fw + sw, b - fw - sw, mid - 0.004, head - fw - sw, 0.018, glazing, parent);
        upperPane.castShadow = false;
        for (const [fa, fb, y0, y1] of [
          [a + fw, a + fw + sw, mid - 0.012, head - fw],
          [b - fw - sw, b - fw, mid - 0.012, head - fw],
          [a + fw, b - fw, head - fw - sw, head - fw],
          [a + fw, b - fw, mid - 0.012, mid - 0.012 + sw],
        ]) piece(upperSeg, fa, fb, y0, y1, 0.032, sashFrame, parent);
        piece(shiftSeg(s, 0.042), cx - 0.045, cx + 0.045, mid - 0.008, mid + 0.012, 0.016, hardware, parent);
      } else if (s.opening.sash === 'casement') {
        const gap = 0.008;
        const inset = fw + gap;
        const sw = 0.034;
        const stopSeg = shiftSeg(s, -0.022);
        for (const [fa, fb, y0, y1] of [
          [a + fw, a + inset + 0.01, sill + fw, head - fw],
          [b - inset - 0.01, b - fw, sill + fw, head - fw],
          [a + fw, b - fw, sill + fw, sill + inset + 0.01],
          [a + fw, b - fw, head - inset - 0.01, head - fw],
        ]) piece(stopSeg, fa, fb, y0, y1, 0.026, frame, parent);

        const sashSeg = shiftSeg(s, 0.012);
        const pane = piece(sashSeg, a + inset + sw, b - inset - sw, sill + inset + sw, head - inset - sw, 0.018, glazing, parent);
        pane.castShadow = false;
        for (const [fa, fb, y0, y1] of [
          [a + inset, a + inset + sw, sill + inset, head - inset],
          [b - inset - sw, b - inset, sill + inset, head - inset],
          [a + inset, b - inset, sill + inset, sill + inset + sw],
          [a + inset, b - inset, head - inset - sw, head - inset],
        ]) piece(sashSeg, fa, fb, y0, y1, 0.052, sashFrame, parent);

        const handleX = b - inset - sw / 2;
        const midY = (sill + head) / 2;
        piece(shiftSeg(s, 0.045), handleX - 0.012, handleX + 0.012, midY - 0.032, midY + 0.032, 0.012, hardware, parent);
        piece(shiftSeg(s, 0.058), handleX - 0.007, handleX + 0.007, midY - 0.007, midY + 0.007, 0.024, hardware, parent);
        piece(shiftSeg(s, 0.072), handleX - 0.007, handleX + 0.007, midY - 0.095, midY + 0.008, 0.014, hardware, parent);

        const hingeX = a + inset + 0.006;
        const sashY0 = sill + inset;
        const sashH = head - inset - sashY0;
        for (const frac of [0.2, 0.8]) {
          const hy = sashY0 + sashH * frac;
          piece(shiftSeg(s, 0.044), hingeX - 0.007, hingeX + 0.007, hy - 0.024, hy + 0.024, 0.014, hardware, parent);
        }
      } else {
        const pane = piece(s, a + fw, b - fw, sill + fw, head - fw, 0.024, glazing, parent);
        pane.castShadow = false;
        if (s.opening.panes === 2 || (s.opening.panes !== 1 && b - a > 1.2)) {
          piece(s, (a + b) / 2 - fw / 2, (a + b) / 2 + fw / 2, sill, head, 0.07, frame, parent);
        }
      }
      continue;
    }
    if (type === 'window') continue; // a window in an interior wall is just a gap

    piece(s, a, b, 0, height, t, wallMats, parent);
    // Interior walls are drawn cut low, but lamps should still be contained by the
    // real, full-height wall: an invisible shadow caster fills in the missing part.
    if (!exterior && Hi < H) piece(s, a, b, Hi, H, 0.04, blocker).receiveShadow = false;
  }

  const low = CURB / H;
  const pose = (side) => {
    const sunk = side.up === 0;
    side.curb.visible = sunk;
    side.tall.visible = !sunk;
    side.tall.scale.y = low + (1 - low) * side.up * side.up * (3 - 2 * side.up);
  };

  return {
    group,
    floors,
    // The camera looks from (dx, dz), a horizontal unit vector. The first call sets the walls at once.
    view(dx, dz) {
      for (const side of sides.values()) {
        const facing = side.nx * dx + side.nz * dz;
        if (side.near === null) {
          side.near = facing > NEAR;
          side.up = side.near ? 0 : 1;
          pose(side);
        } else {
          side.near = facing > NEAR + (side.near ? -NEAR_BAND : NEAR_BAND);
        }
      }
    },
    // Returns 'moving' while a wall is sinking or rising, 'stopped' on the frame the last one
    // comes to rest (the shadows are out of date then), and null otherwise.
    update(dt) {
      let moving = false;
      let stopped = false;
      for (const side of sides.values()) {
        const goal = side.near ? 0 : 1;
        if (side.up === goal) continue;
        const step = dt / WALL_TIME;
        side.up = goal > side.up ? Math.min(goal, side.up + step) : Math.max(goal, side.up - step);
        pose(side);
        if (side.up === goal) stopped = true;
        else moving = true;
      }
      return moving ? 'moving' : stopped ? 'stopped' : null;
    },
  };
}
