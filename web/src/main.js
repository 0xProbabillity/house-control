import { loadConfig } from './config.js';
import { createStore } from './store.js';
import { createWorld } from './three/world.js';
import { createPanel } from './ui/panel.js';
import { h, openMenu } from './ui/dom.js';
import { icon } from './ui/icons.js';
import { isNative, post, incoming } from './bridge.js';

const DEMO_PLANS = [
  { id: 'home', name: 'Demo · Apartment' },
  { id: 'studio', name: 'Demo · Studio' },
];
const STAGE_INSETS = [62, 50]; // header above, panel overlap below

const app = document.getElementById('app');
if (isNative) document.documentElement.classList.add('native');

function fatal(title, error) {
  console.error(error);
  app.replaceChildren(h('div.fatal', h('h1', title),
    'The floor plan could not be loaded. Fix the file and reload, or pick another plan from the menu bar icon.',
    h('code', String(error?.message || error))));
  post('ready', { error: String(error?.message || error) });
}

async function boot() {
  let config;
  try {
    config = await loadConfig();
  } catch (error) {
    fatal('Could not open this home', error);
    return;
  }

  const store = createStore(config);
  const linked = [...config.lights, ...config.acs].some((d) => d.tuya?.deviceId);
  // Never invent a starting state for real hardware: it reports its own.
  if (!store.restored && !linked) {
    // First launch: start with something worth looking at.
    const first = config.scenes.find((s) => s.id === 'cozy') || config.scenes[1] || config.scenes[0];
    if (first) store.applyScene(first.id);
    if (config.acs[0]) store.setAC(config.acs[0].id, { on: true, target: 23 });
  }

  let world;
  const panel = createPanel(app, config, store, {
    onFocus: (target) => world?.focus(target),
    onMenu: (anchor, reason) => (reason === 'escape' ? post('close') : planMenu(anchor)),
  });

  try {
    world = createWorld(panel.canvas, config, store, {
      onHover: panel.showTooltip,
      onPick(target) {
        if (!target) return;
        if (target.kind === 'light') store.toggleLight(target.id);
        else if (target.kind === 'ac') panel.openSheet(target);
        else if (target.kind === 'room') panel.selectRoom(target.id);
      },
    });
  } catch (error) {
    fatal('3D view failed to start', error);
    return;
  }

  panel.attach(world);
  world.setInsets(...STAGE_INSETS);
  new ResizeObserver(() => world.resize()).observe(panel.canvas);

  const show = () => { world.setRunning(true); world.intro(); };
  const hide = () => { world.setRunning(false); };
  incoming.shown = show;
  incoming.hidden = () => { hide(); panel.closeSheet(); if (panel.room !== 'all') panel.selectRoom('all'); };
  incoming.setNotch = (x) => panel.setNotch(x);
  incoming.applyRemote = (update) => store.applyRemote(update);
  store.onDeviceError = (id, message) => {
    const name = store.lightCfg.get(id)?.name || store.acCfg.get(id)?.name || id;
    panel.toast(`${name}: ${message}`);
  };
  // The loop pauses whenever the page is hidden; any sign of life resumes it.
  const resume = () => { if (!document.hidden) world.setRunning(true); };
  document.addEventListener('visibilitychange', () => (document.hidden ? hide() : resume()));
  for (const type of ['focus', 'pageshow', 'pointermove', 'pointerdown']) window.addEventListener(type, resume, { passive: true });

  function planMenu(anchor) {
    const current = window.__HOUSE_BOOT__?.plan ?? (new URLSearchParams(location.search).get('plan') || 'home');
    const items = DEMO_PLANS.map((p) => ({
      label: p.name,
      selected: p.id === current,
      icon: p.id === current ? icon('check', 16, 2.4) : null,
      action: () => {
        if (isNative) post('selectPlan', { plan: p.id });
        else location.search = `?plan=${p.id}`;
      },
    }));
    if (window.__HOUSE_BOOT__?.hasCustomPlan) {
      items.unshift({
        label: 'My home',
        selected: current === 'custom',
        icon: current === 'custom' ? icon('check', 16, 2.4) : null,
        action: () => post('selectPlan', { plan: 'custom' }),
      });
    }
    if (isNative) {
      items.push('-',
        { label: 'Edit home…', action: () => post('openEditor') },
        { label: 'Load floor plan…', action: () => post('loadPlan') },
        { label: 'Reveal plan file', action: () => post('revealPlan') },
        '-',
        { label: 'Quit House Control', action: () => post('quit') });
    }
    openMenu(panel.anchorMenu, anchor, items);
  }

  const opened = window.__HOUSE_BOOT__?.openDevice || new URLSearchParams(location.search).get('device');
  if (store.acCfg.has(opened)) panel.openSheet({ kind: 'ac', id: opened });
  else if (store.lightCfg.has(opened)) panel.openSheet({ kind: 'light', id: opened });

  if (!isNative) show();
  post('ready', { summary: store.summary() });
  window.__house = { store, world, panel, config }; // handy in the dev console
}

const mode = window.__HOUSE_BOOT__?.mode || new URLSearchParams(location.search).get('mode') || 'panel';
if (mode === 'editor') {
  document.documentElement.classList.add('mode-editor');
  import('./editor/editor.js').then((m) => m.bootEditor(app)).catch((e) => fatal('Editor failed to start', e));
} else {
  boot();
}
