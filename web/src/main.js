import { loadRawConfig, normalize, isLinked } from './config.js';
import { createStore } from './store.js';
import { createWorld } from './three/world.js';
import { createPanel } from './ui/panel.js';
import { createAgent } from './agent/tools.js';
import { h, openMenu } from './ui/dom.js';
import { icon } from './ui/icons.js';
import { isNative, isPhone, post, incoming, haptic } from './bridge.js';
import { publishWidgets, runWidgetAction } from './widgets.js';

const DEMO_PLANS = [
  { id: 'home', name: 'Demo · Apartment' },
  { id: 'studio', name: 'Demo · Studio' },
];
const STAGE_INSETS = [62, 50]; // header above, panel overlap below

const app = document.getElementById('app');
if (isNative) document.documentElement.classList.add('native');
if (isPhone) document.documentElement.classList.add('ios');

// ?safeTop=62&safeBottom=34 stands in for a phone's safe areas when its layout is looked at in a browser.
for (const edge of ['top', 'bottom']) {
  const px = Number(new URLSearchParams(location.search).get(edge === 'top' ? 'safeTop' : 'safeBottom'));
  if (isPhone && px) document.documentElement.style.setProperty(`--safe-${edge}-preview`, `${px}px`);
}

// Height of the status bar / Dynamic Island on a phone; 0 everywhere else.
function safeAreaTop() {
  const probe = document.body.appendChild(h('div', { style: { position: 'fixed', paddingTop: 'var(--safe-top-preview, env(safe-area-inset-top, 0px))' } }));
  const top = parseFloat(getComputedStyle(probe).paddingTop) || 0;
  probe.remove();
  return top;
}

function fatal(title, error) {
  console.error(error);
  app.replaceChildren(h('div.fatal', h('h1', title),
    'The floor plan could not be loaded. Fix the file and reload, or pick another plan from the menu bar icon.',
    h('code', String(error?.message || error))));
  post('ready', { error: String(error?.message || error) });
}

