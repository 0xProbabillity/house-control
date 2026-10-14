// Where the walls of a plan go: every room edge split into wall segments, each knowing what
// kind of wall it is, how thick it is and how far its ends reach. Pure geometry with no
// three.js, so it can be tested on its own (test/walls.test.js); house.js turns it into meshes.
//
// Coordinates are the plan's: metres, x to the east, z to the south. A segment runs along
// `axis` ('x': east–west, at z = c; 'z': north–south, at x = c) from `a` to `b`.

/** Thickness of the building's outer walls, in metres. */
export const OUTER_THICKNESS = 0.2;
/** Thickness of every other wall, in metres. */
export const INNER_THICKNESS = 0.1;

const EPS = 1e-4;
/** Plan coordinates are compared to the millimetre. */
const mm = (v) => Math.round(v * 1000);

/**
 * The plan's walls.
 *
 * Each segment is `{ axis, c, a, b, kind, inside, opening, outline, thickness, from, to }`:
 * - `kind`: 'interior' where two rooms share the edge, 'exterior' where one room ends.
 * - `inside`: which side the room is on (+1: towards larger coordinates), for exterior walls.
 * - `opening`: the door, window or open gap covering the segment, or null.
 * - `outline`: true for an exterior wall on the building's outline. An exterior wall inside
 *   that outline faces a recess (a stairwell, a light well) rather than the outside.
 * - `thickness`: outer thickness on the outline, inner thickness anywhere else. A wall that is
 *   exterior only because it faces a recess usually continues inner walls on the same line;
 *   giving it their thickness keeps the line flat instead of stepping out like a column.
 * - `from`, `to`: `a` and `b` with each free end (one that does not continue along the line)
 *   reaching to the middle of the wall it runs into, so corners and T-junctions close up
 *   without a thin wall's end poking out through the far side of another.
 */
export function planWalls(config) {
  const segments = splitEdges(config);
  const outline = outlineOf(segments);
  for (const s of segments) {
    s.outline = s.kind === 'exterior' && outline[s.axis].some((c) => Math.abs(c - s.c) < EPS);
    s.thickness = s.outline ? OUTER_THICKNESS : INNER_THICKNESS;
  }
  for (const s of segments) {
    s.from = s.a - (s.freeA ? reach(segments, s, s.a) : 0);
    s.to = s.b + (s.freeB ? reach(segments, s, s.b) : 0);
  }
  return segments;
}

/**
 * True for an outline wall on the camera's side of the building: it is drawn cut down so the
 * rooms behind it can be seen. `camDir` is the horizontal direction from the model to the
 * camera, `{ x, z }`. Walls of a recess are never cut: with nothing behind them, a cut-down
 * one reads as an opening into the room.
 */
export function facesCamera(segment, camDir) {
  if (!segment.outline) return false;
  const nx = segment.axis === 'z' ? -segment.inside : 0;
  const nz = segment.axis === 'x' ? -segment.inside : 0;
  return nx * camDir.x + nz * camDir.z > 0.15;
}

// Splits every room edge into segments and attaches the opening that covers each one.
function splitEdges(config) {
  const lines = new Map();
  const line = (axis, c) => {
    const k = `${axis}:${mm(c)}`;
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
    const l = lines.get(alongX ? `x:${mm(o.from[1])}` : `z:${mm(o.from[0])}`);
    if (!l) continue; // an opening that is not on any wall
    const p = alongX ? [o.from[0], o.to[0]] : [o.from[1], o.to[1]];
    l.openings.push({ ...o, a: Math.min(...p), b: Math.max(...p) });
  }

  const segments = [];
  for (const l of lines.values()) {
    const points = [...new Set([...l.edges, ...l.openings].flatMap((e) => [mm(e.a), mm(e.b)]))]
      .sort((p, q) => p - q).map((p) => p / 1000);
    const run = [];
    for (let i = 0; i < points.length - 1; i++) {
      const mid = (points[i] + points[i + 1]) / 2;
      const covering = l.edges.filter((e) => e.a < mid && mid < e.b);
      if (!covering.length) continue;
      const seg = {
        axis: l.axis, c: l.c, a: points[i], b: points[i + 1],
        kind: covering.length > 1 ? 'interior' : 'exterior',
        inside: covering[0].inside,
        opening: l.openings.find((o) => o.a < mid && mid < o.b) || null,
      };
      const prev = run[run.length - 1];
      if (prev && Math.abs(prev.b - seg.a) < EPS && prev.kind === seg.kind
        && prev.inside === seg.inside && prev.opening === seg.opening) prev.b = seg.b;
      else run.push(seg);
    }
    run.forEach((s, i) => {
      s.freeA = !(run[i - 1] && Math.abs(run[i - 1].b - s.a) < EPS);
      s.freeB = !(run[i + 1] && Math.abs(run[i + 1].a - s.b) < EPS);
    });
    segments.push(...run);
  }
  return segments;
}

// The building's outline: the outermost line of real (not open) exterior walls on each side.
function outlineOf(segments) {
  const solid = segments.filter((s) => s.kind === 'exterior' && s.opening?.type !== 'open');
  const extent = (axis) => {
    const cs = solid.filter((s) => s.axis === axis).map((s) => s.c);
    return cs.length ? [Math.min(...cs), Math.max(...cs)] : [];
  };
  return { x: extent('x'), z: extent('z') };
}

// How far a free end at `at` reaches: to the middle of the thickest wall it runs into, or
// nowhere if it stands free.
function reach(segments, s, at) {
  const meets = segments.filter((p) => p.axis !== s.axis && Math.abs(p.c - at) < EPS
    && p.a - EPS <= s.c && s.c <= p.b + EPS);
  return meets.length ? Math.max(...meets.map((p) => p.thickness)) / 2 : 0;
}
