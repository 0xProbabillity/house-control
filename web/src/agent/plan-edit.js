// Edits to the floor plan an AI asks for: small, checked operations on the plan as it is
// written on disk. Nothing here touches the page, so it runs (and is tested) under Node too.
import { normalize, LIGHT_KINDS, FLOOR_KINDS, LINK_FIELDS, isLinked } from '../config.js';
import { FURNITURE_TYPES, footprint } from '../three/furniture.js';

export const SCENE_ICONS = ['sun', 'sofa', 'film', 'moon', 'door', 'bed', 'tv', 'sparkles'];
export const WALLS = ['north', 'south', 'east', 'west'];
const FURNITURE_KEYS = ['type', 'pos', 'rot', 'width', 'height', 'size', 'color', 'chairs', 'stools', 'upper'];
const LIGHT_KEYS = ['id', 'name', 'room', 'type', 'pos', 'y', 'rot', 'length', 'capabilities', 'color'];
const AC_KEYS = ['id', 'name', 'room', 'wall', 'pos', 'y', 'min', 'max'];

export class PlanEditError extends Error {}

const fail = (msg) => { throw new PlanEditError(msg); };
const isNum = (v) => typeof v === 'number' && Number.isFinite(v);
const isPoint = (p) => Array.isArray(p) && p.length === 2 && p.every(isNum);
const round = (v) => Math.round(v * 100) / 100;
const pick = (obj, keys) => Object.fromEntries(Object.entries(obj || {}).filter(([k]) => keys.includes(k)));

/** The plan as an AI sees it: links to real hardware are replaced by `"linked": true`. */
export function redactPlan(raw) {
  const plan = structuredClone(raw);
  for (const list of [plan.lights || [], plan.acs || []]) {
    for (const d of list) {
      if (LINK_FIELDS.some((k) => d[k])) {
        for (const k of LINK_FIELDS) delete d[k];
        d.linked = true;
      }
    }
  }
  return plan;
}

/** Puts the hardware links of `old` back into a plan an AI wrote from a redacted copy. */
export function restoreLinks(plan, old) {
  for (const key of ['lights', 'acs']) {
    const links = new Map((old[key] || []).map((d) => [d.id, pick(d, LINK_FIELDS)]));
    for (const d of plan[key] || []) {
      delete d.linked;
      for (const k of LINK_FIELDS) delete d[k]; // an AI cannot invent links to devices; they are made in the editor
      Object.assign(d, links.get(d.id) || {});
    }
  }
  return plan;
}

