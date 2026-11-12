// Loads and normalises a floor plan ("home.json"). Everything the 3D scene and the UI
// know about the apartment comes from this one document, so swapping the file swaps the home.

const LIGHT_TYPES = ['ceiling', 'pendant', 'spots', 'floor', 'table', 'strip'];
const WALLS = ['north', 'south', 'east', 'west'];

export class ConfigError extends Error {}

export const LIGHT_KINDS = LIGHT_TYPES;

// A lamp or an AC is real when it is linked to a device of a connected platform:
// `link: { service, id }` (Home Assistant, Philips Hue, Apple Home) or, for Smart Life,
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
  homekit: { name: 'Apple Home', short: 'Apple Home' },
};
export const FLOOR_KINDS = ['oak', 'walnut', 'tile', 'stone'];

// A home on several floors lists them in "levels", lowest first: [{ id, name, wallHeight? }].
// Rooms, furniture and openings say which one they are on with "level"; lamps and ACs are on
// their room's. Without "levels" (or without "level" on an item) everything is on the first.
export const SLAB = 0.3; // thickness of the floor between two levels, metres

export function levelsOf(raw) {
  const list = Array.isArray(raw?.levels) ? raw.levels.filter((l) => l && typeof l.id === 'string' && l.id) : [];
  return list.length ? list : [{ id: 'main', name: 'Ground floor' }];
}

// The plan exactly as written on disk (the editor works on this form).
export async function loadRawConfig() {
  const boot = window.__HOUSE_BOOT__;
  if (boot?.config) return boot.config;
  const plan = (boot?.plan !== 'custom' && boot?.plan) || new URLSearchParams(location.search).get('plan') || 'home';
  const res = await fetch(`./plans/${plan}.json`);
  if (!res.ok) throw new ConfigError(`Plan "${plan}" not found (HTTP ${res.status})`);
  try {
    return await res.json();
  } catch (e) {
    throw new ConfigError(`Plan "${plan}" is not valid JSON: ${e.message}`);
  }
}

export async function loadConfig() {
  return normalize(await loadRawConfig());
}

function need(cond, msg) {
  if (!cond) throw new ConfigError(msg);
}

const isPoint = (p) => Array.isArray(p) && p.length === 2 && p.every(Number.isFinite);

export function normalize(raw) {
  need(raw && typeof raw === 'object', 'Plan must be a JSON object');
  need(Array.isArray(raw.rooms) && raw.rooms.length > 0, 'Plan needs at least one room in "rooms"');

  const ids = new Set();
  const unique = (id, what) => {
    need(typeof id === 'string' && id, `${what} is missing an "id"`);
    need(!ids.has(id), `Duplicate id "${id}"`);
    ids.add(id);
  };

  const wallHeight = raw.wallHeight ?? 2.6;
  const levelIds = new Set();
  let elevation = 0;
  const levels = levelsOf(raw).map((l) => {
    need(!levelIds.has(l.id), `Duplicate floor id "${l.id}"`);
    levelIds.add(l.id);
    const H = Number.isFinite(l.wallHeight) && l.wallHeight > 0 ? l.wallHeight : wallHeight;
    const level = { id: l.id, name: l.name || l.id, wallHeight: H, elevation };
    elevation += H + SLAB;
    return level;
  });
  const ground = levels[0].id;
  const levelOf = (item, what) => {
    if (item.level == null) return ground;
    need(levelIds.has(item.level), `${what} is on unknown floor "${item.level}"`);
    return item.level;
  };

  const rooms = raw.rooms.map((r) => {
    unique(r.id, 'A room');
    need(Array.isArray(r.rect) && r.rect.length === 4 && r.rect.every(Number.isFinite),
      `Room "${r.id}" needs "rect": [x, z, width, depth]`);
    const [x, z, w, d] = r.rect;
    need(w > 0 && d > 0, `Room "${r.id}" has an empty rect`);
    return { id: r.id, name: r.name || r.id, x, z, w, d, floor: r.floor || 'oak', level: levelOf(r, `Room "${r.id}"`) };
  });
  const roomIds = new Set(rooms.map((r) => r.id));
  const roomLevel = new Map(rooms.map((r) => [r.id, r.level]));

  const openings = (raw.openings || []).map((o, i) => {
    need(isPoint(o.from) && isPoint(o.to), `Opening #${i + 1} needs "from" and "to" points`);
    need(o.from[0] === o.to[0] || o.from[1] === o.to[1], `Opening #${i + 1} must be axis-aligned`);
    return { type: o.type || 'door', from: o.from, to: o.to, sill: o.sill ?? 0.85, head: o.head ?? 2.1, level: levelOf(o, `Opening #${i + 1}`) };
  });

  const lights = (raw.lights || []).map((l) => {
    unique(l.id, 'A light');
    need(roomIds.has(l.room), `Light "${l.id}" refers to unknown room "${l.room}"`);
    need(LIGHT_TYPES.includes(l.type), `Light "${l.id}" has unknown type "${l.type}" (use ${LIGHT_TYPES.join(', ')})`);
    need(isPoint(l.pos), `Light "${l.id}" needs "pos": [x, z]`);
    return {
      ...l,
      name: l.name || l.id,
      rot: l.rot || 0,
      capabilities: l.capabilities || [], // plain smart plugs: on/off only
      level: roomLevel.get(l.room),
    };
  });

  const acs = (raw.acs || []).map((a) => {
    unique(a.id, 'An AC');
    need(roomIds.has(a.room), `AC "${a.id}" refers to unknown room "${a.room}"`);
    need(isPoint(a.pos), `AC "${a.id}" needs "pos": [x, z]`);
    need(WALLS.includes(a.wall), `AC "${a.id}" needs "wall": one of ${WALLS.join(', ')}`);
    return { ...a, name: a.name || a.id, y: a.y ?? 2.2, min: a.min ?? 16, max: a.max ?? 30, level: roomLevel.get(a.room) };
  });

  const scenes = (raw.scenes || []).map((s) => {
    need(typeof s.id === 'string' && s.id, 'A scene is missing an "id"');
    return { id: s.id, name: s.name || s.id, icon: s.icon || 'sun', lights: s.lights || {}, acs: s.acs || {}, toggle: s.toggle === true };
  });

  const furniture = (raw.furniture || []).map((f, i) => {
    const level = levelOf(f, `Furniture #${i + 1}`);
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
    name: raw.name || 'Home',
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
