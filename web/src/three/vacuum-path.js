// Where a robot vacuum drives, worked out from the floor plan alone. Home Assistant says
// "cleaning" but not where the robot is, so the 3D view shows a plausible run instead: every
// room the dock's room leads to through doors and open passages, back and forth in lanes,
// from one room to the next through the middle of their doorways. Plain functions on the
// normalised plan (config.js), with no Three.js, so they can be checked under Node.

export const ROBOT_RADIUS = 0.17;
export const LANE = 0.35;   // between two passes, about a robot's width with some overlap
export const INSET = 0.3;   // kept from every wall: half a wall plus the robot, plus a little
const DOOR_DEPTH = 0.32;    // how far into a room the robot lines up before a doorway
const DOCK_GAP = 0.17;      // from the wall line to the middle of the dock
const DOCKED = 0.23;        // from the middle of the dock to the middle of a docked robot
const CLEAR_OF_DOCK = 0.5;  // from the dock's wall to the robot's middle while it cleans
const UNDOCK = 0.62;        // where it turns round in front of the dock
const EPS = 1e-6;

const clamp = (v, a, b) => Math.min(b, Math.max(a, v));
const near = (a, b) => Math.abs(a - b) < 1e-3;

/** The part of a room the robot's centre can reach: its rectangle less INSET all round. */
export function reach(room) {
  const x0 = room.x + INSET;
  const x1 = room.x + room.w - INSET;
  const z0 = room.z + INSET;
  const z1 = room.z + room.d - INSET;
  // A room too small to drive in still has a middle to stand on.
  return {
    x0: x0 <= x1 ? x0 : room.x + room.w / 2, x1: x0 <= x1 ? x1 : room.x + room.w / 2,
    z0: z0 <= z1 ? z0 : room.z + room.d / 2, z1: z0 <= z1 ? z1 : room.z + room.d / 2,
  };
}

const inside = (r, x, z) => x >= r.x - EPS && x <= r.x + r.w + EPS && z >= r.z - EPS && z <= r.z + r.d + EPS;

/**
 * Rooms and the doorways between them. A door or an open passage joins the two rooms on
 * either side of it, where it is wide enough for the robot; a window, a door to the outside
 * or a gap too narrow to pass joins nothing.
 * Returns { rooms: Map(id → room), links: Map(id → [{ to, door, from: [x, z], into: [x, z] }]) }:
 * `from` is where the robot lines up in this room, `door` the middle of the doorway, `into`
 * where it comes out in the other room.
 */
export function roomGraph(config) {
  const rooms = new Map(config.rooms.map((r) => [r.id, r]));
  const links = new Map(config.rooms.map((r) => [r.id, []]));
  const best = new Map(); // "a|b" → the widest doorway between the two rooms

  for (const o of config.openings) {
    if (o.type !== 'door' && o.type !== 'open') continue;
    const alongX = o.from[1] === o.to[1];
    const c = alongX ? o.from[1] : o.from[0];
    const lo = Math.min(alongX ? o.from[0] : o.from[1], alongX ? o.to[0] : o.to[1]);
    const hi = Math.max(alongX ? o.from[0] : o.from[1], alongX ? o.to[0] : o.to[1]);
    // The room that ends on the wall line, and the one that starts on it.
    const before = config.rooms.filter((r) => near(alongX ? r.z + r.d : r.x + r.w, c));
    const after = config.rooms.filter((r) => near(alongX ? r.z : r.x, c));
    for (const a of before) {
      for (const b of after) {
        const span = (r) => (alongX ? [r.x, r.x + r.w] : [r.z, r.z + r.d]);
        const from = Math.max(lo, span(a)[0], span(b)[0]);
        const to = Math.min(hi, span(a)[1], span(b)[1]);
        if (to - from < ROBOT_RADIUS * 2 + 0.08) continue;
        // Through the middle, but where both rooms can be driven in, if the doorway allows.
        const ra = reach(a);
        const rb = reach(b);
        const lo2 = Math.max(from + ROBOT_RADIUS, alongX ? Math.max(ra.x0, rb.x0) : Math.max(ra.z0, rb.z0));
        const hi2 = Math.min(to - ROBOT_RADIUS, alongX ? Math.min(ra.x1, rb.x1) : Math.min(ra.z1, rb.z1));
        const mid = lo2 <= hi2 ? (lo2 + hi2) / 2 : (from + to) / 2;
        const door = alongX ? [mid, c] : [c, mid];
        const inA = alongX ? [mid, c - DOOR_DEPTH] : [c - DOOR_DEPTH, mid];
        const inB = alongX ? [mid, c + DOOR_DEPTH] : [c + DOOR_DEPTH, mid];
        const key = [a.id, b.id].sort().join('|');
        if ((best.get(key)?.width ?? 0) >= to - from) continue;
        best.set(key, { a: a.id, b: b.id, door, inA, inB, width: to - from });
      }
    }
  }
  for (const { a, b, door, inA, inB } of best.values()) {
    links.get(a).push({ to: b, door, from: inA, into: inB });
    links.get(b).push({ to: a, door, from: inB, into: inA });
  }
  return { rooms, links };
}

