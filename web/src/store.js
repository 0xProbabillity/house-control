import { post, call, isNative } from './bridge.js';

const STORAGE_KEY = 'house-control:state:v1';

export const AC_MODES = ['cool', 'heat', 'dry', 'fan', 'auto'];
export const AC_FANS = ['auto', 'low', 'medium', 'high', 'turbo'];
export const AC_SWINGS = ['swing', 'l1', 'l2', 'l3', 'l4', 'l5', 'off'];

const clamp = (v, a, b) => Math.min(b, Math.max(a, v));

function defaultLight(cfg) {
  return { on: false, brightness: 0.8, temp: 3000, color: cfg.color || null };
}

function defaultAC(cfg, outdoor) {
  return {
    on: false, target: 24, mode: 'cool', fan: 'auto', swing: 'swing',
    sleep: false, eco: false, roomTemp: Math.min(outdoor - 2, 27),
  };
}

export function createStore(config) {
  const listeners = new Set();
  const lightCfg = new Map(config.lights.map((l) => [l.id, l]));
  const acCfg = new Map(config.acs.map((a) => [a.id, a]));

  const state = { lights: {}, acs: {}, scene: null };
  for (const l of config.lights) state.lights[l.id] = defaultLight(l);
  for (const a of config.acs) state.acs[a.id] = defaultAC(a, config.outdoorTemp);
  // What each real AC can do, as reported by the native side. A simulated AC can do everything.
  const features = {};

  let restored = false;
  try {
    const saved = JSON.parse(localStorage.getItem(STORAGE_KEY) || 'null');
    if (saved && saved.home === config.name) {
      for (const [id, s] of Object.entries(saved.lights || {})) if (state.lights[id]) Object.assign(state.lights[id], s);
      for (const [id, s] of Object.entries(saved.acs || {})) if (state.acs[id]) Object.assign(state.acs[id], s);
      for (const [id, f] of Object.entries(saved.features || {})) if (state.acs[id]) features[id] = f;
      state.scene = saved.scene || null;
      restored = true;
    }
  } catch { /* storage unavailable: start from defaults */ }

  let saveTimer = 0;
  function persist() {
    clearTimeout(saveTimer);
    saveTimer = setTimeout(() => {
      try {
        localStorage.setItem(STORAGE_KEY, JSON.stringify({ home: config.name, ...state, features }));
      } catch { /* ignore */ }
    }, 200);
  }

  function emit(change) {
    for (const fn of listeners) fn(change);
    if (change.type !== 'tick') {
      persist();
      post('summary', summary());
      // The native shell passes this on to its other views of the same home (the panel
      // and the island each run their own store), which adopt it without re-sending.
      if (!change.adopted) post('state', { lights: state.lights, acs: state.acs, scene: state.scene, source: change.source ?? store.source ?? null });
    }
  }

  // One command per device is in flight at a time. Whatever changes meanwhile is merged
  // into a single follow-up, so dragging a slider costs a couple of requests (or infrared
  // key presses) instead of dozens. A change the device refuses is rolled back.
  const COOL_DOWN = { light: 300, ac: 900 };
  const outbox = new Map();

  function transmit(kind, id, patch) {
    if (!isNative) return Promise.resolve();
    const current = kind === 'light' ? state.lights[id] : state.acs[id];
    const sent = call('command', { kind, id, patch, state: { ...current } });
    // Never let a lost reply block the device for good.
    return Promise.race([sent, new Promise((resolve) => setTimeout(resolve, 20000))]);
  }

  function dispatch(kind, id, patch, before) {
    const slot = outbox.get(id);
    if (slot) {
      slot.pending = { ...slot.pending, ...patch };
      slot.before = { ...before, ...slot.before }; // the oldest value is the one to return to
      return;
    }
    const entry = { pending: null, before: null };
    outbox.set(id, entry);
    run(kind, id, patch, before, entry);
  }

  function run(kind, id, patch, before, entry) {
    const started = performance.now();
    transmit(kind, id, patch)
      .catch((error) => rollback(kind, id, patch, before, entry, error))
      .then(() => setTimeout(() => {
        if (!entry.pending) { outbox.delete(id); return; }
        const [next, prior] = [entry.pending, entry.before];
        entry.pending = entry.before = null;
        run(kind, id, next, prior, entry);
      }, Math.max(0, COOL_DOWN[kind] - (performance.now() - started))));
  }

  function rollback(kind, id, patch, before, entry, error) {
    const current = kind === 'light' ? state.lights[id] : state.acs[id];
    let any = false;
    for (const key of error.detail?.failed || Object.keys(patch)) {
      if (!(key in patch)) continue;
      // Changed again in the meantime: that follow-up now falls back to the last good value.
      if (entry.pending && key in entry.pending) { entry.before[key] = before[key]; continue; }
      if (current[key] !== patch[key]) continue; // a real device reported something newer
      current[key] = before[key];
      any = true;
    }
    if (any) emit({ type: kind, id, reverted: true });
    store.onDeviceError?.(id, error.message);
  }

  function sanitizeLight(id, patch) {
    const caps = lightCfg.get(id).capabilities;
    const out = {};
    if ('on' in patch) out.on = Boolean(patch.on);
    if ('brightness' in patch && caps.includes('brightness')) out.brightness = clamp(patch.brightness, 0.05, 1);
    if ('temp' in patch && caps.includes('temp')) { out.temp = clamp(patch.temp, 2200, 6500); out.color = null; }
    if ('color' in patch && caps.includes('color')) out.color = patch.color;
    return out;
  }

  function writeLight(id, patch, { remote = false } = {}) {
    const cur = state.lights[id];
    if (!cur) return false;
    const clean = sanitizeLight(id, patch);
    // Only what actually changed is worth sending to the device.
    const diff = Object.fromEntries(Object.entries(clean).filter(([k, v]) => cur[k] !== v));
    if (!Object.keys(diff).length) return false;
    const before = Object.fromEntries(Object.keys(diff).map((k) => [k, cur[k]]));
    Object.assign(cur, clean);
    if (!remote) dispatch('light', id, diff, before);
    return true;
  }

  function writeAC(id, patch, { remote = false } = {}) {
    const cur = state.acs[id];
    const cfg = acCfg.get(id);
    if (!cur) return false;
    const clean = { ...patch };
    if ('target' in clean) clean.target = clamp(Math.round(clean.target), cfg.min, cfg.max);
    const diff = Object.fromEntries(Object.entries(clean).filter(([k, v]) => cur[k] !== v));
    if (!Object.keys(diff).length) return false;
    const before = Object.fromEntries(Object.keys(diff).map((k) => [k, cur[k]]));
    Object.assign(cur, clean);
    const { roomTemp, ...sendable } = diff;
    if (!remote && Object.keys(sendable).length) dispatch('ac', id, sendable, before);
    return true;
  }

  function summary() {
    const lights = Object.values(state.lights);
    const acs = Object.entries(state.acs).filter(([, a]) => a.on);
    return {
      lightsOn: lights.filter((l) => l.on).length,
      lightsTotal: lights.length,
      acOn: acs.length,
      acTarget: acs.length ? acs[0][1].target : null,
      acMode: acs.length ? acs[0][1].mode : null,
    };
  }

  const store = {
    state,
    config,
    restored,
    lightCfg,
    acCfg,
    summary,
    /** Set by the UI: called with (device id, message) when a real device refuses a change. */
    onDeviceError: null,
    /** Who is changing things right now when it is not the person at this screen ("ChatGPT"…). */
    source: null,

    /** What the panel may offer for this AC: modes, fan speeds, and the optional extras. */
    acFeatures(id) {
      return features[id] || { modes: AC_MODES, fans: AC_FANS, sleep: true, eco: true, swing: true };
    },

    on(fn) { listeners.add(fn); return () => listeners.delete(fn); },

    setLight(id, patch) {
      if (writeLight(id, patch)) { state.scene = null; emit({ type: 'light', id }); }
    },
    toggleLight(id) { store.setLight(id, { on: !state.lights[id].on }); },

    setAllLights(on) {
      let any = false;
      for (const id of Object.keys(state.lights)) any = writeLight(id, { on }) || any;
      if (any) { state.scene = null; emit({ type: 'bulk' }); }
    },

    setAC(id, patch) {
      if (writeAC(id, patch)) emit({ type: 'ac', id });
    },

    applyScene(sceneId) {
      const scene = config.scenes.find((s) => s.id === sceneId);
      if (!scene) return;
      for (const id of Object.keys(state.lights)) {
        const patch = { ...(scene.lights['*'] || {}), ...(scene.lights[id] || {}) };
        // A scene that sets a white temperature should not be overridden by a stale colour.
        if (!('color' in patch) && 'temp' in patch) patch.color = null;
        writeLight(id, patch);
      }
      for (const id of Object.keys(state.acs)) {
        const patch = { ...(scene.acs['*'] || {}), ...(scene.acs[id] || {}) };
        if (Object.keys(patch).length) writeAC(id, patch);
      }
      state.scene = sceneId;
      emit({ type: 'bulk', scene: sceneId });
    },

    /** Reports the state again, for a view that has only just started. */
    share() { post('state', { lights: state.lights, acs: state.acs, scene: state.scene }); },

    // The state of another view of this home (see emit). Nothing goes to the devices:
    // the view where the change was made has already sent it.
    adopt(other) {
      let any = false;
      for (const [id, s] of Object.entries(other.lights || {})) any = writeLight(id, s, { remote: true }) || any;
      for (const [id, s] of Object.entries(other.acs || {})) any = writeAC(id, s, { remote: true }) || any;
      const scene = other.scene ?? null;
      if (scene !== state.scene) { state.scene = scene; any = true; }
      if (any) emit({ type: 'bulk', remote: true, adopted: true, source: other.source || null });
    },

    // State reported by real devices (native provider). Never echoed back as a command.
    applyRemote(update) {
      let any = false;
      for (const [id, patch] of Object.entries(update.lights || {})) any = writeLight(id, patch, { remote: true }) || any;
      for (const [id, patch] of Object.entries(update.acs || {})) any = writeAC(id, patch, { remote: true }) || any;
      for (const [id, f] of Object.entries(update.features || {})) {
        if (!state.acs[id] || JSON.stringify(features[id]) === JSON.stringify(f)) continue;
        features[id] = f;
        any = true;
      }
      if (any) emit({ type: 'bulk', remote: true });
    },
  };

  // Without real sensors the room temperature is simulated: it drifts towards the
  // set-point while an AC runs and back towards the outdoor-ish ambient when it is off.
  setInterval(() => {
    let any = false;
    for (const [id, a] of Object.entries(state.acs)) {
      const cfg = acCfg.get(id);
      if (cfg.tuya?.sensorId || cfg.sensor?.id || cfg.link?.id) continue; // a real sensor or unit reports this room
      const ambient = Math.min(config.outdoorTemp - 2, 27);
      const goal = a.on && a.mode !== 'fan' ? a.target : ambient;
      const step = a.on ? 0.2 : 0.1;
      const next = Math.abs(goal - a.roomTemp) <= step ? goal : a.roomTemp + Math.sign(goal - a.roomTemp) * step;
      if (next !== a.roomTemp) { a.roomTemp = Math.round(next * 10) / 10; any = true; }
    }
    if (any) { for (const fn of listeners) fn({ type: 'tick' }); persist(); }
  }, 3000);

  return store;
}
