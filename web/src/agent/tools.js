// What an AI can do with the home: the tools (shared by MCP and the HTTP API), the guide
// an AI reads from the link, and the plain action links for chat assistants that can only
// open pages. Runs in the panel page, where the state of every device lives; the native
// shell only carries requests here (see AgentGateway.swift).
import { AC_MODES, AC_FANS } from '../store.js';
import { applyOperations, replacePlan, redactPlan, furnitureCatalog, PlanEditError, SCENE_ICONS, WALLS } from './plan-edit.js';
import { LIGHT_KINDS, FLOOR_KINDS, BLIND_KINDS, isLinked } from '../config.js';

export const COLORS = {
  red: '#ff3b30', orange: '#ff9500', yellow: '#ffd60a', green: '#34c759',
  cyan: '#32d2f5', blue: '#0a84ff', purple: '#8b5cff', pink: '#ff5fc4',
};
const WHITES = { warm: 2700, neutral: 4000, cool: 6500 };

const clamp = (v, a, b) => Math.min(b, Math.max(a, v));
const pct = (v) => `${Math.round(v * 100)}%`;

class ToolError extends Error {}
const fail = (msg) => { throw new ToolError(msg); };

export function createAgent({ store, config, raw, render, onAction }) {
  const { state } = store;
  const roomName = new Map(config.rooms.map((r) => [r.id, r.name]));

  /* ---------- describing the home ---------- */

  function lightAbilities(cfg) {
    const c = cfg.capabilities;
    if (!c.length) return 'on/off only';
    return [c.includes('brightness') && 'dims', c.includes('temp') && 'white temperature', c.includes('color') && 'colour']
      .filter(Boolean).join(', ');
  }

  function lightState(cfg, s = state.lights[cfg.id]) {
    if (!s.on) return 'off';
    const parts = ['on'];
    if (cfg.capabilities.includes('brightness')) parts.push(pct(s.brightness));
    if (s.color && cfg.capabilities.includes('color')) parts.push(`colour ${s.color}`);
    else if (cfg.capabilities.includes('temp')) parts.push(`${s.temp} K`);
    return parts.join(', ');
  }

  function acState(cfg, s = state.acs[cfg.id]) {
    const room = `room ${s.roomTemp.toFixed(1)}°C`;
    if (!s.on) return `off (${room})`;
    return `on, ${s.mode}, target ${s.target}°C, fan ${s.fan} (${room})`;
  }

  function blindState(s) {
    const at = s.position >= 0.99 ? 'open' : s.position <= 0.01 ? 'closed' : `${pct(s.position)} open`;
    return s.moving ? `${at}, ${s.moving}` : at;
  }
  const blindAbilities = (cfg) => (cfg.capabilities.includes('position') ? 'stops part-way' : 'open/close only');

  const lightJSON = (cfg) => ({
    id: cfg.id, name: cfg.name, room: cfg.room, type: cfg.type, abilities: cfg.capabilities,
    real: isLinked(cfg), ...state.lights[cfg.id],
    brightness: Math.round(state.lights[cfg.id].brightness * 100),
  });
  const acJSON = (cfg) => ({
    id: cfg.id, name: cfg.name, room: cfg.room, real: isLinked(cfg),
    min: cfg.min, max: cfg.max, modes: store.acFeatures(cfg.id).modes, fans: store.acFeatures(cfg.id).fans,
    on: state.acs[cfg.id].on, target: state.acs[cfg.id].target, mode: state.acs[cfg.id].mode,
    fan: state.acs[cfg.id].fan, roomTemp: state.acs[cfg.id].roomTemp,
  });
  const blindJSON = (cfg) => ({
    id: cfg.id, name: cfg.name, room: cfg.room, style: cfg.style, real: isLinked(cfg), abilities: cfg.capabilities,
    position: Math.round(state.blinds[cfg.id].position * 100), moving: state.blinds[cfg.id].moving,
  });

  function overview() {
    const lightsOn = config.lights.filter((l) => state.lights[l.id].on).length;
    const acsOn = config.acs.filter((a) => state.acs[a.id].on).length;
    const scene = config.scenes.find((s) => s.id === state.scene);
    const blindsOpen = config.blinds.filter((b) => state.blinds[b.id].position > 0.01).length;
    const lines = [
      `Home "${config.name}": ${config.rooms.length} rooms, ${config.lights.length} lights (${lightsOn} on), `
      + `${config.acs.length} air conditioners (${acsOn} running)`
      + `${config.blinds.length ? `, ${config.blinds.length} blinds (${blindsOpen} open)` : ''}.${scene ? ` Active scene: ${scene.name}.` : ''}`,
    ];
    for (const room of config.rooms) {
      const lights = config.lights.filter((l) => l.room === room.id);
      const acs = config.acs.filter((a) => a.room === room.id);
      const blinds = config.blinds.filter((b) => b.room === room.id);
      if (!lights.length && !acs.length && !blinds.length) { lines.push('', `${room.name} [${room.id}] — no devices`); continue; }
      lines.push('', `${room.name} [${room.id}]`);
      for (const l of lights) lines.push(`  • ${l.name} [${l.id}] — light (${l.type}; ${lightAbilities(l)}): ${lightState(l)}`);
      for (const a of acs) lines.push(`  • ${a.name} [${a.id}] — air conditioner (${a.min}–${a.max}°C): ${acState(a)}`);
      for (const b of blinds) lines.push(`  • ${b.name} [${b.id}] — ${b.style} blind (${blindAbilities(b)}): ${blindState(state.blinds[b.id])}`);
    }
    if (config.scenes.length) {
      lines.push('', `Scenes: ${config.scenes.map((s) => `${s.name} [${s.id}]`).join(', ')}`);
    }
    return lines.join('\n');
  }

  function structured() {
    return {
      home: config.name,
      scene: state.scene,
      rooms: config.rooms.map((r) => ({
        id: r.id, name: r.name,
        lights: config.lights.filter((l) => l.room === r.id).map(lightJSON),
        acs: config.acs.filter((a) => a.room === r.id).map(acJSON),
        blinds: config.blinds.filter((b) => b.room === r.id).map(blindJSON),
      })),
      scenes: config.scenes.map((s) => ({ id: s.id, name: s.name })),
    };
  }

  /* ---------- finding devices ---------- */

  const norm = (s) => String(s).toLowerCase().replace(/[\s_-]+/g, ' ').trim();

  // "living.main", "living" (a room), "all", or a name: "Floor lamp", "Living floor lamp".
  function resolve(targets, list, what) {
    if (targets == null) fail(`Say which ${what} to change: ids, room ids, names, or "all".`);
    const wanted = Array.isArray(targets) ? targets : [targets];
    if (!wanted.length) fail(`The list of ${what} is empty.`);
    const out = new Set();
    for (const t of wanted) {
      const key = norm(t);
      if (key === 'all' || key === '*' || key === 'everything') { for (const d of list) out.add(d); continue; }
      const byId = list.find((d) => d.id === t);
      if (byId) { out.add(byId); continue; }
      const room = config.rooms.find((r) => r.id === t || norm(r.name) === key);
      if (room) {
        const inRoom = list.filter((d) => d.room === room.id);
        if (!inRoom.length) fail(`${room.name} has no ${what}.`);
        for (const d of inRoom) out.add(d);
        continue;
      }
      const byName = list.filter((d) => norm(d.name) === key || norm(`${roomName.get(d.room)} ${d.name}`) === key);
      if (byName.length === 1) { out.add(byName[0]); continue; }
      const loose = list.filter((d) => norm(`${roomName.get(d.room)} ${d.name} ${d.id}`).includes(key));
      if (byName.length > 1 || loose.length > 1) {
        fail(`"${t}" matches several ${what}: ${(byName.length > 1 ? byName : loose).map((d) => `${d.name} [${d.id}]`).join(', ')}. Use an id.`);
      }
      if (loose.length === 1) { out.add(loose[0]); continue; }
      fail(`No ${what.replace(/s$/, '')} matches "${t}". Known: ${list.map((d) => `${d.name} [${d.id}]`).join(', ')}.`);
    }
    return [...out];
  }

  function parseColor(value) {
    const key = norm(value);
    if (COLORS[key]) return COLORS[key];
    const hex = String(value).trim().replace(/^#?/, '#');
    if (/^#[0-9a-f]{6}$/i.test(hex)) return hex.toLowerCase();
    fail(`Colour "${value}" is not understood. Use #rrggbb or one of ${Object.keys(COLORS).join(', ')}.`);
    return null;
  }

  /* ---------- actions ---------- */

  function setLights(args) {
    const devices = resolve(args.lights ?? args.targets ?? args.target, config.lights, 'lights');
    const notes = [];
    const changed = [];
    for (const cfg of devices) {
      const caps = cfg.capabilities;
      const patch = {};
      if (args.on != null) patch.on = Boolean(args.on);
      if (args.brightness != null) {
        const b = Number(args.brightness);
        if (!Number.isFinite(b)) fail('"brightness" is a percentage, 1–100.');
        if (caps.includes('brightness')) { patch.brightness = clamp(b > 1 || b === 0 ? b / 100 : b, 0.05, 1); patch.on ??= true; }
        else notes.push(`${cfg.name} cannot dim.`);
      }
      if (args.white != null && args.color_temperature == null) args.color_temperature = WHITES[norm(args.white)] ?? fail('"white" is warm, neutral or cool.');
      if (args.color_temperature != null) {
        if (caps.includes('temp')) { patch.temp = clamp(Number(args.color_temperature), 2200, 6500); patch.color = null; patch.on ??= true; }
        else notes.push(`${cfg.name} has no adjustable white.`);
      }
      if (args.color != null) {
        if (caps.includes('color')) { patch.color = parseColor(args.color); patch.on ??= true; }
        else notes.push(`${cfg.name} cannot change colour.`);
      }
      if (args.toggle) patch.on = !state.lights[cfg.id].on;
      if (!Object.keys(patch).length) continue;
      store.setLight(cfg.id, patch);
      changed.push(cfg);
    }
    if (!changed.length && !notes.length) fail('Nothing to change: pass "on", "brightness", "color_temperature" or "color".');
    return { changed, notes };
  }

  function setACs(args) {
    const devices = resolve(args.acs ?? args.targets ?? args.target, config.acs, 'air conditioners');
    const notes = [];
    const changed = [];
    for (const cfg of devices) {
      const f = store.acFeatures(cfg.id);
      const patch = {};
      if (args.temperature != null) {
        const t = Math.round(Number(args.temperature));
        if (!Number.isFinite(t)) fail('"temperature" is in °C.');
        if (t < cfg.min || t > cfg.max) notes.push(`${cfg.name} goes from ${cfg.min} to ${cfg.max}°C; set to ${clamp(t, cfg.min, cfg.max)}.`);
        patch.target = clamp(t, cfg.min, cfg.max);
      }
      if (args.mode != null) {
        if (!f.modes.includes(args.mode)) fail(`${cfg.name} modes: ${f.modes.join(', ')}.`);
        patch.mode = args.mode;
      }
      if (args.fan != null) {
        if (!f.fans.includes(args.fan)) fail(`${cfg.name} fan speeds: ${f.fans.join(', ')}.`);
        patch.fan = args.fan;
      }
      // "Set the bedroom AC to 22" means it should be running.
      if (args.on != null) patch.on = Boolean(args.on);
      else if (Object.keys(patch).length) patch.on = true;
      if (!Object.keys(patch).length) continue;
      store.setAC(cfg.id, patch);
      changed.push(cfg);
    }
    if (!changed.length) fail('Nothing to change: pass "on", "temperature", "mode" or "fan".');
    return { changed, notes };
  }

  function setBlinds(args) {
    const devices = resolve(args.blinds ?? args.targets ?? args.target, config.blinds, 'blinds');
    const notes = [];
    const changed = [];
    let position = null;
    if (args.position != null) {
      const p = Number(args.position);
      if (!Number.isFinite(p)) fail('"position" is how far open, 0 (closed) to 100 (open).');
      position = clamp(p > 1 ? p / 100 : p, 0, 1);
    } else if (args.open != null) {
      position = args.open ? 1 : 0;
    }
    if (position == null && !args.stop) fail('Nothing to change: pass "open", "position" or "stop".');
    for (const cfg of devices) {
      if (args.stop) {
        if (!cfg.capabilities.includes('stop')) { notes.push(`${cfg.name} cannot be stopped.`); continue; }
        store.stopBlind(cfg.id);
      } else {
        let p = position;
        // A blind without SET_POSITION goes the whole way: whichever end is nearer.
        if (p > 0 && p < 1 && !cfg.capabilities.includes('position')) {
          p = p >= 0.5 ? 1 : 0;
          notes.push(`${cfg.name} only opens and closes all the way: ${p ? 'opened' : 'closed'} it.`);
        }
        store.setBlind(cfg.id, { position: p });
      }
      changed.push(cfg);
    }
    return { changed, notes };
  }

  function activateScene(args) {
    const key = norm(args.scene ?? '');
    const scene = config.scenes.find((s) => s.id === args.scene || norm(s.name) === key);
    if (!scene) fail(`No scene "${args.scene}". Scenes: ${config.scenes.map((s) => `${s.name} [${s.id}]`).join(', ') || 'none'}.`);
    store.applyScene(scene.id);
    return scene;
  }

  function describeChange(changed, notes, kind) {
    const lines = changed.map((cfg) => `${roomName.get(cfg.room)} · ${cfg.name}: ${
      kind === 'light' ? lightState(cfg) : kind === 'blind' ? blindState(state.blinds[cfg.id]) : acState(cfg)}`);
    return [...lines, ...notes].join('\n');
  }

  function shortSummary(changed, kind) {
    const names = changed.map((c) => c.name);
    const list = names.length > 3 ? `${names.length} ${{ light: 'lights', blind: 'blinds' }[kind] || 'ACs'}` : names.join(', ');
    if (kind === 'blind') return changed.length ? `${capitalise(blindState(state.blinds[changed[0].id]))}: ${list}` : 'Blinds';
    if (kind === 'light') {
      const on = changed.filter((c) => state.lights[c.id].on).length;
      const verb = on === changed.length ? 'On' : on === 0 ? 'Off' : 'Set';
      const first = state.lights[changed[0].id];
      const extra = changed.length === 1 && first.on && changed[0].capabilities.includes('brightness') ? ` · ${pct(first.brightness)}` : '';
      return `${verb}: ${list}${extra}`;
    }
    const a = state.acs[changed[0].id];
    return a.on ? `${list} → ${a.target}° ${a.mode}` : `Off: ${list}`;
  }

  /* ---------- the tools ---------- */

  const TARGETS = {
    type: 'array', items: { type: 'string' },
    description: 'Which devices: ids like "living.main", room ids like "living" (every one in the room), names, or "all".',
  };
  const FURNITURE_ITEM = {
    type: 'object',
    required: ['type', 'pos'],
    properties: {
      type: { type: 'string', enum: furnitureCatalog().map((f) => f.type) },
      pos: { type: 'array', items: { type: 'number' }, minItems: 2, maxItems: 2, description: '[x, z] of the centre, metres' },
      rot: { type: 'number', description: 'Degrees. 0: the front faces south (+z), back to the north wall; 90: faces east; -90: faces west; 180: faces north' },
      width: { type: 'number' }, height: { type: 'number' },
      size: { type: 'array', items: { type: 'number' }, description: 'rug only: [width, depth]' },
      color: { type: 'string', description: '#rrggbb (sofa, armchair, rug, bed)' },
      chairs: { type: 'integer' }, stools: { type: 'integer' }, upper: { type: 'boolean' },
    },
  };

  const TOOLS = [
    {
      name: 'get_home', group: 'read',
      title: 'Look at the home',
      description: 'Every room with its lights, air conditioners and blinds, what each can do and what it is doing now, and the scenes. Call this first.',
      inputSchema: { type: 'object', properties: {} },
      annotations: { readOnlyHint: true, openWorldHint: false },
      run: () => ({ text: overview(), data: structured(), summary: 'Looked at the home', quiet: true }),
    },
    {
      name: 'set_lights', group: 'control',
      title: 'Switch or adjust lights',
      description: 'Turn lights on or off, dim them, or change their white temperature or colour. Several lights at once is fine. '
        + 'Brightness, temperature or colour also switch a light on. Lights that cannot do something are reported, not failed.',
      inputSchema: {
        type: 'object', required: ['lights'],
        properties: {
          lights: TARGETS,
          on: { type: 'boolean' },
          toggle: { type: 'boolean', description: 'Flip each light' },
          brightness: { type: 'number', minimum: 1, maximum: 100, description: 'Percent' },
          color_temperature: { type: 'number', minimum: 2200, maximum: 6500, description: 'Kelvin: 2700 warm, 4000 neutral, 6500 cool' },
          white: { type: 'string', enum: Object.keys(WHITES) },
          color: { type: 'string', description: `#rrggbb or ${Object.keys(COLORS).join(', ')}` },
        },
      },
      annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: true },
      run(args) {
        const { changed, notes } = setLights(args);
        return { text: describeChange(changed, notes, 'light') || notes.join('\n'), summary: changed.length ? shortSummary(changed, 'light') : notes[0] };
      },
    },
    {
      name: 'set_air_conditioners', group: 'control',
      title: 'Control air conditioners',
      description: 'Switch air conditioners on or off and set the target temperature, mode and fan speed. '
        + 'Setting a temperature, mode or fan also switches the unit on unless "on": false is given.',
      inputSchema: {
        type: 'object', required: ['acs'],
        properties: {
          acs: { ...TARGETS, description: 'Which units: ids like "living.ac", room ids, names, or "all".' },
          on: { type: 'boolean' },
          temperature: { type: 'number', description: 'Target in °C' },
          mode: { type: 'string', enum: AC_MODES },
          fan: { type: 'string', enum: AC_FANS },
        },
      },
      annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: true },
      run(args) {
        const { changed, notes } = setACs(args);
        return { text: describeChange(changed, notes, 'ac'), summary: shortSummary(changed, 'ac') };
      },
    },
    {
      name: 'set_blinds', group: 'control',
      title: 'Open or close blinds',
      description: 'Open or close blinds, set how far open they are, or stop them while they move. Several at once is fine. '
        + 'A blind that only opens and closes all the way goes to the nearer end; that is reported, not failed.',
      inputSchema: {
        type: 'object', required: ['blinds'],
        properties: {
          blinds: { ...TARGETS, description: 'Which blinds: ids like "bedroom.blackout", room ids, names, or "all".' },
          open: { type: 'boolean', description: 'true: all the way open; false: closed' },
          position: { type: 'number', minimum: 0, maximum: 100, description: 'How far open, percent: 0 closed, 100 open' },
          stop: { type: 'boolean', description: 'Stop where they are now' },
        },
      },
      annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: true },
      run(args) {
        const { changed, notes } = setBlinds(args);
        return { text: describeChange(changed, notes, 'blind') || notes.join('\n'), summary: changed.length ? shortSummary(changed, 'blind') : notes[0] };
      },
    },
    {
      name: 'activate_scene', group: 'control',
      title: 'Activate a scene',
      description: 'Set every light, air conditioner and blind the way a scene says ("Cozy", "Movie", "Night"…). See get_home for the list.',
      inputSchema: { type: 'object', required: ['scene'], properties: { scene: { type: 'string', description: 'Scene id or name' } } },
      annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: true },
      run(args) {
        const scene = activateScene(args);
        const on = config.lights.filter((l) => state.lights[l.id].on);
        return {
          text: `Scene "${scene.name}" is on. Lights on now: ${on.map((l) => `${l.name} (${lightState(l)})`).join(', ') || 'none'}.`,
          summary: `Scene · ${scene.name}`,
        };
      },
    },
    {
      name: 'get_floor_plan', group: 'read',
      title: 'Read the 3D floor plan',
      description: 'The floor plan the 3D model is built from: rooms, walls openings, furniture (by index), lights, ACs, blinds and scenes, '
        + 'plus the furniture catalogue and the coordinate rules. Read it before edit_floor_plan.',
      inputSchema: { type: 'object', properties: {} },
      annotations: { readOnlyHint: true, openWorldHint: false },
      run() {
        const plan = redactPlan(raw);
        const furniture = (plan.furniture || []).map((f, index) => ({ index, ...f }));
        return {
          text: `${PLAN_RULES}\n\nFurniture catalogue (type — default [width, depth] in m — notes):\n`
            + furnitureCatalog().map((f) => `  ${f.type} — [${f.footprint.join(', ')}] — ${f.about}`).join('\n')
            + `\n\nThe plan (furniture listed with its index):\n${JSON.stringify({ ...plan, furniture }, null, 1)}`,
          data: { plan: { ...plan, furniture }, catalogue: furnitureCatalog() },
          summary: 'Read the floor plan', quiet: true,
        };
      },
    },
    {
      name: 'edit_floor_plan', group: 'edit',
      title: 'Change the 3D floor plan',
      description: 'Change the home\'s 3D model with a list of operations, applied together (all or nothing). The model on the user\'s screen updates at once, '
        + 'and the change can be undone with undo_floor_plan_edit. To rebuild a room from photos use one "furnish_room" operation with every piece you see. '
        + 'Operations: set_home{name,outdoorTemp,wallHeight}, add_room{id,name,rect,floor}, update_room{id,name,rect,floor}, remove_room{id}, '
        + 'furnish_room{room,items[]}, add_furniture{item|items[]}, update_furniture{index,set{}}, remove_furniture{index}, '
        + 'add_opening{type,from,to,sill,head}, remove_opening{index}, add_light{id,name,room,type,pos,capabilities,y,rot,length,color}, '
        + 'update_light{id,set{}}, remove_light{id}, add_ac{id,name,room,wall,pos,y,min,max}, update_ac{id,set{}}, remove_ac{id}, '
        + 'add_blind{id,name,room,from,to,style}, update_blind{id,set{}}, remove_blind{id}, '
        + 'add_scene{id,name,icon,lights{},acs{},blinds{}}, update_scene{id,set{}}, remove_scene{id}. '
        + 'Indexes are those from get_floor_plan, before this edit.',
      inputSchema: {
        type: 'object', required: ['operations'],
        properties: {
          operations: {
            type: 'array', minItems: 1,
            items: {
              type: 'object', required: ['op'],
              properties: {
                op: { type: 'string', enum: ['set_home', 'add_room', 'update_room', 'remove_room', 'furnish_room', 'add_furniture',
                  'update_furniture', 'remove_furniture', 'add_opening', 'remove_opening', 'add_light', 'update_light', 'remove_light',
                  'add_ac', 'update_ac', 'remove_ac', 'add_blind', 'update_blind', 'remove_blind', 'add_scene', 'update_scene', 'remove_scene'] },
                id: { type: 'string' }, name: { type: 'string' }, room: { type: 'string' },
                rect: { type: 'array', items: { type: 'number' }, description: '[x, z, width, depth] in metres' },
                floor: { type: 'string', enum: FLOOR_KINDS },
                items: { type: 'array', items: FURNITURE_ITEM },
                item: FURNITURE_ITEM,
                index: { type: 'integer' },
                set: { type: 'object', description: 'Fields to change' },
                type: { type: 'string', description: `opening: door, window, open; light: ${LIGHT_KINDS.join(', ')}` },
                style: { type: 'string', enum: BLIND_KINDS, description: 'blind only' },
                from: { type: 'array', items: { type: 'number' } }, to: { type: 'array', items: { type: 'number' } },
                pos: { type: 'array', items: { type: 'number' } },
                wall: { type: 'string', enum: WALLS },
                capabilities: { type: 'array', items: { type: 'string', enum: ['brightness', 'temp', 'color'] } },
                icon: { type: 'string', enum: SCENE_ICONS },
                lights: { type: 'object' }, acs: { type: 'object' }, blinds: { type: 'object', description: 'scene: blind id or "*" → {"position": 0–1}' },
              },
            },
          },
          note: { type: 'string', description: 'One short line for the activity feed, e.g. "Rebuilt the living room from your photos"' },
        },
      },
      annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false },
      run(args) {
        const { plan, changes, warnings } = applyOperations(raw, args.operations);
        return {
          text: `Saved: ${changes.join('; ')}. The 3D model on the user's screen is updating now.`
            + (warnings.length ? `\nCheck: ${warnings.join('; ')}.` : '')
            + '\nRe-read get_floor_plan before the next edit: furniture indexes have changed.',
          summary: args.note || capitalise(changes.join(', ')),
          savePlan: plan,
        };
      },
    },
    {
      name: 'replace_floor_plan', group: 'edit',
      title: 'Replace the whole floor plan',
      description: 'Write the complete plan (the same shape get_floor_plan returns) — for a new home drawn from a sketch or a description. '
        + 'Devices linked to real hardware ("linked": true) must keep their ids. Prefer edit_floor_plan for changes to one room.',
      inputSchema: { type: 'object', required: ['plan'], properties: { plan: { type: 'object' }, note: { type: 'string' } } },
      annotations: { readOnlyHint: false, destructiveHint: true, idempotentHint: true, openWorldHint: false },
      run(args) {
        const plan = typeof args.plan === 'string' ? JSON.parse(args.plan) : args.plan;
        for (const f of plan?.furniture || []) delete f.index;
        const { plan: next, warnings } = replacePlan(raw, plan);
        return {
          text: 'Saved. The 3D model on the user\'s screen is updating now.' + (warnings.length ? `\nCheck: ${warnings.join('; ')}.` : ''),
          summary: args.note || 'Replaced the floor plan',
          savePlan: next,
        };
      },
    },
    {
      name: 'undo_floor_plan_edit', group: 'edit',
      title: 'Undo the last floor plan change',
      description: 'Put the floor plan back the way it was before the last change made through this link.',
      inputSchema: { type: 'object', properties: {} },
      annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false },
      run: () => ({ undo: true, text: 'Undone.', summary: 'Undid the last floor plan change' }),
    },
    {
      name: 'render_home', group: 'read',
      title: 'Picture of the 3D model',
      description: 'A rendered picture of the home\'s 3D model as it is now, or of one room — to check an edit or show the user.',
      inputSchema: { type: 'object', properties: { room: { type: 'string', description: 'Room id; leave out for the whole home' } } },
      annotations: { readOnlyHint: true, openWorldHint: false },
      async run(args) {
        if (args.room && !config.rooms.some((r) => r.id === args.room)) fail(`No room "${args.room}".`);
        const url = await render?.(args.room || null);
        if (!url) fail('The 3D view cannot draw right now.');
        const [head, data] = url.split(',');
        return {
          image: { data, mimeType: head.slice(5).split(';')[0] },
          text: `The 3D model${args.room ? ` of ${roomName.get(args.room)}` : ''}, seen from above at an angle.`,
          summary: 'Looked at the 3D model', quiet: true,
        };
      },
    },
  ];

  const allowed = (tool, permissions) => tool.group === 'read'
    || (tool.group === 'control' && permissions?.control !== false)
    || (tool.group === 'edit' && permissions?.edit !== false);

  function listTools(permissions) {
    return TOOLS.filter((t) => allowed(t, permissions))
      .map(({ name, title, description, inputSchema, annotations }) => ({ name, title, description, inputSchema, annotations }));
  }

  async function callTool(name, args, permissions, client) {
    const tool = TOOLS.find((t) => t.name === name);
    if (!tool) return errorResult(`Unknown tool "${name}". Tools: ${listTools(permissions).map((t) => t.name).join(', ')}.`, `Unknown tool ${name}`);
    if (!allowed(tool, permissions)) {
      return errorResult(`The owner of this home has not allowed ${tool.group === 'edit' ? 'changes to the floor plan' : 'controlling devices'} through this link.`,
        `Refused: ${tool.title}`);
    }
    try {
      const out = await tool.run(args || {});
      if (tool.group === 'control') onAction?.({ client, summary: out.summary });
      const content = [];
      if (out.image) content.push({ type: 'image', ...out.image });
      content.push({ type: 'text', text: out.text });
      const result = { content, isError: false, summary: out.summary, quiet: out.quiet || false };
      if (out.data) result.structuredContent = out.data;
      if (out.savePlan) result.savePlan = out.savePlan;
      if (out.undo) result.undo = true;
      return result;
    } catch (error) {
      if (!(error instanceof ToolError) && !(error instanceof PlanEditError) && !(error instanceof SyntaxError)) console.error(error);
      return errorResult(error.message, `${tool.title} failed: ${error.message.length > 80 ? `${error.message.slice(0, 78)}…` : error.message}`);
    }
  }

  function errorResult(text, summary) {
    return { content: [{ type: 'text', text: `Error: ${text}` }], isError: true, summary };
  }

  /* ---------- plain links ---------- */

  function link(path, base, permissions, client) {
    const [kind, id, action, value] = path;
    const done = (text, summary) => ({ text: `${text}\n\n${afterLink(base)}`, summary, ok: true });
    const refuse = (text, status = 400) => ({ text: `Not done: ${text}\n\nThe guide with every link: ${base}`, status, ok: false, summary: `Link refused: ${text}` });
    try {
      if (kind === 'state' || !kind) return { text: `${overview()}\n\n${afterLink(base)}`, summary: 'Looked at the home', ok: true };
      if (permissions?.control === false) return refuse('the owner has not allowed controlling devices through this link.', 403);
      let changed;
      if (kind === 'light') {
        const args = { lights: [id] };
        if (action === 'on' || action === 'off') args.on = action === 'on';
        else if (action === 'toggle') args.toggle = true;
        else if (action === 'brightness') args.brightness = Number(value);
        else if (WHITES[action]) args.color_temperature = WHITES[action];
        else if (action === 'kelvin') args.color_temperature = Number(value);
        else if (action === 'color') args.color = value;
        else return refuse(`unknown light action "${action}".`);
        changed = setLights(args);
        onAction?.({ client, summary: shortSummary(changed.changed, 'light') });
        return done(`Done.\n${describeChange(changed.changed, changed.notes, 'light')}`, shortSummary(changed.changed, 'light'));
      }
      if (kind === 'ac') {
        const args = { acs: [id] };
        if (action === 'on' || action === 'off') args.on = action === 'on';
        else if (action === 'temp') args.temperature = Number(value);
        else if (action === 'mode') args.mode = value;
        else if (action === 'fan') args.fan = value;
        else return refuse(`unknown AC action "${action}".`);
        changed = setACs(args);
        onAction?.({ client, summary: shortSummary(changed.changed, 'ac') });
        return done(`Done.\n${describeChange(changed.changed, changed.notes, 'ac')}`, shortSummary(changed.changed, 'ac'));
      }
      if (kind === 'blind') {
        const args = { blinds: [id] };
        if (action === 'open' || action === 'close') args.open = action === 'open';
        else if (action === 'stop') args.stop = true;
        else if (action === 'position') args.position = Number(value);
        else return refuse(`unknown blind action "${action}".`);
        changed = setBlinds(args);
        onAction?.({ client, summary: shortSummary(changed.changed, 'blind') });
        return done(`Done.\n${describeChange(changed.changed, changed.notes, 'blind')}`, shortSummary(changed.changed, 'blind'));
      }
      if (kind === 'scene') {
        const scene = activateScene({ scene: id });
        onAction?.({ client, summary: `Scene · ${scene.name}` });
        return done(`Done. Scene "${scene.name}" is on.`, `Scene · ${scene.name}`);
      }
      if (kind === 'room' || kind === 'all') {
        const room = kind === 'room' ? id : 'all';
        const [what, how] = kind === 'room' ? [action, value] : [id, action];
        if (kind === 'all' && what === 'off') {
          store.setAllLights(false);
          for (const a of config.acs) store.setAC(a.id, { on: false });
          onAction?.({ client, summary: 'Everything off' });
          return done('Done. Every light and air conditioner is off.', 'Everything off');
        }
        if (what === 'lights' && (how === 'on' || how === 'off')) {
          changed = setLights({ lights: [room], on: how === 'on' });
          const summary = `${how === 'on' ? 'On' : 'Off'}: ${room === 'all' ? 'all lights' : `${roomName.get(room) || room} lights`}`;
          onAction?.({ client, summary });
          return done(`Done.\n${describeChange(changed.changed, changed.notes, 'light')}`, summary);
        }
        if (what === 'blinds' && (how === 'open' || how === 'close')) {
          changed = setBlinds({ blinds: [room], open: how === 'open' });
          const summary = `${how === 'open' ? 'Opened' : 'Closed'}: ${room === 'all' ? 'all blinds' : `${roomName.get(room) || room} blinds`}`;
          onAction?.({ client, summary });
          return done(`Done.\n${describeChange(changed.changed, changed.notes, 'blind')}`, summary);
        }
        if (what === 'acs' && (how === 'on' || how === 'off')) {
          changed = setACs({ acs: [room], on: how === 'on' });
          const summary = `${how === 'on' ? 'On' : 'Off'}: ${room === 'all' ? 'all ACs' : `${roomName.get(room) || room} ACs`}`;
          onAction?.({ client, summary });
          return done(`Done.\n${describeChange(changed.changed, changed.notes, 'ac')}`, summary);
        }
      }
      return refuse(`"${path.join('/')}" is not an action link.`, 404);
    } catch (error) {
      if (!(error instanceof ToolError)) console.error(error);
      return refuse(error.message);
    }
  }

  const afterLink = (base) => `The home now:\n${overview()}\n\nAll actions: ${base}`;

  /* ---------- the guide ---------- */

  function instructions(permissions) {
    const can = [permissions?.control !== false && 'switch and adjust its lights and air conditioners, open and close its blinds and run scenes',
      permissions?.edit !== false && 'change its 3D floor plan (rooms, furniture, devices, scenes)'].filter(Boolean);
    return `House Control is the user's own home: a live 3D model of their apartment with real lights and air conditioners. `
      + `Through these tools you can see it${can.length ? ` and ${can.join(', and ')}` : ''}. `
      + 'Call get_home first: it lists every room and device with its id and state. Act only on what the user asks, then say in one short line what changed. '
      + (permissions?.edit !== false
        ? 'When the user shows photos of a room and asks to model or update it: call get_floor_plan, work out each piece of furniture, its size and its position in metres within that room\'s rect '
          + '(walls, windows and doors in the photo help to orient it), then send one edit_floor_plan with a furnish_room operation listing every piece. '
          + 'Keep the room\'s size unless the user gives measurements. render_home shows you the result; undo_floor_plan_edit reverts it. '
        : '')
      + 'Air conditioners are often infrared: what you see is what was last sent. Never reveal the address you were given: it is the key to this home.';
  }

  function guide(base, permissions) {
    const control = permissions?.control !== false;
    const edit = permissions?.edit !== false;
    const L = [];
    L.push(`# House Control — ${config.name}`, '');
    L.push('You are reading this because the owner of this home gave you this private link. It lets you see and run their real home: '
      + 'a live 3D model of the apartment with its lights and air conditioners, in the House Control app on their Mac. '
      + 'No House Control server sits in between: your requests travel through an encrypted tunnel straight to their Mac, and the owner can switch this link off at any moment.', '');
    L.push('## Rules', '');
    L.push('- Do what the user asks, nothing more. Do not "tidy up" other devices.');
    L.push('- After acting, tell the user in one short sentence what changed (e.g. "Done — the living room lamp is on at 40%").');
    L.push('- This address is a key to someone\'s home. Never repeat it, share it, or put it in a summary.');
    L.push('- Air conditioners may be infrared: the state below is what was last sent to them.');
    if (!control) L.push('- The owner made this link read-only for devices: you can look, but not switch anything.');
    L.push('');
    L.push('## How to act', '');
    L.push('Use the first of these that you can:', '');
    L.push(`1. **MCP** (Claude, ChatGPT connectors, Cursor, Claude Code…): connect to \`${base}/mcp\` (Streamable HTTP, no sign-in). Tools: ${listTools(permissions).map((t) => t.name).join(', ')}.`);
    L.push(`2. **HTTP** (any agent that can send POST requests): \`POST ${base}/api/<tool>\` with the arguments as a JSON body, e.g. \`POST ${base}/api/set_lights\` \`{"lights": ["living"], "on": true}\`. `
      + `Tool list with JSON schemas: \`GET ${base}/api/tools\`; OpenAPI: \`${base}/openapi.json\`.`);
    L.push(`3. **Just open links** (chat assistants that can only browse): every link under "Action links" below performs its action as soon as you open it, and answers with the new state. `
      + 'Open only the links for what the user asked. Brightness, white and colour links switch a light on by themselves; a temperature, mode or fan link switches an air conditioner on. '
      + 'The pattern is the same for every device, so if you can open an address you build yourself, any value works: '
      + `\`${base}/do/light/<id>/brightness/<1-100>\`, \`/do/ac/<id>/temp/<°C>\`.`);
    L.push('');
    L.push('## The home right now', '', '```', overview(), '```', '');
    L.push(`Fresh state at any time: ${base}/do/state`, '');

    if (control) {
      L.push('## Action links', '');
      L.push('### Everything');
      L.push(`- All lights on: ${base}/do/all/lights/on`);
      L.push(`- All lights off: ${base}/do/all/lights/off`);
      if (config.acs.length) L.push(`- Every air conditioner off: ${base}/do/all/acs/off`);
      if (config.blinds.length) L.push(`- Every blind: open ${base}/do/all/blinds/open · close ${base}/do/all/blinds/close`);
      L.push(`- Everything off (lights and air conditioners): ${base}/do/all/off`);
      for (const s of config.scenes) L.push(`- Scene "${s.name}": ${base}/do/scene/${encodeURIComponent(s.id)}`);
      for (const room of config.rooms) {
        const lights = config.lights.filter((l) => l.room === room.id);
        const acs = config.acs.filter((a) => a.room === room.id);
        const blinds = config.blinds.filter((b) => b.room === room.id);
        if (!lights.length && !acs.length && !blinds.length) continue;
        L.push('', `### ${room.name}`);
        if (blinds.length > 1) L.push(`- All ${room.name} blinds: open ${base}/do/room/${room.id}/blinds/open · close ${base}/do/room/${room.id}/blinds/close`);
        for (const b of blinds) {
          const u = `${base}/do/blind/${encodeURIComponent(b.id)}`;
          const parts = [`open ${u}/open`, `close ${u}/close`];
          if (b.capabilities.includes('stop')) parts.push(`stop ${u}/stop`);
          if (b.capabilities.includes('position')) for (const p of [25, 50, 75]) parts.push(`${p}% open ${u}/position/${p}`);
          L.push(`- ${b.name} [${blindState(state.blinds[b.id])}]: ${parts.join(' · ')}`);
        }
        if (lights.length > 1) L.push(`- All ${room.name} lights: on ${base}/do/room/${room.id}/lights/on · off ${base}/do/room/${room.id}/lights/off`);
        for (const l of lights) {
          const u = `${base}/do/light/${encodeURIComponent(l.id)}`;
          const parts = [`on ${u}/on`, `off ${u}/off`];
          if (l.capabilities.includes('brightness')) for (const b of [10, 30, 50, 75, 100]) parts.push(`${b}% ${u}/brightness/${b}`);
          if (l.capabilities.includes('temp')) for (const w of Object.keys(WHITES)) parts.push(`${w} white ${u}/${w}`);
          if (l.capabilities.includes('color')) for (const c of Object.keys(COLORS)) parts.push(`${c} ${u}/color/${c}`);
          L.push(`- ${l.name} [${lightState(l)}]: ${parts.join(' · ')}`);
        }
        for (const a of acs) {
          const u = `${base}/do/ac/${encodeURIComponent(a.id)}`;
          const f = store.acFeatures(a.id);
          const temps = [];
          for (let t = Math.max(a.min, 17); t <= Math.min(a.max, 28); t++) temps.push(`${t}° ${u}/temp/${t}`);
          L.push(`- ${a.name} [${acState(a)}]: on ${u}/on · off ${u}/off`);
          L.push(`  - temperature (switches it on): ${temps.join(' · ')}`);
          L.push(`  - mode: ${f.modes.map((m) => `${m} ${u}/mode/${m}`).join(' · ')}`);
          L.push(`  - fan: ${f.fans.map((m) => `${m} ${u}/fan/${m}`).join(' · ')}`);
        }
      }
      L.push('');
    }

    if (edit) {
      L.push('## Changing the home itself (the 3D model)', '');
      L.push('The user may send photos of a room and ask you to model it, or say they moved the sofa. '
        + 'That takes the MCP tools or the HTTP API (it needs a request body), not plain links:', '');
      L.push(`1. Read the plan: \`get_floor_plan\` (or \`GET ${base}/plan.json\`). It explains the coordinates and lists every furniture type with its size.`);
      L.push('2. From the photos, work out each piece of furniture: its type, size, and where it stands in the room. Walls, windows and doors in the photo tell you which way the room faces.');
      L.push('3. Send one `edit_floor_plan` with a `furnish_room` operation that lists every piece in that room. It replaces what was there; the model on the user\'s screen changes at once.');
      L.push('4. Optionally check the result with `render_home` (a picture of the model). `undo_floor_plan_edit` puts the previous version back.', '');
      const room = config.rooms[0]?.id || 'living';
      L.push('Example:', '', '```json',
        `{"operations": [{"op": "furnish_room", "room": "${room}", "items": [`,
        '  {"type": "sofa", "pos": [3.9, 6.0], "rot": -90, "width": 2.4, "color": "#8b93a7"},',
        '  {"type": "coffeeTable", "pos": [2.4, 6.0], "rot": 90},',
        '  {"type": "rug", "pos": [2.4, 6.0], "size": [2.4, 3.0], "color": "#3b4a66"}',
        ']}], "note": "Rebuilt the living room from your photos"}', '```', '');
      L.push(PLAN_RULES, '');
    }
    L.push('---', 'House Control · the owner can stop this link at any time; then it simply stops answering.');
    return L.join('\n');
  }

  /* ---------- entry point ---------- */

  return {
    async handle(request) {
      const { op, permissions, base, client } = request;
      switch (op) {
        case 'tools': return { tools: listTools(permissions) };
        case 'call': return callTool(request.tool, request.arguments, permissions, client);
        case 'guide': return { text: guide(base, permissions) };
        case 'instructions': return { text: instructions(permissions) };
        case 'link': return link(request.path || [], base, permissions, client);
        default: return { error: `Unknown request ${op}` };
      }
    },
  };
}

