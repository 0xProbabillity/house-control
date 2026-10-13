// Turns the rooms + openings of a plan into floors, walls and windows.
import * as THREE from 'three';
import { box, mat, at, floorMesh } from './kit.js';

const EXT_T = 0.2;   // exterior wall thickness
const INT_T = 0.1;   // interior wall thickness
const CURB = 0.14;   // height of the cut-away walls on the camera side
const EPS = 1e-4;

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

export function buildHouse(config, camDir) {
  const group = new THREE.Group();
  const floors = [];
  const H = config.wallHeight;
  const Hi = Math.min(config.interiorWallHeight, H);
  const { minX, minZ, maxX, maxZ } = config.bounds;

  // Plinth the model stands on.
  const plinth = box(maxX - minX + 0.7, 0.3, maxZ - minZ + 0.7, mat('#141927', { rough: 0.9 }), { r: 0.12 });
  at(plinth, (minX + maxX) / 2, -0.305, (minZ + maxZ) / 2);
  plinth.receiveShadow = true;
  group.add(plinth);

  for (const room of config.rooms) {
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
  const frame = mat('#2c3142', { rough: 0.6 });

  // A wall piece running from a..b along its axis, between heights y0..y1.
  const piece = (s, a, b, y0, y1, t, materials = wallMats) => {
    const len = b - a;
    const geo = s.axis === 'x' ? new THREE.BoxGeometry(len, y1 - y0, t) : new THREE.BoxGeometry(t, y1 - y0, len);
    const m = new THREE.Mesh(geo, materials);
    const mid = (a + b) / 2;
    m.position.set(s.axis === 'x' ? mid : s.c, (y0 + y1) / 2, s.axis === 'x' ? s.c : mid);
    m.castShadow = m.receiveShadow = true;
    group.add(m);
    return m;
  };

  for (const s of wallSegments(config)) {
    const exterior = s.kind === 'exterior';
    const t = exterior ? EXT_T : INT_T;
    // Outward normal of an exterior wall points away from its room.
    const nx = s.axis === 'z' ? -s.inside : 0;
    const nz = s.axis === 'x' ? -s.inside : 0;
    const near = exterior && nx * camDir.x + nz * camDir.z > 0.15;
    const a = s.a - (s.freeA ? EXT_T / 2 : 0);
    const b = s.b + (s.freeB ? EXT_T / 2 : 0);
    const type = s.opening?.type;

    if (near) {
      if (type !== 'door') piece(s, a, b, 0, CURB, t);
      continue;
    }
    if (type === 'door' || type === 'open') continue;

    const height = exterior ? H : Hi;
    if (type === 'window' && exterior) {
      const { sill, head } = s.opening;
      piece(s, a, b, 0, sill, t);
      piece(s, a, b, Math.min(head, H), H, t);
      const pane = piece(s, a, b, sill, head, 0.03, glass);
      pane.castShadow = false;
      const fw = 0.05;
      const bars = [[a, a + fw, sill, head], [b - fw, b, sill, head], [a, b, sill, sill + fw], [a, b, head - fw, head]];
      if (b - a > 1.2) bars.push([(a + b) / 2 - fw / 2, (a + b) / 2 + fw / 2, sill, head]);
      for (const [fa, fb, y0, y1] of bars) piece(s, fa, fb, y0, y1, 0.07, frame);
      continue;
    }
    if (type === 'window') continue; // a window in an interior wall is just a gap

    piece(s, a, b, 0, height, t);
    // Interior walls are drawn cut low, but lamps should still be contained by the
    // real, full-height wall: an invisible shadow caster fills in the missing part.
    if (!exterior && Hi < H) piece(s, a, b, Hi, H, 0.04, blocker).receiveShadow = false;
  }

  return { group, floors };
}
