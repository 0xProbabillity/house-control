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

  const rooms = raw.rooms.map((r) => {
    unique(r.id, 'A room');
    need(Array.isArray(r.rect) && r.rect.length === 4 && r.rect.every(Number.isFinite),
      `Room "${r.id}" needs "rect": [x, z, width, depth]`);
    const [x, z, w, d] = r.rect;
    need(w > 0 && d > 0, `Room "${r.id}" has an empty rect`);
    return { id: r.id, name: r.name || r.id, x, z, w, d, floor: r.floor || 'oak' };
  });
  const roomIds = new Set(rooms.map((r) => r.id));

  const openings = (raw.openings || []).map((o, i) => {
    need(isPoint(o.from) && isPoint(o.to), `Opening #${i + 1} needs "from" and "to" points`);
    need(o.from[0] === o.to[0] || o.from[1] === o.to[1], `Opening #${i + 1} must be axis-aligned`);
    return { type: o.type || 'door', from: o.from, to: o.to, sill: o.sill ?? 0.85, head: o.head ?? 2.1 };
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
    };
  });

  const acs = (raw.acs || []).map((a) => {
    unique(a.id, 'An AC');
    need(roomIds.has(a.room), `AC "${a.id}" refers to unknown room "${a.room}"`);
    need(isPoint(a.pos), `AC "${a.id}" needs "pos": [x, z]`);
    need(WALLS.includes(a.wall), `AC "${a.id}" needs "wall": one of ${WALLS.join(', ')}`);
    return { ...a, name: a.name || a.id, y: a.y ?? 2.2, min: a.min ?? 16, max: a.max ?? 30 };
  });

  const scenes = (raw.scenes || []).map((s) => {
    need(typeof s.id === 'string' && s.id, 'A scene is missing an "id"');
    return { id: s.id, name: s.name || s.id, icon: s.icon || 'sun', lights: s.lights || {}, acs: s.acs || {} };
  });

  const minX = Math.min(...rooms.map((r) => r.x));
  const minZ = Math.min(...rooms.map((r) => r.z));
  const maxX = Math.max(...rooms.map((r) => r.x + r.w));
  const maxZ = Math.max(...rooms.map((r) => r.z + r.d));

  return {
    name: raw.name || 'Home',
    wallHeight: raw.wallHeight ?? 2.6,
    interiorWallHeight: raw.interiorWallHeight ?? 1.25,
    camera: { azimuth: raw.camera?.azimuth ?? 34, elevation: raw.camera?.elevation ?? 47 },
    outdoorTemp: raw.outdoorTemp ?? 27,
    rooms,
    openings,
    furniture: raw.furniture || [],
    lights,
    acs,
    scenes,
    bounds: { minX, minZ, maxX, maxZ },
  };
}