/** Room ids reachable from `start`, nearest first (breadth-first). */
export function reachable(graph, start) {
  const seen = [start];
  for (let i = 0; i < seen.length; i++) {
    for (const l of graph.links.get(seen[i]) || []) if (!seen.includes(l.to)) seen.push(l.to);
  }
  return seen;
}

/** The doorways to pass from room `a` to room `b`: the fewest of them, or null. */
export function hops(graph, a, b) {
  if (a === b) return [];
  const back = new Map([[a, null]]);
  const queue = [a];
  while (queue.length) {
    const id = queue.shift();
    for (const l of graph.links.get(id) || []) {
      if (back.has(l.to)) continue;
      back.set(l.to, { from: id, link: l });
      if (l.to === b) {
        const out = [];
        for (let at = b; back.get(at); at = back.get(at).from) out.unshift(back.get(at).link);
        return out;
      }
      queue.push(l.to);
    }
  }
  return null;
}

/**
 * Waypoints from a point in one room to a point in another, through the doorways between
 * them. Each waypoint is { x, z, room }: the room the robot is in once it gets there.
 * Inside a room it drives straight, which is safe: a room is a rectangle.
 */
export function route(graph, from, to) {
  const path = hops(graph, from.room, to.room);
  if (!path) return null;
  const out = [];
  let room = from.room;
  for (const l of path) {
    const r = reach(graph.rooms.get(room));
    out.push({ x: clamp(l.from[0], r.x0, r.x1), z: clamp(l.from[1], r.z0, r.z1), room });
    out.push({ x: l.door[0], z: l.door[1], room });
    room = l.to;
    // A room shallower than DOOR_DEPTH (a closet) is only driven into as far as it allows.
    const n = reach(graph.rooms.get(room));
    out.push({ x: clamp(l.into[0], n.x0, n.x1), z: clamp(l.into[1], n.z0, n.z1), room });
  }
  out.push({ x: to.x, z: to.z, room: to.room });
  return out;
}

/**
 * Cleaning one room: once round its edge, then back and forth along its longer side, from
 * the corner nearest to `entry` ([x, z], where the robot comes in). `r` is the part of the
 * room to cover, the whole reachable part by default.
 */
export function lanes(room, entry, r = reach(room)) {
  const wide = r.x1 - r.x0 >= r.z1 - r.z0;
  // Long axis `u` (along a lane), short axis `v` (across the lanes).
  const [u0, u1, v0, v1] = wide ? [r.x0, r.x1, r.z0, r.z1] : [r.z0, r.z1, r.x0, r.x1];
  const [eu, ev] = wide ? entry : [entry[1], entry[0]];
  const uStart = Math.abs(eu - u0) <= Math.abs(eu - u1) ? u0 : u1;
  const uEnd = uStart === u0 ? u1 : u0;
  const vStart = Math.abs(ev - v0) <= Math.abs(ev - v1) ? v0 : v1;
  const vEnd = vStart === v0 ? v1 : v0;
  const pt = (u, v) => (wide ? { x: u, z: v, room: room.id } : { x: v, z: u, room: room.id });

  const out = [pt(uStart, vStart), pt(uEnd, vStart), pt(uEnd, vEnd), pt(uStart, vEnd), pt(uStart, vStart)];
  const n = Math.max(1, Math.ceil(Math.abs(vEnd - vStart) / LANE));
  for (let i = 0; i <= n; i++) {
    const v = vStart + ((vEnd - vStart) * i) / n;
    const [a, b] = i % 2 ? [uEnd, uStart] : [uStart, uEnd];
    if (i) out.push(pt(a, v));
    out.push(pt(b, v));
  }
  // Points that coincide (a room too small for lanes) would only make it spin.
  return out.filter((p, i) => !i || Math.hypot(p.x - out[i - 1].x, p.z - out[i - 1].z) > 1e-4);
}