function cleanFurniture(item, where) {
  if (!item || typeof item !== 'object') fail(`${where}: a furniture item must be an object`);
  if (!FURNITURE_TYPES.includes(item.type)) fail(`${where}: unknown furniture type "${item.type}". Use one of: ${FURNITURE_TYPES.join(', ')}`);
  if (!isPoint(item.pos)) fail(`${where}: "pos" must be [x, z] in metres (the centre of the piece)`);
  const out = pick(item, FURNITURE_KEYS);
  out.pos = out.pos.map(round);
  if (out.rot != null) { if (!isNum(out.rot)) fail(`${where}: "rot" must be a number of degrees`); out.rot = Math.round(out.rot); }
  for (const k of ['width', 'height']) {
    if (out[k] != null && !(isNum(out[k]) && out[k] > 0.1 && out[k] < 12)) fail(`${where}: "${k}" must be metres between 0.1 and 12`);
  }
  if (out.size != null && !(isPoint(out.size) && out.size.every((v) => v > 0.1 && v < 15))) fail(`${where}: "size" must be [width, depth] in metres`);
  if (out.color != null && !/^#[0-9a-f]{6}$/i.test(out.color)) fail(`${where}: "color" must look like "#8b93a7"`);
  for (const k of ['chairs', 'stools']) {
    if (out[k] != null && !(Number.isInteger(out[k]) && out[k] >= 0 && out[k] <= 12)) fail(`${where}: "${k}" must be a whole number 0–12`);
  }
  if (out.upper != null) out.upper = Boolean(out.upper);
  if (out.rot === 0) delete out.rot;
  return out;
}

function roomAt(plan, [x, z]) {
  return (plan.rooms || []).find((r) => x >= r.rect[0] - 0.01 && x <= r.rect[0] + r.rect[2] + 0.01
    && z >= r.rect[1] - 0.01 && z <= r.rect[1] + r.rect[3] + 0.01);
}

function findById(list, id, what) {
  const i = list.findIndex((d) => d.id === id);
  if (i < 0) fail(`There is no ${what} with id "${id}". Ids: ${list.map((d) => d.id).join(', ') || 'none'}`);
  return i;
}

function checkRect(rect, where) {
  if (!(Array.isArray(rect) && rect.length === 4 && rect.every(isNum) && rect[2] > 0.3 && rect[3] > 0.3)) {
    fail(`${where}: "rect" must be [x, z, width, depth] in metres, at least 0.3 m each way`);
  }
  return rect.map(round);
}

/**
 * Applies `operations` to `raw` and returns { plan, changes, warnings }. Nothing is
 * changed when one operation is wrong: the error says which one and why.
 *
 * Furniture and openings are addressed by their index in the plan as it was before this
 * edit; removals happen last, so the indexes of one edit never shift under it.
 */
export function applyOperations(raw, operations) {
  if (!Array.isArray(operations) || !operations.length) fail('"operations" must be a non-empty list');
  const plan = structuredClone(raw);
  for (const key of ['rooms', 'openings', 'furniture', 'lights', 'acs', 'scenes']) plan[key] = plan[key] || [];
  const originalFurniture = plan.furniture.length;
  const originalOpenings = plan.openings.length;
  const dropFurniture = new Set();
  const dropOpenings = new Set();
  const addFurniture = [];
  const changes = [];

  const furnitureIndex = (op, where) => {
    if (!Number.isInteger(op.index) || op.index < 0 || op.index >= originalFurniture) {
      fail(`${where}: "index" must be 0–${originalFurniture - 1} (the furniture list from get_floor_plan)`);
    }
    if (dropFurniture.has(op.index)) fail(`${where}: furniture #${op.index} is already removed in this edit`);
    return op.index;
  };

  operations.forEach((op, n) => {
    const where = `Operation ${n + 1} (${op?.op})`;
    if (!op || typeof op !== 'object') fail(`Operation ${n + 1} must be an object`);
    switch (op.op) {
      case 'set_home': {
        if (op.name != null) plan.name = String(op.name).slice(0, 60);
        if (op.outdoorTemp != null) { if (!isNum(op.outdoorTemp)) fail(`${where}: outdoorTemp must be a number`); plan.outdoorTemp = op.outdoorTemp; }
        if (op.wallHeight != null) { if (!(isNum(op.wallHeight) && op.wallHeight > 1.8 && op.wallHeight < 6)) fail(`${where}: wallHeight must be 1.8–6 m`); plan.wallHeight = op.wallHeight; }
        if (op.camera != null) plan.camera = { ...plan.camera, ...pick(op.camera, ['azimuth', 'elevation']) };
        changes.push('home settings');
        break;
      }
      case 'add_room': {
        if (typeof op.id !== 'string' || !/^[a-z0-9_.-]+$/i.test(op.id)) fail(`${where}: "id" must be a short word like "office"`);
        if (plan.rooms.some((r) => r.id === op.id)) fail(`${where}: a room "${op.id}" already exists`);
        if (op.floor != null && !FLOOR_KINDS.includes(op.floor)) fail(`${where}: "floor" must be one of ${FLOOR_KINDS.join(', ')}`);
        plan.rooms.push({ id: op.id, name: String(op.name || op.id), rect: checkRect(op.rect, where), floor: op.floor || 'oak' });
        changes.push(`added room ${op.name || op.id}`);
        break;
      }
      case 'update_room': {
        const room = plan.rooms[findById(plan.rooms, op.id, 'room')];
        if (op.name != null) room.name = String(op.name);
        if (op.rect != null) {
          // Furniture inside the room moves with it, so resizing from the far edge keeps it in place.
          const rect = checkRect(op.rect, where);
          const [dx, dz] = [rect[0] - room.rect[0], rect[1] - room.rect[1]];
          if (op.moveContents !== false && (dx || dz)) {
            const inside = (p) => roomAt({ rooms: [room] }, p);
            for (const f of plan.furniture) if (inside(f.pos)) f.pos = [round(f.pos[0] + dx), round(f.pos[1] + dz)];
            for (const d of [...plan.lights, ...plan.acs]) if (d.room === room.id) d.pos = [round(d.pos[0] + dx), round(d.pos[1] + dz)];
          }
          room.rect = rect;
        }
        if (op.floor != null) {
          if (!FLOOR_KINDS.includes(op.floor)) fail(`${where}: "floor" must be one of ${FLOOR_KINDS.join(', ')}`);
          room.floor = op.floor;
        }
        changes.push(`updated room ${room.name}`);
        break;
      }
      case 'remove_room': {
        const i = findById(plan.rooms, op.id, 'room');
        const devices = [...plan.lights, ...plan.acs].filter((d) => d.room === op.id);
        if (devices.some(isLinked)) fail(`${where}: this room has devices linked to real hardware; unlink them in the editor first`);
        const room = plan.rooms[i];
        plan.furniture.forEach((f, k) => { if (k < originalFurniture && roomAt({ rooms: [room] }, f.pos)) dropFurniture.add(k); });
        plan.lights = plan.lights.filter((d) => d.room !== op.id);
        plan.acs = plan.acs.filter((d) => d.room !== op.id);
        plan.rooms.splice(i, 1);
        changes.push(`removed room ${room.name}`);
        break;
      }
      case 'furnish_room': {
        // Replaces everything standing in a room: the natural edit for "here is a photo of my living room".
        const room = plan.rooms[findById(plan.rooms, op.room, 'room')];
        if (!Array.isArray(op.items)) fail(`${where}: "items" must be a list of furniture`);
        plan.furniture.forEach((f, k) => {
          if (k < originalFurniture && Array.isArray(f.pos) && roomAt({ rooms: [room] }, f.pos)?.id === room.id) dropFurniture.add(k);
        });
        op.items.forEach((item, k) => addFurniture.push(cleanFurniture(item, `${where}, item ${k + 1}`)));
        changes.push(`refurnished ${room.name} (${op.items.length} pieces)`);
        break;
      }
      case 'add_furniture': {
        const items = op.items || [op.item];
        items.forEach((item, k) => addFurniture.push(cleanFurniture(item, `${where}, item ${k + 1}`)));
        changes.push(`added ${items.map((i) => i.type).join(', ')}`);
        break;
      }
      case 'update_furniture': {
        const i = furnitureIndex(op, where);
        plan.furniture[i] = cleanFurniture({ ...plan.furniture[i], ...(op.set || {}) }, where);
        changes.push(`changed ${plan.furniture[i].type} #${i}`);
        break;
      }
      case 'remove_furniture': {
        const i = furnitureIndex(op, where);
        dropFurniture.add(i);
        changes.push(`removed ${plan.furniture[i].type} #${i}`);
        break;
      }
      case 'add_opening': {
        const type = op.type || 'door';
        if (!['door', 'window', 'open'].includes(type)) fail(`${where}: "type" must be door, window or open`);
        if (!isPoint(op.from) || !isPoint(op.to)) fail(`${where}: "from" and "to" must be [x, z] points on a wall`);
        if (op.from[0] !== op.to[0] && op.from[1] !== op.to[1]) fail(`${where}: an opening must be horizontal or vertical`);
        const o = { type, from: op.from.map(round), to: op.to.map(round) };
        if (type === 'window') { if (isNum(op.sill)) o.sill = op.sill; if (isNum(op.head)) o.head = op.head; }
        plan.openings.push(o);
        changes.push(`added a ${type}`);
        break;
      }
      case 'remove_opening': {
        if (!Number.isInteger(op.index) || op.index < 0 || op.index >= originalOpenings) fail(`${where}: "index" must be 0–${originalOpenings - 1}`);
        dropOpenings.add(op.index);
        changes.push(`removed ${plan.openings[op.index].type} #${op.index}`);
        break;
      }
      case 'add_light':
      case 'add_ac': {
        const isLight = op.op === 'add_light';
        const list = isLight ? plan.lights : plan.acs;
        const device = pick(op, isLight ? LIGHT_KEYS : AC_KEYS);
        if (typeof device.id !== 'string' || !device.id) fail(`${where}: "id" is required, e.g. "living.reading"`);
        if ([...plan.lights, ...plan.acs].some((d) => d.id === device.id)) fail(`${where}: id "${device.id}" is taken`);
        if (isLight && !LIGHT_KINDS.includes(device.type)) fail(`${where}: "type" must be one of ${LIGHT_KINDS.join(', ')}`);
        if (!isLight && !WALLS.includes(device.wall)) fail(`${where}: "wall" must be one of ${WALLS.join(', ')}`);
        list.push(device);
        changes.push(`added ${isLight ? 'light' : 'AC'} ${device.name || device.id}`);
        break;
      }
      case 'update_light':
      case 'update_ac': {
        const isLight = op.op === 'update_light';
        const list = isLight ? plan.lights : plan.acs;
        const i = findById(list, op.id, isLight ? 'light' : 'AC');
        const set = pick(op.set, (isLight ? LIGHT_KEYS : AC_KEYS).filter((k) => k !== 'id'));
        if (LINK_FIELDS.some((k) => op.set?.[k]) || op.set?.linked != null) fail(`${where}: links to real devices are made in the editor, not here`);
        Object.assign(list[i], set);
        changes.push(`changed ${list[i].name || list[i].id}`);
        break;
      }
      case 'remove_light':
      case 'remove_ac': {
        const isLight = op.op === 'remove_light';
        const list = isLight ? plan.lights : plan.acs;
        const i = findById(list, op.id, isLight ? 'light' : 'AC');
        if (isLinked(list[i])) fail(`${where}: "${list[i].name}" is a real device; unlink it in the editor before removing it`);
        const [gone] = list.splice(i, 1);
        for (const s of plan.scenes) delete s[isLight ? 'lights' : 'acs']?.[gone.id];
        changes.push(`removed ${gone.name || gone.id}`);
        break;
      }
      case 'add_scene':
      case 'update_scene': {
        const adding = op.op === 'add_scene';
        const source = adding ? op : { ...plan.scenes[findById(plan.scenes, op.id, 'scene')], ...(op.set || {}) };
        if (adding && plan.scenes.some((s) => s.id === op.id)) fail(`${where}: a scene "${op.id}" already exists`);
        if (typeof source.id !== 'string' || !source.id) fail(`${where}: "id" is required`);
        if (source.icon != null && !SCENE_ICONS.includes(source.icon)) fail(`${where}: "icon" must be one of ${SCENE_ICONS.join(', ')}`);
        const scene = { id: source.id, name: String(source.name || source.id), icon: source.icon || 'sparkles',
          lights: source.lights || {}, acs: source.acs || {} };
        for (const [id, s] of Object.entries(scene.lights)) {
          if (id !== '*' && !plan.lights.some((l) => l.id === id)) fail(`${where}: unknown light "${id}"`);
          if (s.brightness != null && !(s.brightness > 0 && s.brightness <= 1)) fail(`${where}: scene brightness is 0–1 (0.6 = 60%)`);
        }
        for (const id of Object.keys(scene.acs)) if (id !== '*' && !plan.acs.some((a) => a.id === id)) fail(`${where}: unknown AC "${id}"`);
        if (adding) plan.scenes.push(scene);
        else plan.scenes[plan.scenes.findIndex((s) => s.id === op.id)] = scene;
        changes.push(`${adding ? 'added' : 'changed'} scene ${scene.name}`);
        break;
      }
      case 'remove_scene': {
        const i = findById(plan.scenes, op.id, 'scene');
        changes.push(`removed scene ${plan.scenes[i].name}`);
        plan.scenes.splice(i, 1);
        break;
      }
      default:
        fail(`${where}: unknown operation. Use one of: set_home, add_room, update_room, remove_room, furnish_room, `
          + 'add_furniture, update_furniture, remove_furniture, add_opening, remove_opening, add_light, update_light, '
          + 'remove_light, add_ac, update_ac, remove_ac, add_scene, update_scene, remove_scene');
    }
  });

  plan.furniture = plan.furniture.filter((_, k) => !dropFurniture.has(k)).concat(addFurniture);
  plan.openings = plan.openings.filter((_, k) => !dropOpenings.has(k));
  return { plan, changes, warnings: check(plan) };
}

/** Throws when the plan cannot be drawn; returns gentle warnings otherwise. */
export function check(plan) {
  try {
    normalize(structuredClone(plan));
  } catch (error) {
    fail(error.message);
  }
  const warnings = [];
  plan.furniture.forEach((f, i) => {
    if (!FURNITURE_TYPES.includes(f.type)) fail(`Furniture #${i} has unknown type "${f.type}"`);
    if (!roomAt(plan, f.pos)) warnings.push(`furniture #${i} (${f.type}) stands outside every room`);
  });
  for (const d of [...plan.lights, ...plan.acs]) {
    const room = plan.rooms.find((r) => r.id === d.room);
    if (room && roomAt({ rooms: [room] }, d.pos)?.id !== room.id) warnings.push(`${d.name || d.id} is outside its room "${room.name}"`);
  }
  return warnings;
}

/** A plan an AI wrote whole (replace_floor_plan), checked and with the hardware links kept. */
export function replacePlan(old, next) {
  if (!next || typeof next !== 'object' || !Array.isArray(next.rooms)) fail('"plan" must be a floor plan object with a "rooms" list');
  const plan = restoreLinks(structuredClone(next), old);
  plan.furniture = (plan.furniture || []).map((f, i) => cleanFurniture(f, `Furniture #${i}`));
  if (old.version != null && plan.version == null) plan.version = old.version;
  const lost = [...(old.lights || []), ...(old.acs || [])].filter((d) => isLinked(d)
    && ![...(plan.lights || []), ...(plan.acs || [])].some((n) => n.id === d.id));
  if (lost.length) {
    fail(`The new plan drops devices linked to real hardware: ${lost.map((d) => `${d.name} (${d.id})`).join(', ')}. Keep them, with the same ids.`);
  }
  return { plan, warnings: check(plan) };
}

/** What each furniture type is, for the AI that places it. */
export const FURNITURE_GUIDE = {
  sofa: 'sofa; options width, color',
  armchair: 'armchair; option color',
  coffeeTable: 'low coffee table; option width',
  rug: 'flat rug; options size [w, d], color',
  tv: 'TV on a low media console; option width',
  sideboard: 'sideboard / low cabinet; option width',
  diningSet: 'dining table with chairs around it; options width, chairs',
  island: 'kitchen island with stools on its front side; options width, stools',
  kitchen: 'run of kitchen base cabinets with counter, sink and hob; options width, upper (wall cabinets, default true)',
  fridge: 'tall fridge',
  bed: 'bed with headboard; options width (mattress), color (bedding)',
  nightstand: 'nightstand',
  dresser: 'chest of drawers; option width',
  plant: 'potted plant; option height',
  vanity: 'bathroom vanity with basin and mirror; option width',
  bathtub: 'bathtub',
  toilet: 'toilet',
  desk: 'desk; option width',
  wardrobe: 'wardrobe; options width, height',
  bookshelf: 'open bookshelf with books; options width, height',
};

export function furnitureCatalog() {
  return FURNITURE_TYPES.map((type) => {
    const [w, d] = footprint({ type });
    return { type, footprint: [round(w), round(d)], about: FURNITURE_GUIDE[type] || type };
  });
}