async function boot() {
  let config;
  let raw;
  try {
    raw = await loadRawConfig();
    config = normalize(structuredClone(raw));
  } catch (error) {
    fatal('Could not open this home', error);
    return;
  }

  const store = createStore(config);
  const linked = [...config.lights, ...config.acs].some(isLinked);
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
    onMenu: (anchor, reason) => {
      if (reason === 'escape') post('close');
      else if (reason === 'agent') post('openAgent');
      else if (isPhone) post('openSettings'); // plans, sync and sign-in are native screens there
      else planMenu(anchor);
    },
  });

  try {
    world = createWorld(panel.canvas, config, store, {
      onHover: panel.showTooltip,
      onPick(target) {
        if (!target) return;
        if (target.kind === 'light') { haptic('light'); store.toggleLight(target.id); }
        else if (target.kind === 'ac') panel.openSheet(target);
        else if (target.kind === 'room') panel.selectRoom(target.id);
      },
    });
  } catch (error) {
    fatal('3D view failed to start', error);
    return;
  }

  panel.attach(world);
  // On a phone the header sits lower (status bar) but is closer to the model.
  const applyInsets = () => (isPhone ? world.setInsets(50 + safeAreaTop(), 36) : world.setInsets(...STAGE_INSETS));
  applyInsets();
  new ResizeObserver(() => (isPhone ? applyInsets() : world.resize())).observe(panel.canvas);

  const show = () => { world.setRunning(true); world.intro(); };
  const hide = () => { world.setRunning(false); };
  incoming.shown = show;
  incoming.hidden = () => { hide(); panel.closeSheet(); if (panel.room !== 'all') panel.selectRoom('all'); };
  incoming.setNotch = (x) => panel.setNotch(x);
  if (isPhone) {
    // Swiping in from the left edge goes back from a device sheet, as it does everywhere on iOS.
    let edge = null;
    window.addEventListener('pointerdown', (ev) => { edge = ev.clientX < 28 ? { x: ev.clientX, y: ev.clientY } : null; }, true);
    window.addEventListener('pointerup', (ev) => {
      const swiped = edge && ev.clientX - edge.x > 56 && Math.abs(ev.clientY - edge.y) < 80;
      edge = null;
      if (swiped && panel.closeSheet()) haptic('light');
    }, true);
    window.addEventListener('pointercancel', () => { edge = null; }, true);
  }
  incoming.applyRemote = (update) => store.applyRemote(update);
  incoming.adopt = (state) => store.adopt(state);
  incoming.share = () => store.share();
  // Widgets and controls: what they changed while the app was away is run here, where it
  // reaches the devices; a widget's tap on a lamp or a scene opens that in the panel.
  incoming.widget = (actions) => {
    store.source = 'Widget';
    try {
      for (const action of [].concat(actions)) runWidgetAction(store, config, action);
    } finally {
      store.source = null;
    }
  };
  incoming.openDevice = (id) => {
    if (store.acCfg.has(id)) panel.openSheet({ kind: 'ac', id });
    else if (store.lightCfg.has(id)) panel.openSheet({ kind: 'light', id });
    else if (config.rooms.some((r) => r.id === id)) { panel.closeSheet(); panel.selectRoom(id); }
  };
  // AI Access: an AI assistant's requests are run here, where the state of every device lives.
  const agent = createAgent({
    store, config, raw,
    render: (room) => renderShot(config, store, room),
    onAction: ({ client, summary }) => { if (summary) panel.toast(summary, client || 'AI'); },
  });
  incoming.agent = async (request) => {
    store.source = request.client || 'AI'; // the other views say who made the change
    try {
      return JSON.stringify(await agent.handle(request));
    } finally {
      store.source = null;
    }
  };
  incoming.agentLive = (live) => panel.setAgentLive(Boolean(live));
  panel.setAgentLive(Boolean(window.__HOUSE_BOOT__?.agentLive));
  // 'on', 'off' or 'needsApproval' (switched on, waiting to be allowed in System Settings).
  let openAtLogin = window.__HOUSE_BOOT__?.openAtLogin || 'off';
  incoming.openAtLogin = (state) => { openAtLogin = state; };

  store.onDeviceError = (id, message) => {
    const name = store.lightCfg.get(id)?.name || store.acCfg.get(id)?.name || id;
    panel.toast(`${name}: ${message}`);
    haptic('error');
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
        { label: 'AI access…', action: () => post('openAgent') },
        { label: 'Load floor plan…', action: () => post('loadPlan') },
        { label: 'Reveal plan file', action: () => post('revealPlan') },
        '-',
        {
          label: openAtLogin === 'needsApproval' ? 'Open at login — allow in Settings…' : 'Open at login',
          icon: openAtLogin === 'on' ? icon('check', 16, 2.4) : null,
          action: () => post('setOpenAtLogin', { on: openAtLogin !== 'on' }),
        },
        { label: 'Quit House Control', action: () => post('quit') });
    }
    openMenu(panel.anchorMenu, anchor, items);
  }

  const opened = window.__HOUSE_BOOT__?.openDevice || new URLSearchParams(location.search).get('device');
  if (store.acCfg.has(opened)) panel.openSheet({ kind: 'ac', id: opened });
  else if (store.lightCfg.has(opened)) panel.openSheet({ kind: 'light', id: opened });

  if (!isNative) show();
  post('ready', { summary: store.summary() });
  if (isNative) publishWidgets(config, store);
  window.__house = { store, world, panel, config }; // handy in the dev console
}

// A still of the 3D model for an AI checking its own edit: a second, off-screen world
// rendered once and thrown away, so the panel's own view is left as it is.
async function renderShot(config, store, room) {
  const canvas = h('canvas', { style: { width: '100%', height: '100%', display: 'block' } });
  const holder = h('div', { style: { position: 'fixed', left: '-4000px', top: '0', width: '880px', height: '660px', pointerEvents: 'none' } }, canvas);
  document.body.append(holder);
  let shot;
  try {
    shot = createWorld(canvas, config, store, { onHover() {}, onPick() {} });
    shot.setInsets(0, 0);
    if (room) shot.focus({ kind: 'room', id: room });
    shot.settle(8);
    return canvas.toDataURL('image/jpeg', 0.86);
  } finally {
    shot?.dispose();
    holder.remove();
  }
}

const mode = window.__HOUSE_BOOT__?.mode || new URLSearchParams(location.search).get('mode') || 'panel';
if (mode === 'editor') {
  document.documentElement.classList.add('mode-editor');
  import('./editor/editor.js').then((m) => m.bootEditor(app)).catch((e) => fatal('Editor failed to start', e));
} else if (mode === 'agent') {
  import('./agent/console.js').then((m) => m.bootConsole(app)).catch((e) => fatal('AI Access failed to start', e));
} else if (mode === 'island') {
  document.documentElement.classList.add('mode-island');
  import('./island/island.js').then((m) => m.bootIsland(app)).catch((e) => console.error(e));
} else {
  boot();
}
