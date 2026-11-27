// Normalize floor plans for the renderer and its consumers.
const LIGHT_TYPES = ['ceiling', 'pendant', 'spots', 'floor', 'table', 'strip'];
const WALLS = ['north', 'south', 'east', 'west'];

export class ConfigError extends Error {}

export const LIGHT_KINDS = LIGHT_TYPES;

// A lamp or an AC is real when it is linked to a device of a connected platform:
// `link: { service, id }` (Home Assistant, Philips Hue, Homebridge, Apple Home) or, for Smart Life,
// `tuya: { deviceId }`. An AC's `sensor: { service, id }` is a thermometer for its room.
export const LINK_FIELDS = ['tuya', 'link', 'sensor'];

export function linkOf(d) {
  if (d?.link?.service && d.link.id) return { service: d.link.service, id: d.link.id };
  if (d?.tuya?.deviceId) return { service: 'smartlife', id: d.tuya.deviceId };
  return null;
}

export const isLinked = (d) => Boolean(linkOf(d));

/** The platforms House Control can link to, in the order the editor lists them. */
export const SERVICES = {
  smartlife: { name: 'Smart Life', short: 'Smart Life' },
  homeassistant: { name: 'Home Assistant', short: 'Home Assistant' },
  hue: { name: 'Philips Hue', short: 'Hue' },
  homebridge: { name: 'Homebridge', short: 'Homebridge' },
  homekit: { name: 'Apple Home', short: 'Apple Home' },
};
export const FLOOR_KINDS = ['oak', 'walnut', 'tile', 'stone'];

/** Where an outlet at `pos` sits: on the nearest wall of `room`, facing into it. `rot` turns
 *  the model's front (+z) into the room; `inset` is half the wall's thickness, so the plate
 *  touches the wall's face (exterior walls are thicker than the ones between two rooms). */
export function wallMount(room, rooms, [x, z]) {
  const walls = [
    { d: z - room.z, pos: [x, room.z], rot: 0, n: [0, 1] },
    { d: room.z + room.d - z, pos: [x, room.z + room.d], rot: 180, n: [0, -1] },
    { d: x - room.x, pos: [room.x, z], rot: 90, n: [1, 0] },
    { d: room.x + room.w - x, pos: [room.x + room.w, z], rot: -90, n: [-1, 0] },
  ];
  const wall = walls.reduce((a, b) => (b.d < a.d ? b : a));
  const along = wall.n[0] ? 1 : 0; // the coordinate that runs along the wall
  const lo = along ? room.z : room.x;
  const hi = along ? room.z + room.d : room.x + room.w;
  const p = [...wall.pos];
  p[along] = Math.min(hi - 0.15, Math.max(lo + 0.15, p[along]));
  // Interior when another room on the same floor lies right behind this wall at that point.
  const behind = [p[0] - wall.n[0] * 0.1, p[1] - wall.n[1] * 0.1];
  const interior = rooms.some((r) => r !== room && r.level === room.level
    && behind[0] > r.x && behind[0] < r.x + r.w && behind[1] > r.z && behind[1] < r.z + r.d);
  const inset = (interior ? 0.05 : 0.1) + 0.002;
  return { pos: [p[0] + wall.n[0] * inset, p[1] + wall.n[1] * inset], rot: wall.rot };
}

// A home on several floors lists them in "levels", lowest first: [{ id, name, wallHeight? }].
// Rooms, furniture and openings say which one they are on with "level"; lamps and ACs are on
// their room's. Without "levels" (or without "level" on an item) everything is on the first.
export const SLAB = 0.3; // thickness of the floor between two levels, metres

function english(text, vars) {
  return vars ? text.replace(/\{(\w+)\}/g, (match, key) => (key in vars ? String(vars[key]) : match)) : text;
}

export function levelsOf(raw, t = english) {
  const list = Array.isArray(raw?.levels) ? raw.levels.filter((l) => l && typeof l.id === 'string' && l.id) : [];
  return list.length ? list : [{ id: 'main', name: t('Ground floor') }];
}

function need(cond, msg) {
  if (!cond) throw new ConfigError(msg);
}

const isPoint = (p) => Array.isArray(p) && p.length === 2 && p.every(Number.isFinite);