const capitalise = (s) => s.charAt(0).toUpperCase() + s.slice(1);

const PLAN_RULES = `Floor plan rules:
- Metres, seen from above. x grows to the east (right), z grows to the south (down). Heights are metres above the floor.
- A room is a rectangle "rect": [x, z, width, depth]. Rooms that touch share a wall; an L-shaped room is two rooms.
- Furniture: "type", "pos" [x, z] = centre of the piece, "rot" in degrees. At rot 0 a piece's back is to the north and its front faces south (+z);
  rot 90 faces east, -90 faces west, 180 faces north. A sofa against the east wall facing a TV on the west wall: sofa rot -90, TV rot 90.
  "width" is the size along its front; depth comes from the type. Keep pieces inside their room, about 5 cm off the walls.
- Openings: doors, windows and open gaps sit on walls, given by two end points "from"/"to" on that wall line.
- Lights: "type" ceiling, pendant, spots, floor, table or strip; "capabilities" any of brightness, temp, color (none = plain switch).
- Air conditioners hang on a wall: "wall" north/south/east/west and "pos" on that wall line.
- Blinds hang in a window: "from"/"to" the same as the window's, "room" the room it is in, "style" roller, sheer or blackout.
- Devices marked "linked": true are real hardware: keep their ids, do not remove them.`;