/** The part of the dock's room a robot cleans without driving over the dock (dockPose). */
export function aroundDock(room, dock) {
  const r = { ...reach(room) };
  const keep = (lo, hi, key, v) => { if (v >= r[lo] && v <= r[hi]) r[key] = v; };
  if (dock.nz > 0.5) keep('z0', 'z1', 'z0', room.z + CLEAR_OF_DOCK);
  else if (dock.nz < -0.5) keep('z0', 'z1', 'z1', room.z + room.d - CLEAR_OF_DOCK);
  else if (dock.nx > 0.5) keep('x0', 'x1', 'x0', room.x + CLEAR_OF_DOCK);
  else if (dock.nx < -0.5) keep('x0', 'x1', 'x1', room.x + room.w - CLEAR_OF_DOCK);
  return r;
}

/**
 * One cleaning run: from `start` ({ x, z, room }) through every room it can reach, the
 * room it starts in first, each next room the nearest one not cleaned yet. With `dock`
 * (dockPose) its room is cleaned around the dock instead of over it.
 */
export function tour(graph, start, dock = null) {
  const out = [];
  const todo = reachable(graph, start.room);
  let at = { ...start };
  while (todo.length) {
    // Fewest doorways away, so it does not cross the home twice.
    let next = 0;
    let fewest = Infinity;
    todo.forEach((id, i) => {
      const n = hops(graph, at.room, id)?.length ?? Infinity;
      if (n < fewest) { fewest = n; next = i; }
    });
    const [id] = todo.splice(next, 1);
    const room = graph.rooms.get(id);
    const way = id === at.room ? [] : route(graph, at, { ...at, room: id });
    // `route` ends where it came in: the lanes start from there.
    if (way) way.pop();
    const entry = way?.length ? [way[way.length - 1].x, way[way.length - 1].z] : [at.x, at.z];
    const sweep = lanes(room, entry, dock && dock.room === id ? aroundDock(room, dock) : reach(room));
    out.push(...(way || []), ...sweep);
    at = sweep[sweep.length - 1];
  }
  return out;
}

/**
 * Where the dock stands and how a robot sits on it. The dock backs onto the nearest wall of
 * its room, unless the plan turns it with `rot` (the furniture convention: 0 faces south).
 * Returns { x, z, nx, nz, room, docked: { x, z }, out: { x, z } }: the dock's middle, the
 * way it faces (into the room), where a docked robot's middle is, and the point in front
 * of it where the robot turns round to back onto it.
 */
export function dockPose(room, pos, rot) {
  let [x, z] = pos;
  let nx = 0;
  let nz = 1;
  if (Number.isFinite(rot)) {
    const a = (rot * Math.PI) / 180;
    nx = Math.sin(a);
    nz = Math.cos(a);
  } else {
    const walls = [
      [Math.abs(z - room.z), 0, 1], [Math.abs(room.z + room.d - z), 0, -1],
      [Math.abs(x - room.x), 1, 0], [Math.abs(room.x + room.w - x), -1, 0],
    ].sort((p, q) => p[0] - q[0]);
    [, nx, nz] = walls[0];
    // Up against that wall, and far enough from the corners for a robot to sit on it.
    const r = reach(room);
    if (nz) { x = clamp(x, r.x0, r.x1); z = (nz > 0 ? room.z : room.z + room.d) + nz * DOCK_GAP; }
    else { z = clamp(z, r.z0, r.z1); x = (nx > 0 ? room.x : room.x + room.w) + nx * DOCK_GAP; }
  }
  const r = reach(room);
  const fit = (p) => ({ x: clamp(p[0], r.x0, r.x1), z: clamp(p[1], r.z0, r.z1) });
  return {
    x, z, nx, nz, room: room.id,
    docked: { x: x + nx * DOCKED, z: z + nz * DOCKED },
    out: fit([x + nx * UNDOCK, z + nz * UNDOCK]),
  };
}

/** The room a point stands in, preferring `hint` where rooms touch. */
export function roomAt(config, [x, z], hint) {
  const own = config.rooms.find((r) => r.id === hint);
  if (own && inside(own, x, z)) return own;
  return config.rooms.find((r) => inside(r, x, z)) || own || null;
}

/** Length of a path of waypoints, starting at `from` ({ x, z }). */
export function pathLength(from, points) {
  let len = 0;
  let p = from;
  for (const q of points) { len += Math.hypot(q.x - p.x, q.z - p.z); p = q; }
  return len;
}
