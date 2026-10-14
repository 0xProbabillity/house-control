// The home as the widgets and controls draw it (HomeSnapshot in core/…/HomeSnapshot.swift):
// rooms, lamps, ACs and scenes with their current state. Posted to the native shell, which
// keeps it where its widgets can read it; only the panel posts, the other views are copies.
import { post } from './bridge.js';
import { linkOf, LINK_FIELDS } from './config.js';
import { footprint } from './three/furniture.js';

const round = (v, digits = 3) => (Number.isFinite(v) ? Math.round(v * 10 ** digits) / 10 ** digits : v);

function links(device) {
  const out = {};
  for (const key of LINK_FIELDS) if (device[key]) out[key] = device[key];
  return Object.keys(out).length ? out : null;
}

export function widgetSnapshot(config, store, plan) {
  const { state } = store;
  return {
    version: 1,
    name: config.name,
    plan,
    outdoorTemp: config.outdoorTemp,
    updated: Date.now() / 1000,
    scene: state.scene || null,
    rooms: config.rooms.map((r) => ({ id: r.id, name: r.name, x: r.x, z: r.z, w: r.w, d: r.d, floor: r.floor })),
    lights: config.lights.map((l) => {
      const s = state.lights[l.id];
      return {
        id: l.id, name: l.name, room: l.room, type: l.type, x: l.pos[0], z: l.pos[1],
        capabilities: l.capabilities, on: s.on, brightness: round(s.brightness), temp: Math.round(s.temp),
        color: s.color || null, service: linkOf(l)?.service || null, links: links(l),
      };
    }),
    acs: config.acs.map((a) => {
      const s = state.acs[a.id];
      return {
        id: a.id, name: a.name, room: a.room, wall: a.wall, x: a.pos[0], z: a.pos[1], min: a.min, max: a.max,
        on: s.on, target: s.target, mode: s.mode, fan: s.fan, roomTemp: round(s.roomTemp, 1),
        swing: s.swing, sleep: s.sleep, eco: s.eco, service: linkOf(a)?.service || null, links: links(a),
      };
    }),
    furniture: config.furniture.filter((f) => Array.isArray(f.pos)).map((f) => {
      const [w, d] = footprint(f);
      return { type: f.type, x: f.pos[0], z: f.pos[1], w, d, rot: f.rot || 0, color: f.color || null };
    }),
    scenes: config.scenes.map((s) => ({ id: s.id, name: s.name, icon: s.icon, lights: s.lights, acs: s.acs })),
  };
}

/** Posts the snapshot after every change (and now and then while a room's temperature drifts). */
export function publishWidgets(config, store) {
  const plan = window.__HOUSE_BOOT__?.plan || new URLSearchParams(location.search).get('plan') || 'home';
  let timer = 0;
  let lastTick = 0;
  const send = () => { timer = 0; post('widgets', { snapshot: widgetSnapshot(config, store, plan) }); };
  const soon = (delay) => { if (!timer) timer = setTimeout(send, delay); };
  store.on((change) => {
    if (change.type !== 'tick') { soon(250); return; }
    // The simulated room temperature creeps a tenth of a degree at a time: once a minute is plenty.
    if (Date.now() - lastTick > 60000) { lastTick = Date.now(); soon(250); }
  });
  send();
}

/** Runs an action a widget made (HomeAction in Swift), like a tap in the panel would. */
export function runWidgetAction(store, config, action) {
  const { kind, id } = action;
  switch (kind) {
    case 'light':
      if (store.lightCfg.has(id)) store.setLight(id, { on: action.on ?? !store.state.lights[id].on });
      break;
    case 'room': {
      const ids = config.lights.filter((l) => l.room === id).map((l) => l.id);
      const on = action.on ?? !ids.some((l) => store.state.lights[l].on);
      for (const l of ids) store.setLight(l, { on });
      break;
    }
    case 'allLights':
      store.setAllLights(action.on ?? !Object.values(store.state.lights).some((l) => l.on));
      break;
    case 'scene':
      store.applyScene(id);
      break;
    case 'acPower':
      if (store.acCfg.has(id)) store.setAC(id, { on: action.on ?? !store.state.acs[id].on });
      break;
    case 'acTarget':
      if (store.acCfg.has(id) && Number.isFinite(action.target)) store.setAC(id, { target: action.target });
      break;
    default:
      return false;
  }
  return true;
}