export function normalize(raw, t = english) {
  need(raw && typeof raw === 'object', t('Plan must be a JSON object'));
  need(Array.isArray(raw.rooms) && raw.rooms.length > 0, t('Plan needs at least one room in "rooms"'));

  const ids = new Set();
  const unique = (id, missing) => {
    need(typeof id === 'string' && id, missing);
    need(!ids.has(id), t('Duplicate id "{id}"', { id }));
    ids.add(id);
  };

  const wallHeight = raw.wallHeight ?? 2.6;
  const levelIds = new Set();
  let elevation = 0;
  const levels = levelsOf(raw, t).map((l) => {
    need(!levelIds.has(l.id), t('Duplicate floor id "{id}"', { id: l.id }));
    levelIds.add(l.id);
    const H = Number.isFinite(l.wallHeight) && l.wallHeight > 0 ? l.wallHeight : wallHeight;
    const level = { id: l.id, name: l.name || l.id, wallHeight: H, elevation };
    elevation += H + SLAB;
    return level;
  });
  const ground = levels[0].id;
  // `unknown`: the error for an item on a floor the plan does not have, made from that floor's id.
  const levelOf = (item, unknown) => {
    if (item.level == null) return ground;
    need(levelIds.has(item.level), unknown(item.level));
    return item.level;
  };

  const rooms = raw.rooms.map((r) => {
    unique(r.id, t('A room is missing an "id"'));
    need(Array.isArray(r.rect) && r.rect.length === 4 && r.rect.every(Number.isFinite),
      t('Room "{id}" needs "rect": [x, z, width, depth]', { id: r.id }));
    const [x, z, w, d] = r.rect;
    need(w > 0 && d > 0, t('Room "{id}" has an empty rect', { id: r.id }));
    const level = levelOf(r, (floor) => t('Room "{id}" is on unknown floor "{floor}"', { id: r.id, floor }));
    return { id: r.id, name: r.name || r.id, x, z, w, d, floor: r.floor || 'oak', level };
  });
  const roomIds = new Set(rooms.map((r) => r.id));
  const roomLevel = new Map(rooms.map((r) => [r.id, r.level]));

  const openings = (raw.openings || []).map((o, i) => {
    need(isPoint(o.from) && isPoint(o.to), t('Opening #{n} needs "from" and "to" points', { n: i + 1 }));
    need(o.from[0] === o.to[0] || o.from[1] === o.to[1], t('Opening #{n} must be axis-aligned', { n: i + 1 }));
    const level = levelOf(o, (floor) => t('Opening #{n} is on unknown floor "{floor}"', { n: i + 1, floor }));
    return { type: o.type || 'door', from: o.from, to: o.to, sill: o.sill ?? 0.85, head: o.head ?? 2.1, level };
  });

  // An outlet ("outlet": true) is a lamp that looks like a wall socket: on/off only, drawn on
  // the wall of its room nearest to where it was put. Older apps ignore the flag and show a lamp.
  const lights = (raw.lights || []).map((l) => {
    unique(l.id, t('A light is missing an "id"'));
    need(roomIds.has(l.room), t('Light "{id}" refers to unknown room "{room}"', { id: l.id, room: l.room }));
    need(LIGHT_TYPES.includes(l.type), t('Light "{id}" has unknown type "{type}" (use {types})', { id: l.id, type: l.type, types: LIGHT_TYPES.join(', ') }));
    need(isPoint(l.pos), t('Light "{id}" needs "pos": [x, z]', { id: l.id }));
    const outlet = l.outlet === true;
    return {
      ...l,
      name: l.name || l.id,
      rot: l.rot || 0,
      outlet,
      capabilities: outlet ? [] : l.capabilities || [], // plain smart plugs: on/off only
      level: roomLevel.get(l.room),
      ...(outlet ? { mount: wallMount(rooms.find((r) => r.id === l.room), rooms, l.pos) } : {}),
    };
  });

  const acs = (raw.acs || []).map((a) => {
    unique(a.id, t('An AC is missing an "id"'));
    need(roomIds.has(a.room), t('AC "{id}" refers to unknown room "{room}"', { id: a.id, room: a.room }));
    need(isPoint(a.pos), t('AC "{id}" needs "pos": [x, z]', { id: a.id }));
    need(WALLS.includes(a.wall), t('AC "{id}" needs "wall": one of {walls}', { id: a.id, walls: WALLS.join(', ') }));
    return { ...a, name: a.name || a.id, y: a.y ?? 2.2, min: a.min ?? 16, max: a.max ?? 30, level: roomLevel.get(a.room) };
  });

  const scenes = (raw.scenes || []).map((s) => {
    need(typeof s.id === 'string' && s.id, t('A scene is missing an "id"'));
    return { id: s.id, name: s.name || s.id, icon: s.icon || 'sun', lights: s.lights || {}, acs: s.acs || {}, toggle: s.toggle === true };
  });

  const furniture = (raw.furniture || []).map((f, i) => {
    const level = levelOf(f, (floor) => t('Furniture #{n} is on unknown floor "{floor}"', { n: i + 1, floor }));
    // Stairs climb to the floor above unless told otherwise.
    const H = levels.find((l) => l.id === level).wallHeight;
    return f.type === 'stairs' && f.height == null ? { ...f, level, height: H + SLAB } : { ...f, level };
  });

  const box = (rs) => ({
    minX: Math.min(...rs.map((r) => r.x)),
    minZ: Math.min(...rs.map((r) => r.z)),
    maxX: Math.max(...rs.map((r) => r.x + r.w)),
    maxZ: Math.max(...rs.map((r) => r.z + r.d)),
  });
  // A floor with no rooms yet borrows the outline of the whole home.
  const all = box(rooms);
  for (const l of levels) {
    const own = rooms.filter((r) => r.level === l.id);
    l.bounds = own.length ? box(own) : all;
  }

  return {
    name: raw.name || t('Home'),
    wallHeight,
    interiorWallHeight: raw.interiorWallHeight ?? 1.25,
    camera: { azimuth: raw.camera?.azimuth ?? 34, elevation: raw.camera?.elevation ?? 47 },
    outdoorTemp: raw.outdoorTemp ?? 27,
    levels,
    rooms,
    openings,
    furniture,
    lights,
    acs,
    scenes,
    bounds: all,
  };
}
