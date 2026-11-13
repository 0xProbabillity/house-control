// Home editor (a window on the Mac, full screen on the iPhone): a top-down plan you can drag
// things around on, an inspector for the selected item, a live 3D preview and the links to
// real devices. On a phone the same pieces are laid out for a finger: the plan fills the
// screen, the inspector is a sheet from the bottom, pinch zooms and drag pans.
import './editor.css';
import { normalize, loadRawConfig, LIGHT_KINDS, FLOOR_KINDS, isLinked, levelsOf } from '../config.js';
import { createWorld } from '../three/world.js';
import { FURNITURE_TYPES, footprint } from '../three/furniture.js';
import { h, clamp } from '../ui/dom.js';
import { icon } from '../ui/icons.js';
import { isNative, isPhone, call, post, haptic, incoming } from '../bridge.js';
import { createConnections } from './connections.js';

const SVG = 'http://www.w3.org/2000/svg';
const sv = (tag, attrs = {}, ...kids) => {
  const el = document.createElementNS(SVG, tag);
  for (const [k, v] of Object.entries(attrs)) if (v != null) el.setAttribute(k, v);
  el.append(...kids.filter((k) => k != null));
  return el;
};

const KEYS = { room: 'rooms', light: 'lights', ac: 'acs', furniture: 'furniture', opening: 'openings', scene: 'scenes' };
const TITLES = { room: 'Rooms', light: 'Lights', ac: 'Air conditioners', furniture: 'Furniture', opening: 'Doors & windows', scene: 'Scenes' };
const FLOOR_FILL = { oak: '#4a3d2e', walnut: '#3c2f28', tile: '#39424b', stone: '#30353c' };
const WALLS = ['north', 'east', 'south', 'west'];
const LEVEL_NAMES = ['Ground floor', 'First floor', 'Second floor', 'Third floor', 'Fourth floor', 'Fifth floor'];
const HANDLES = { nw: [0, 0], n: [0.5, 0], ne: [1, 0], e: [1, 0.5], se: [1, 1], s: [0.5, 1], sw: [0, 1], w: [0, 0.5] };
const MIN_ROOM = 0.6; // metres, either way
const SCENE_ICONS = ['sun', 'sofa', 'film', 'moon', 'door', 'table', 'bed', 'tv', 'power', 'sparkles'];
const REGIONS = [
  ['eu', 'Central Europe'], ['eu-w', 'Western Europe'], ['us', 'Western America'], ['us-e', 'Eastern America'],
  ['cn', 'China'], ['in', 'India'], ['sg', 'Singapore'],
];

const round = (v, step = 0.05) => Math.round(v / step) * step;
const fix = (v) => Math.round(v * 1000) / 1000;
const slug = (t) => String(t).toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '') || 'item';

export async function bootEditor(root) {
  let doc = structuredClone(await loadRawConfig());
  for (const key of Object.values(KEYS)) doc[key] ||= [];

  // "connections", "service:smartlife|homeassistant|hue|homekit": where the editor opens
  // (HOUSE_OPEN_EDITOR, or the Mac's Settings window through incoming.openSection).
  const sectionSel = (at) => (at === 'connections' ? { kind: 'connections' }
    : at.startsWith('service:') ? { kind: 'service', service: at.slice(8) }
      : at === 'tuya' ? { kind: 'service', service: 'smartlife' } : { kind: 'home' });
  let sel = sectionSel(window.__HOUSE_BOOT__?.section || new URLSearchParams(location.search).get('section') || '');
  let dirty = false;
  let world = null;
  let phone = null; // the iPhone's layout and gestures, set up by buildPhoneLayout()
  let previewLights = true;
  let level = levelsOf(doc)[0].id; // the floor being edited
  let view = null; // the part of the plan on show, a box in metres, or null to fit the floor
  const undo = [];
  const redo = [];
  const tuya = {
    info: window.__HOUSE_BOOT__?.tuya || { configured: false, accessId: '', region: 'eu' },
    account: window.__HOUSE_BOOT__?.smartLife || { connected: false, userCode: '', account: '' },
    devices: null, busy: false, error: null, qr: null,
    get linked() { return this.account.connected || this.info.configured; },
  };
  const links = createConnections({
    rerender: () => {
      renderSidebar();
      if (['connections', 'service', 'light', 'ac'].includes(sel.kind)) renderInspector();
    },
    toast,
    usedBy: () => links.usedMap(doc),
    // On the iPhone the connection screens are native ones, shown over the editor.
    onOpen: (service) => (isPhone && service ? post('openConnection', { service })
      : select(service ? { kind: 'service', service } : { kind: 'connections' })),
  });
  // Smart Life signed in or out on its own screen: the overview and the pickers follow.
  const smartLifeChanged = () => links.refreshInfo().then(() => links.load({ quiet: true }));

  /* ---------- layout ---------- */

  const nameInput = h('input.title-input', { value: doc.name || 'Home', spellcheck: 'false', 'aria-label': 'Home name' });
  nameInput.addEventListener('input', () => { snapshot('name'); doc.name = nameInput.value; touch({ inspector: sel.kind === 'home' }); });
  const status = h('div.status');
  const saveBtn = h('button.btn.primary', { onclick: save }, icon('check', 15, 2.4), 'Save & apply');
  const hint = h('div.hint', 'Tap to select · drag what is selected · pinch to zoom');
  const levelBar = h('div.levels', { role: 'tablist', 'aria-label': 'Floors' });
  // An empty floor says how to start it.
  const emptyCard = h('div.empty-card');
  const toastEl = h('div.toast');

  const sidebar = h('aside.side');
  const plan = sv('svg', { class: 'plan', tabindex: 0 });
  const inspector = h('div.inspector');
  const previewHost = h('div.preview');
  const previewToggle = h('button.chip', { onclick: () => { previewLights = !previewLights; schedulePreview(0); } });

  if (isPhone) buildPhoneLayout();
  else root.replaceChildren(h('div.editor',
    h('header.bar',
      h('div.bar-title', icon('home', 17), nameInput),
      h('div.bar-actions',
        h('button.btn', { title: 'Undo (⌘Z)', onclick: () => stepHistory(undo, redo) }, 'Undo'),
        h('button.btn', { title: 'Redo (⇧⌘Z)', onclick: () => stepHistory(redo, undo) }, 'Redo'),
        h('button.btn', { onclick: importPlan }, 'Import…'),
        h('button.btn', { onclick: exportPlan }, 'Export…'),
        saveBtn)),
    sidebar,
    h('main.canvas', plan, levelBar, emptyCard, addBar(), zoomBar()),
    h('aside.right', h('div.preview-wrap', previewHost, previewToggle), inspector),
    h('footer.foot', status),
    toastEl));

  /* ---------- history ---------- */

  let lastSnapshotKey = null;
  function snapshot(key = null) {
    if (key && key === lastSnapshotKey) return; // coalesce a drag or a burst of typing into one step
    lastSnapshotKey = key;
    undo.push(JSON.stringify(doc));
    if (undo.length > 100) undo.shift();
    redo.length = 0;
  }

  function stepHistory(from, to) {
    if (!from.length) return;
    to.push(JSON.stringify(doc));
    doc = JSON.parse(from.pop());
    lastSnapshotKey = null;
    checkLevel();
    if (sel.index != null && !doc[KEYS[sel.kind]]?.[sel.index]) sel = { kind: 'home' };
    if (sel.kind === 'level' && !levelList().some((l) => l.id === sel.id)) sel = { kind: 'home' };
    nameInput.value = doc.name || '';
    touch();
  }

  function touch({ inspector: redrawInspector = true } = {}) {
    dirty = true;
    renderSidebar();
    renderPlan();
    if (redrawInspector) renderInspector();
    validate();
    schedulePreview();
  }

  function select(next) {
    // Something on another floor (picked in the list or a scene's rules): that floor comes up.
    const item = next.index != null ? doc[KEYS[next.kind]]?.[next.index] : null;
    const on = item && levelOf(next.kind, item);
    if (on && on !== level) { level = on; view = null; world?.setLevel(level); }
    sel = next;
    lastSnapshotKey = null;
    renderSidebar();
    renderPlan();
    renderInspector();
    if (isPhone) phone.selected(next);
  }

  function toast(text, bad = false) {
    toastEl.textContent = text;
    toastEl.className = `toast show${bad ? ' bad' : ''}`;
    clearTimeout(toast.timer);
    toast.timer = setTimeout(() => { toastEl.className = 'toast'; }, 2600);
  }

  /* ---------- floors ---------- */

  const levelList = () => levelsOf(doc);
  const firstLevel = () => levelList()[0].id;
  const levelName = (id) => levelList().find((l) => l.id === id)?.name || id;
  const roomLevel = (id) => doc.rooms.find((r) => r.id === id)?.level ?? firstLevel();
  const levelRooms = (id = level) => doc.rooms.filter((r) => (r.level ?? firstLevel()) === id);
  // The floor an item is on; null for a scene, which is for the whole home.
  function levelOf(kind, item) {
    if (kind === 'light' || kind === 'ac') return roomLevel(item.room);
    if (kind === 'room' || kind === 'furniture' || kind === 'opening') return item.level ?? firstLevel();
    return null;
  }
  const here = (kind, item) => { const l = levelOf(kind, item); return l == null || l === level; };
  // New things on a home with floors say which one they are on.
  const stamp = (item) => (Array.isArray(doc.levels) && doc.levels.length ? { ...item, level } : item);
  // The floor right under the one being edited, drawn faintly to line things up with.
  function below(id = level) {
    const list = levelList();
    const i = list.findIndex((l) => l.id === id);
    return i > 0 ? list[i - 1] : null;
  }
  const outline = (rooms) => rooms.length && {
    minX: Math.min(...rooms.map((r) => r.rect[0])), minZ: Math.min(...rooms.map((r) => r.rect[1])),
    maxX: Math.max(...rooms.map((r) => r.rect[0] + r.rect[2])), maxZ: Math.max(...rooms.map((r) => r.rect[1] + r.rect[3])),
  };

  function checkLevel() {
    if (!levelList().some((l) => l.id === level)) level = firstLevel();
  }

  function setLevel(id) {
    if (id === level || !levelList().some((l) => l.id === id)) return;
    level = id;
    view = null;
    const item = sel.index != null ? doc[KEYS[sel.kind]]?.[sel.index] : null;
    if (item && !here(sel.kind, item)) sel = { kind: 'home' };
    if (sel.kind === 'level') sel = { kind: 'level', id };
    lastSnapshotKey = null;
    renderSidebar();
    renderPlan();
    renderInspector();
    world?.setLevel(level);
    haptic('tick');
  }

  // Before the floors change, everything says which one it is on (without "levels" in the
  // plan, or "level" on an item, it is on the first floor, and the first may be about to change).
  function pinLevels() {
    const first = firstLevel();
    for (const key of ['rooms', 'furniture', 'openings']) for (const item of doc[key]) item.level ??= first;
  }

  // Back to a home on one floor: the plan looks as if it never had floors.
  function unpinLevels() {
    delete doc.levels;
    for (const key of ['rooms', 'furniture', 'openings']) for (const item of doc[key]) delete item.level;
    level = firstLevel();
  }

  function addLevel(where = 'above') {
    snapshot();
    if (!Array.isArray(doc.levels) || !doc.levels.length) {
      const name = levelList()[0].name;
      doc.levels = [{ id: 'ground', name }];
      level = 'ground';
    }
    pinLevels();
    const ids = new Set(doc.levels.map((l) => l.id));
    let n = doc.levels.length + 1;
    while (ids.has(`floor${n}`)) n++;
    const id = `floor${n}`;
    const name = where === 'below' ? 'Basement' : LEVEL_NAMES[doc.levels.length] || `Floor ${doc.levels.length + 1}`;
    doc.levels.splice(where === 'below' ? 0 : doc.levels.length, 0, { id, name });
    level = id;
    view = null;
    sel = { kind: 'level', id };
    world?.dispose();
    world = null;
    touch();
    toast(`${name} added`);
  }

  function removeLevel(id) {
    if (levelList().length < 2) return;
    snapshot();
    pinLevels();
    const gone = new Set(levelRooms(id).map((r) => r.id));
    dropRooms(gone);
    doc.furniture = doc.furniture.filter((f) => f.level !== id);
    doc.openings = doc.openings.filter((o) => o.level !== id);
    const name = levelName(id);
    doc.levels = doc.levels.filter((l) => l.id !== id);
    if (doc.levels.length === 1) unpinLevels();
    checkLevel();
    sel = { kind: 'home' };
    view = null;
    touch();
    toast(`${name} removed · ${isPhone ? 'Undo' : '⌘Z'} brings it back`);
  }

  function moveLevel(id, step) {
    pinLevels();
    const list = doc.levels;
    const i = list.findIndex((l) => l.id === id);
    const j = i + step;
    if (i < 0 || j < 0 || j >= list.length) return;
    snapshot();
    [list[i], list[j]] = [list[j], list[i]];
    touch();
  }

  // An opening on a wall only one room of the floor has (an outside wall).
  function outside(o, rooms) {
    const mid = [(o.from[0] + o.to[0]) / 2, (o.from[1] + o.to[1]) / 2];
    const on = (r) => {
      const [x, z, w, d] = r.rect;
      const inX = mid[0] >= x - 1e-3 && mid[0] <= x + w + 1e-3;
      const inZ = mid[1] >= z - 1e-3 && mid[1] <= z + d + 1e-3;
      return inX && inZ && (Math.abs(mid[0] - x) < 1e-3 || Math.abs(mid[0] - x - w) < 1e-3
        || Math.abs(mid[1] - z) < 1e-3 || Math.abs(mid[1] - z - d) < 1e-3);
    };
    return rooms.filter(on).length < 2;
  }

  // The rooms of the floor below, copied up: the same walls, windows and inner doors.
  function copyRoomsFromBelow(id = level) {
    const from = below(id);
    if (!from) return;
    snapshot();
    pinLevels();
    const rooms = levelRooms(from.id);
    for (const r of rooms) {
      doc.rooms.push({ id: uniqueId(`${r.id}.${id}`.replace(/[^a-z0-9.]+/gi, '')), name: r.name, rect: [...r.rect], floor: r.floor, level: id });
    }
    for (const o of doc.openings.filter((x) => x.level === from.id)) {
      if (o.type === 'door' && outside(o, rooms)) continue; // the front door stays downstairs
      doc.openings.push({ ...structuredClone(o), level: id });
    }
    view = null;
    touch();
    toast(`${rooms.length} rooms copied from ${from.name}`);
  }

  // One room as big as the floor below (or the whole home), to divide up.
  function fillLevel(id = level) {
    snapshot();
    pinLevels();
    const b = outline(below(id) ? levelRooms(below(id).id) : doc.rooms) || { minX: 0, minZ: 0, maxX: 6, maxZ: 4 };
    doc.rooms.push({
      id: uniqueId('room'), name: 'New room', rect: [b.minX, b.minZ, fix(b.maxX - b.minX), fix(b.maxZ - b.minZ)], floor: 'oak',
      ...(Array.isArray(doc.levels) ? { level: id } : {}),
    });
    sel = { kind: 'room', index: doc.rooms.length - 1 };
    view = null;
    touch();
  }

  function renderLevels() {
    const list = levelList();
    levelBar.replaceChildren(
      ...list.map((l) => h(`button.level-tab${l.id === level ? '.active' : ''}`, {
        role: 'tab', 'aria-selected': String(l.id === level),
        title: l.id === level ? `${l.name} · click for its settings` : `Edit ${l.name}`,
        onclick: () => { if (l.id === level) select({ kind: 'level', id: l.id }); else setLevel(l.id); },
      }, l.name, h('span.n', levelRooms(l.id).length))),
      h('button.level-add', { title: 'Add a floor', 'aria-label': 'Add a floor', onclick: () => addLevel() }, icon('plus', 14, 2.4), isPhone ? null : 'Floor'));
    levelBar.querySelector('.active')?.scrollIntoView?.({ block: 'nearest', inline: 'nearest' });

    const empty = !levelRooms().length;
    emptyCard.hidden = !empty;
    if (empty) {
      const under = below();
      emptyCard.replaceChildren(h('b', `${levelName(level)} is empty`),
        h('p', under ? `Copy the rooms of ${under.name}, or start with one room as big as it and divide it up.` : 'Add a room to start.'),
        h('div.empty-actions',
          under ? h('button.btn.primary', { onclick: () => copyRoomsFromBelow() }, icon('copy', 14, 2.2), `Copy ${under.name}`) : null,
          h('button.btn', { onclick: () => fillLevel() }, icon('room', 14, 2.2), under ? 'One big room' : 'Add a room')));
    }
  }

  /* ---------- view: what part of the plan is on show ---------- */

  function bounds() {
    const b = outline(levelRooms()) || outline(below() ? levelRooms(below().id) : []) || outline(doc.rooms);
    return b || { minX: 0, minZ: 0, maxX: 6, maxZ: 4 };
  }

  // The floor fitted into the plan's box, clear of the bars over it.
  function fitBox() {
    const b = bounds();
    const rect = plan.getBoundingClientRect();
    const W = rect.width || 390;
    const H = rect.height || 600;
    // On a phone the sides stay clear of the system's back gesture, so the handles there can be grabbed.
    const pad = isPhone ? { top: 64, side: 34, bottom: 24 } : { top: 64, side: 56, bottom: 84 };
    const scale = Math.max(1, Math.min((W - pad.side * 2) / (b.maxX - b.minX), (H - pad.top - pad.bottom) / (b.maxZ - b.minZ)));
    const w = W / scale;
    const hh = H / scale;
    const midY = pad.top + (H - pad.top - pad.bottom) / 2;
    return { x: (b.minX + b.maxX) / 2 - w / 2, y: (b.minZ + b.maxZ) / 2 - midY / scale, w, h: hh };
  }

  const box = () => view || fitBox();

  function applyView() {
    if (view) {
      // The plan's box changed shape (a sheet came up, the window was resized): keep the middle and the zoom.
      const rect = plan.getBoundingClientRect();
      const hh = rect.width ? view.w * rect.height / rect.width : view.h;
      view = { ...view, y: view.y + (view.h - hh) / 2, h: hh };
    }
    const v = box();
    plan.setAttribute('viewBox', `${v.x} ${v.y} ${v.w} ${v.h}`);
  }
  new ResizeObserver(() => applyView()).observe(plan);

  // Zooms by `factor` (above 1 is closer) keeping the plan point under (cx, cy) where it is.
  function zoomAt(factor, cx, cy) {
    const rect = plan.getBoundingClientRect();
    const v = box();
    const fit = fitBox();
    const w = clamp(v.w / factor, 1.6, Math.max(fit.w * 3, 30));
    const hh = w * rect.height / rect.width;
    const fx = (cx - rect.left) / rect.width;
    const fy = (cy - rect.top) / rect.height;
    view = { x: v.x + fx * v.w - fx * w, y: v.y + fy * v.h - fy * hh, w, h: hh };
    applyView();
  }
  function zoomBy(factor) {
    const rect = plan.getBoundingClientRect();
    zoomAt(factor, rect.left + rect.width / 2, rect.top + rect.height / 2);
  }
  // Shows the whole floor again.
  function reveal() { view = null; applyView(); }

  // How many metres a few screen pixels are: snapping reaches as far.
  const pixels = (px) => px / (plan.getScreenCTM()?.a || 60);

  function zoomBar() {
    return h('div.zoom',
      h('button', { title: 'Zoom in (⌘+ or pinch)', 'aria-label': 'Zoom in', onclick: () => zoomBy(1.35) }, icon('zoomIn', 16, 2)),
      h('button', { title: 'Zoom out', 'aria-label': 'Zoom out', onclick: () => zoomBy(1 / 1.35) }, icon('zoomOut', 16, 2)),
      h('button', { title: 'Show the whole floor (⌘0)', 'aria-label': 'Show the whole floor', onclick: reveal }, icon('fit', 16, 2)));
  }

  // What can be added, for the bar under the plan (Mac) and the Add sheet (phone).
  function addable() {
    return [
      ['room', 'room', 'Room', () => add('room')],
      ['light', 'bulb', 'Lamp', () => add('light')],
      ['ac', 'ac', 'Air conditioner', () => add('ac')],
      ['door', 'opening', 'Door', () => add('opening', { type: 'door' })],
      ['window', 'window', 'Window', () => add('opening', { type: 'window' })],
      ['stairs', 'stairs', 'Stairs', () => add('furniture', { type: 'stairs' })],
      ['furniture', 'furniture', 'Furniture', () => add('furniture')],
    ];
  }

  function addBar() {
    return h('div.add-bar', addable().map(([key, name, label, run]) => h('button', {
      title: `Add ${label.toLowerCase()}`, 'data-add': key, onclick: () => { run(); },
    }, icon(name, 18, 1.9), h('span', key === 'ac' ? 'AC' : label))));
  }

  /* ---------- validation + preview ---------- */

  let valid = null;
  function validate() {
    try {
      valid = normalize(structuredClone(doc));
      const linked = [...doc.lights, ...doc.acs].filter(isLinked).length;
      status.className = 'status';
      const floors = levelList().length > 1 ? `${levelList().length} floors · ` : '';
      status.replaceChildren(h('span.ok', '●'), ` ${floors}${doc.rooms.length} rooms · ${doc.lights.length} lights · ${doc.acs.length} ACs · `,
        `${linked} linked to real devices`, dirty ? h('span.dirty', ' · unsaved changes') : '');
    } catch (e) {
      valid = null;
      status.className = 'status bad';
      status.textContent = `⚠ ${e.message}`;
    }
    saveBtn.disabled = !valid;
    if (isPhone) phone.refresh();
  }

  function previewStore(cfg) {
    const state = { lights: {}, acs: {} };
    for (const l of cfg.lights) state.lights[l.id] = { on: previewLights, brightness: 0.85, temp: 3200, color: l.color || null };
    for (const a of cfg.acs) state.acs[a.id] = { on: previewLights, mode: 'cool', fan: 'auto', swing: 'swing', sleep: false, target: 23 };
    return { state, on: () => () => {} };
  }

  let previewTimer = 0;
  function schedulePreview(delay = 350) {
    clearTimeout(previewTimer);
    previewTimer = setTimeout(buildPreview, delay);
  }

  function buildPreview() {
    previewToggle.replaceChildren(icon(previewLights ? 'bright' : 'moon', 14), previewLights ? 'Lights on' : 'Lights off');
    if (!valid) return;
    if (isPhone && !phone.show3D) { world?.dispose(); world = null; previewHost.replaceChildren(); return; }
    world?.dispose();
    world = null;
    const canvas = h('canvas');
    previewHost.replaceChildren(canvas);
    try {
      world = createWorld(canvas, valid, previewStore(valid), {
        level,
        onHover() {},
        onPick(t) {
          if (!t) return;
          const index = doc[KEYS[t.kind]].findIndex((x) => x.id === t.id);
          if (index >= 0) select({ kind: t.kind, index });
        },
      });
      world.setInsets(isPhone ? 20 : 6, isPhone ? 20 : 6);
      world.setRunning(true);
      const w = world;
      new ResizeObserver(() => { if (world === w) w.resize(); }).observe(canvas);
    } catch (e) {
      previewHost.replaceChildren(h('div.preview-error', String(e.message || e)));
    }
  }

  /* ---------- sidebar ---------- */

  function rowLabel(kind, item) {
    if (kind === 'room') return [item.name || item.id, `${fix(item.rect[2])} × ${fix(item.rect[3])} m`];
    if (kind === 'light') return [item.name || item.id, `${roomName(item.room)} · ${item.type}`];
    if (kind === 'ac') return [item.name || item.id, `${roomName(item.room)} · ${item.wall} wall`];
    if (kind === 'furniture') return [item.type, roomName(roomAt(item.pos)?.id) || '—'];
    if (kind === 'opening' && !item.to) return [item.type || 'door', ''];
    if (kind === 'opening') return [item.type || 'door', `${fix(Math.hypot(item.to[0] - item.from[0], item.to[1] - item.from[1]))} m`];
    return [item.name || item.id, `${Object.keys(item.lights || {}).length} rules`];
  }

  const roomName = (id) => doc.rooms.find((r) => r.id === id)?.name || id || '';
  const roomAt = ([x, z]) => levelRooms().find((r) => x >= r.rect[0] && x <= r.rect[0] + r.rect[2] && z >= r.rect[1] && z <= r.rect[1] + r.rect[3]);

  function renderSidebar() {
    const nodes = [h(`button.row.home-row${sel.kind === 'home' ? '.active' : ''}`, { onclick: () => select({ kind: 'home' }) },
      icon('home', 15), h('span.row-name', 'Home settings')),
    links.sidebarRow(sel.kind === 'connections' || sel.kind === 'service', () => select({ kind: 'connections' }))];
    const list = levelList();
    nodes.push(h('div.group', h('span', 'Floors'), h('span.n', list.length),
      h('button.add', { title: 'Add a floor', 'aria-label': 'Add a floor', onclick: () => addLevel() }, icon('plus', 14, 2.4))));
    for (const l of [...list].reverse()) {
      const active = sel.kind === 'level' && sel.id === l.id;
      nodes.push(h(`div.row.level-row${active ? '.active' : ''}${l.id === level ? '.current' : ''}`, {
        role: 'button', tabindex: 0, onclick: () => { setLevel(l.id); select({ kind: 'level', id: l.id }); },
      }, icon('layers', 14, 2), h('span.row-name', l.name), h('span.row-sub', `${levelRooms(l.id).length} rooms`),
      list.length > 1 ? h('button.del', { title: 'Remove this floor', 'aria-label': `Remove ${l.name}`, onclick: (e) => { e.stopPropagation(); removeLevel(l.id); } }, icon('close', 13, 2.4)) : null));
    }
    for (const kind of Object.keys(KEYS)) {
      const items = doc[KEYS[kind]];
      const shown = items.filter((item) => here(kind, item)).length;
      nodes.push(h('div.group',
        h('span', `${TITLES[kind]}`), h('span.n', shown),
        h('button.add', { title: `Add to ${TITLES[kind].toLowerCase()}`, 'aria-label': `Add ${kind}`, onclick: () => add(kind) }, icon('plus', 14, 2.4))));
      items.forEach((item, index) => {
        if (!here(kind, item)) return;
        const [name, sub] = rowLabel(kind, item);
        const active = sel.kind === kind && sel.index === index;
        nodes.push(h(`div.row${active ? '.active' : ''}`, { role: 'button', tabindex: 0, onclick: () => select({ kind, index }) },
          h('span.row-name', name),
          isLinked(item) ? h('span.linked', { title: 'Linked to a real device' }, icon('link', 12, 2.2)) : null,
          h('span.row-sub', sub),
          h('button.del', { title: 'Remove', 'aria-label': `Remove ${name}`, onclick: (e) => { e.stopPropagation(); remove(kind, index); } }, icon('close', 13, 2.4))));
      });
    }
    const top = sidebar.scrollTop;
    sidebar.replaceChildren(...nodes);
    sidebar.scrollTop = top;
  }

  function uniqueId(base) {
    const ids = new Set([...doc.rooms, ...doc.lights, ...doc.acs, ...doc.scenes].map((x) => x.id));
    if (!ids.has(base)) return base;
    for (let i = 2; ; i++) if (!ids.has(`${base}${i}`)) return `${base}${i}`;
  }

  function add(kind, { type } = {}) {
    // On an empty floor the first room is as big as the floor below, ready to be divided.
    if (kind === 'room' && !levelRooms().length && below()) { fillLevel(); return; }
    snapshot();
    const rooms = levelRooms();
    const picked = sel.index != null ? doc[KEYS[sel.kind]]?.[sel.index] : null;
    const room = (sel.kind === 'room' && picked) || (picked?.room && rooms.find((r) => r.id === picked.room)) || rooms[0];
    const center = room ? [fix(room.rect[0] + room.rect[2] / 2), fix(room.rect[1] + room.rect[3] / 2)] : [1, 1];
    const list = doc[KEYS[kind]];
    if (kind === 'room') {
      const maxX = Math.max(0, ...rooms.map((r) => r.rect[0] + r.rect[2]));
      const minZ = Math.min(...rooms.map((r) => r.rect[1]), 0);
      list.push(stamp({ id: uniqueId('room'), name: 'New room', rect: [fix(maxX), fix(rooms.length ? minZ : 0), 3, 3], floor: 'oak' }));
    } else if (kind === 'light') {
      if (!room) return toast('Add a room first', true);
      list.push({ id: uniqueId(`${room.id}.light`), name: 'New light', room: room.id, type: 'ceiling', pos: freeSpot(room, center), capabilities: [] });
    } else if (kind === 'ac') {
      if (!room) return toast('Add a room first', true);
      list.push({ id: uniqueId(`${room.id}.ac`), name: `${room.name} AC`, room: room.id, wall: 'north', pos: [center[0], room.rect[1]], y: 2.2 });
    } else if (kind === 'furniture') {
      list.push(stamp(type === 'stairs' ? { type, pos: center, rot: 0, width: 1, depth: 2.8 } : { type: type || 'sofa', pos: center, rot: 0 }));
    } else if (kind === 'opening') {
      if (!room) return toast('Add a room first', true);
      // A door on the near (south) wall; a window on the far (north) one, where the 3D model shows it.
      const half = type === 'window' ? 0.6 : 0.45;
      const z = type === 'window' ? room.rect[1] : room.rect[1] + room.rect[3];
      list.push(stamp({ type: type || 'door', from: [fix(center[0] - half), fix(z)], to: [fix(center[0] + half), fix(z)] }));
    } else if (kind === 'scene') {
      list.push({ id: uniqueId('scene'), name: 'New scene', icon: 'sparkles', lights: { '*': { on: false } } });
    }
    sel = { kind, index: list.length - 1 };
    if (view && !inView(list[list.length - 1])) view = null;
    touch();
    if (isPhone) phone.selected(sel);
  }

  // Whether an item's middle is in the part of the plan on show.
  function inView(item) {
    const p = item.pos || item.from || (item.rect && [item.rect[0] + item.rect[2] / 2, item.rect[1] + item.rect[3] / 2]);
    if (!p || !view) return true;
    return p[0] > view.x && p[0] < view.x + view.w && p[1] > view.y && p[1] < view.y + view.h;
  }

  // A copy of what is selected, beside it. A copied lamp or AC is not linked to the same device.
  function duplicate() {
    const kind = sel.kind;
    const item = sel.index != null ? doc[KEYS[kind]]?.[sel.index] : null;
    if (!item) return;
    snapshot();
    const copy = structuredClone(item);
    if (kind === 'room') {
      copy.id = uniqueId(item.id);
      copy.name = `${item.name || item.id} 2`;
      copy.rect[0] = fix(item.rect[0] + item.rect[2]);
    } else if (kind === 'light' || kind === 'ac') {
      copy.id = uniqueId(item.id);
      for (const key of ['tuya', 'link', 'sensor']) delete copy[key];
      if (kind === 'ac') {
        const along = item.wall === 'north' || item.wall === 'south' ? 0 : 1;
        copy.pos[along] = fix(copy.pos[along] + 1.1);
      } else copy.pos = [fix(item.pos[0] + 0.5), fix(item.pos[1])];
    } else if (kind === 'furniture') {
      copy.pos = [fix(item.pos[0] + 0.4), fix(item.pos[1] + 0.4)];
    } else if (kind === 'opening') {
      const alongX = item.from[1] === item.to[1];
      const len = Math.abs(alongX ? item.to[0] - item.from[0] : item.to[1] - item.from[1]) + 0.3;
      const k = alongX ? 0 : 1;
      copy.from[k] = fix(copy.from[k] + len);
      copy.to[k] = fix(copy.to[k] + len);
    } else if (kind === 'scene') {
      copy.id = uniqueId(item.id);
      copy.name = `${item.name || item.id} copy`;
    }
    doc[KEYS[kind]].push(copy);
    sel = { kind, index: doc[KEYS[kind]].length - 1 };
    touch();
    toast('Duplicated');
  }

  // Turns furniture or a lamp a quarter (or, with `step`, a little).
  function rotate(step = 90) {
    const item = sel.index != null ? doc[KEYS[sel.kind]]?.[sel.index] : null;
    if (!item || !['furniture', 'light'].includes(sel.kind)) return;
    snapshot(`rotate${sel.kind}${sel.index}`);
    item.rot = (((item.rot || 0) + step) % 360 + 540) % 360 - 180;
    touch();
  }

  // Splits a room across its longer side, with a door between the two halves.
  function splitRoom(index) {
    const room = doc.rooms[index];
    if (!room) return;
    const [x, z, w, d] = room.rect;
    if (Math.max(w, d) < MIN_ROOM * 2) { toast('Too small to split', true); return; }
    snapshot();
    const across = w >= d;
    const cut = round((across ? w : d) / 2, 0.05);
    const next = structuredClone(room);
    next.id = uniqueId(room.id);
    next.name = `${room.name || room.id} 2`;
    if (across) {
      room.rect = [x, z, fix(cut), d];
      next.rect = [fix(x + cut), z, fix(w - cut), d];
    } else {
      room.rect = [x, z, w, fix(cut)];
      next.rect = [x, fix(z + cut), w, fix(d - cut)];
    }
    doc.rooms.push(next);
    const inNext = ([px, pz]) => px >= next.rect[0] && px <= next.rect[0] + next.rect[2] && pz >= next.rect[1] && pz <= next.rect[1] + next.rect[3];
    for (const dev of [...doc.lights, ...doc.acs]) if (dev.room === room.id && inNext(dev.pos)) dev.room = next.id;
    const mid = across ? [fix(x + cut), fix(z + d / 2)] : [fix(x + w / 2), fix(z + cut)];
    const door = across ? { from: [mid[0], fix(mid[1] - 0.45)], to: [mid[0], fix(mid[1] + 0.45)] } : { from: [fix(mid[0] - 0.45), mid[1]], to: [fix(mid[0] + 0.45), mid[1]] };
    doc.openings.push(stamp({ type: 'door', ...door, ...(room.level ? { level: room.level } : {}) }));
    sel = { kind: 'room', index: doc.rooms.length - 1 };
    touch();
    toast('Split in two, with a door between');
  }

  // Moves a room, and what stands in it, to another floor.
  function moveRoomToLevel(index, id) {
    const room = doc.rooms[index];
    if (!room || id === (room.level ?? firstLevel())) return;
    pinLevels();
    const [x, z, w, d] = room.rect;
    const inside = ([px, pz]) => px >= x - 1e-6 && px <= x + w + 1e-6 && pz >= z - 1e-6 && pz <= z + d + 1e-6;
    for (const f of doc.furniture) if (f.level === room.level && Array.isArray(f.pos) && inside(f.pos)) f.level = id;
    for (const o of doc.openings) if (o.level === room.level && inside(o.from) && inside(o.to)) o.level = id;
    room.level = id;
    level = id;
    view = null;
    world?.setLevel(id);
  }

  // The middle of the room, or the nearest place around it no other lamp stands on.
  function freeSpot(room, center) {
    const [x, z, w, d] = room.rect;
    const taken = (p) => doc.lights.some((l) => here('light', l) && Math.hypot(l.pos[0] - p[0], l.pos[1] - p[1]) < 0.45);
    for (let ring = 0; ring < 4; ring++) {
      for (let k = 0; k < Math.max(1, ring * 6); k++) {
        const a = (k / Math.max(1, ring * 6)) * Math.PI * 2;
        const p = [fix(round(center[0] + Math.cos(a) * ring * 0.6)), fix(round(center[1] + Math.sin(a) * ring * 0.6))];
        if (p[0] > x + 0.2 && p[0] < x + w - 0.2 && p[1] > z + 0.2 && p[1] < z + d - 0.2 && !taken(p)) return p;
      }
    }
    return center;
  }

  function remove(kind, index) {
    snapshot();
    const [gone] = doc[KEYS[kind]].splice(index, 1);
    if (kind === 'room') dropRooms(new Set([gone.id]));
    else if (kind === 'light' || kind === 'ac') forgetDevices();
    sel = { kind: 'home' };
    touch();
  }

  // Devices cannot outlive their room.
  function dropRooms(ids) {
    doc.rooms = doc.rooms.filter((r) => !ids.has(r.id));
    doc.lights = doc.lights.filter((l) => !ids.has(l.room));
    doc.acs = doc.acs.filter((a) => !ids.has(a.room));
    forgetDevices();
  }

  // Scenes let go of devices that are gone.
  function forgetDevices() {
    const ids = new Set([...doc.lights, ...doc.acs].map((d) => d.id));
    for (const sc of doc.scenes) {
      for (const map of [sc.lights, sc.acs]) for (const id of Object.keys(map || {})) if (id !== '*' && !ids.has(id)) delete map[id];
    }
  }

  /* ---------- plan (SVG) ---------- */

  const isSel = (kind, index) => sel.kind === kind && sel.index === index;
  const svText = (attrs, value) => sv('text', attrs, document.createTextNode(value));

  // A flight of stairs on the plan: its treads, and an arrow up from where you step on.
  function stairsMarks(w, d, cls) {
    const steps = Math.max(3, Math.round(d / 0.28));
    const marks = [];
    for (let i = 1; i < steps; i++) {
      const y = -d / 2 + (d * i) / steps;
      marks.push(sv('line', { x1: -w / 2, x2: w / 2, y1: y, y2: y, class: `${cls}-step` }));
    }
    marks.push(sv('path', { d: `M0 ${d / 2 - 0.25}V${-d / 2 + 0.3}M-0.16 ${-d / 2 + 0.5}L0 ${-d / 2 + 0.3}L0.16 ${-d / 2 + 0.5}`, class: `${cls}-arrow` }));
    return marks;
  }

  function renderPlan() {
    applyView();
    renderLevels();
    // Fingers are bigger than a mouse pointer: on a phone small things get a wider target.
    const big = isPhone;
    const kids = [
      sv('defs', {}, sv('pattern', { id: 'grid', width: 1, height: 1, patternUnits: 'userSpaceOnUse' },
        sv('path', { d: 'M1 0H0V1', fill: 'none', stroke: 'rgba(255,255,255,0.07)', 'stroke-width': 0.015 }),
        sv('path', { d: 'M0.5 0V1M0 0.5H1', fill: 'none', stroke: 'rgba(255,255,255,0.03)', 'stroke-width': 0.01 }))),
      sv('rect', { x: -500, y: -500, width: 1000, height: 1000, fill: 'url(#grid)', 'data-kind': 'none' }),
    ];

    // The floor below, faintly, to line the walls (and the stairs coming up) up with.
    const under = below();
    const ghostStairs = sv('g', { class: 'p-ghost' });
    if (under) {
      const ghost = sv('g', { class: 'p-ghost' });
      for (const r of levelRooms(under.id)) {
        const [x, z, w, d] = r.rect;
        ghost.append(sv('rect', { x, y: z, width: w, height: d }), svText({ x: x + w / 2, y: z + d / 2, class: 'p-ghost-label' }, r.name || r.id));
      }
      kids.push(ghost);
      // The stairs coming up from below show over this floor's rooms: that is where the landing goes.
      for (const f of doc.furniture) {
        if (f.type !== 'stairs' || (f.level ?? firstLevel()) !== under.id || !Array.isArray(f.pos)) continue;
        const [w, d] = footprint(f);
        ghostStairs.append(sv('g', { transform: `translate(${f.pos[0]} ${f.pos[1]}) rotate(${-(f.rot || 0)})` },
          sv('rect', { x: -w / 2, y: -d / 2, width: w, height: d, class: 'p-ghost-stairs' }), ...stairsMarks(w, d, 'p-ghost')));
      }
    }

    doc.rooms.forEach((r, i) => {
      if (!here('room', r)) return;
      const [x, z, w, d] = r.rect;
      kids.push(sv('g', { class: `p-room${isSel('room', i) ? ' sel' : ''}`, 'data-kind': 'room', 'data-index': i },
        sv('rect', { x, y: z, width: w, height: d, fill: FLOOR_FILL[r.floor] || FLOOR_FILL.oak }),
        svText({ x: x + w / 2, y: z + d / 2 - 0.02, class: 'p-label' }, r.name || r.id),
        svText({ x: x + w / 2, y: z + d / 2 + 0.3, class: 'p-dim' }, `${fix(w)} × ${fix(d)}`)));
    });

    kids.push(ghostStairs);

    doc.furniture.forEach((f, i) => {
      if (!Array.isArray(f.pos) || !here('furniture', f)) return;
      const [w, d] = footprint(f);
      const stairs = f.type === 'stairs';
      kids.push(sv('g', {
        class: `p-furn${stairs ? ' stairs' : ''}${isSel('furniture', i) ? ' sel' : ''}`, 'data-kind': 'furniture', 'data-index': i,
        transform: `translate(${f.pos[0]} ${f.pos[1]}) rotate(${-(f.rot || 0)})`,
      },
        sv('rect', { x: -w / 2, y: -d / 2, width: w, height: d, rx: stairs ? 0.02 : 0.06 }),
        ...(stairs ? stairsMarks(w, d, 'p-stairs')
          // a tick marks the front of the piece
          : [sv('path', { d: `M${-w / 4} ${d / 2}H${w / 4}`, class: 'front' })])));
    });

    doc.openings.forEach((o, i) => {
      if (!here('opening', o)) return;
      if (big) kids.push(sv('line', { class: 'p-hit', 'data-kind': 'opening', 'data-index': i, x1: o.from[0], y1: o.from[1], x2: o.to[0], y2: o.to[1] }));
      kids.push(sv('line', {
        class: `p-open ${o.type || 'door'}${isSel('opening', i) ? ' sel' : ''}`, 'data-kind': 'opening', 'data-index': i,
        x1: o.from[0], y1: o.from[1], x2: o.to[0], y2: o.to[1],
      }));
    });

    doc.acs.forEach((a, i) => {
      if (!here('ac', a)) return;
      const rot = { north: 0, east: 90, south: 180, west: 270 }[a.wall] || 0;
      kids.push(sv('g', {
        class: `p-ac${isSel('ac', i) ? ' sel' : ''}`, 'data-kind': 'ac', 'data-index': i,
        transform: `translate(${a.pos[0]} ${a.pos[1]}) rotate(${rot})`,
      }, big ? sv('rect', { x: -0.62, y: -0.12, width: 1.24, height: 0.74, class: 'hit' }) : null,
        sv('rect', { x: -0.47, y: 0.08, width: 0.94, height: 0.24, rx: 0.07 }),
        sv('path', { d: 'M-0.3 0.42v0.22M0 0.42v0.3M0.3 0.42v0.22', class: 'flow' })));
    });

    doc.lights.forEach((l, i) => {
      if (!here('light', l)) return;
      const g = sv('g', {
        class: `p-light ${l.type}${isSel('light', i) ? ' sel' : ''}${isLinked(l) ? ' linked' : ''}`, 'data-kind': 'light', 'data-index': i,
        transform: `translate(${l.pos[0]} ${l.pos[1]}) rotate(${-(l.rot || 0)})`,
      });
      if (big) g.append(sv('circle', { r: 0.58, class: 'hit' }));
      if (l.type === 'strip') {
        const len = l.length || 1;
        g.append(sv('rect', { x: -len / 2, y: -0.07, width: len, height: 0.14, rx: 0.07 }));
      } else {
        g.append(sv('circle', { r: 0.34, class: 'halo' }), sv('circle', { r: l.type === 'table' ? 0.13 : 0.19 }));
      }
      kids.push(g);
    });

    // Handles of what is selected, sized in screen pixels so they stay easy to grab at any zoom.
    const r = pixels(big ? 9 : 5.5);
    const reach = pixels(big ? 22 : 9);
    const room = sel.kind === 'room' && doc.rooms[sel.index];
    if (room && here('room', room)) {
      const [x, z, w, d] = room.rect;
      for (const [name, [fx, fz]] of Object.entries(HANDLES)) {
        const cx = x + w * fx;
        const cz = z + d * fz;
        const attrs = { 'data-kind': 'resize', 'data-index': sel.index, 'data-handle': name };
        kids.push(sv('circle', { cx, cy: cz, r: reach, class: `hit grab ${name}`, ...attrs }),
          sv('circle', { cx, cy: cz, r: name.length === 2 ? r : r * 0.8, class: `p-handle ${name}`, ...attrs }));
      }
    }
    const open = sel.kind === 'opening' && doc.openings[sel.index];
    if (open && here('opening', open)) {
      const alongX = open.from[1] === open.to[1];
      for (const end of ['from', 'to']) {
        const [cx, cz] = open[end];
        const attrs = { 'data-kind': 'oend', 'data-index': sel.index, 'data-handle': end };
        kids.push(sv('circle', { cx, cy: cz, r: reach, class: `hit grab ${alongX ? 'e' : 's'}`, ...attrs }),
          sv('circle', { cx, cy: cz, r: r * 0.85, class: `p-handle ${alongX ? 'e' : 's'}`, ...attrs }));
      }
    }

    // Lines something being dragged has snapped to.
    for (const g of drag?.guides || []) {
      kids.push(g.axis === 'x'
        ? sv('line', { x1: g.c, x2: g.c, y1: -500, y2: 500, class: 'p-guide' })
        : sv('line', { x1: -500, x2: 500, y1: g.c, y2: g.c, class: 'p-guide' }));
    }
    plan.replaceChildren(...kids);
  }

  function planPoint(ev) {
    const pt = plan.createSVGPoint();
    pt.x = ev.clientX;
    pt.y = ev.clientY;
    const p = pt.matrixTransform(plan.getScreenCTM().inverse());
    return [p.x, p.y];
  }

  // Puts an AC on the nearest wall of the room under (or nearest to) the pointer.
  function snapAC(ac, [x, z]) {
    const room = roomAt([x, z]) || doc.rooms.find((r) => r.id === ac.room);
    if (!room) return;
    const [rx, rz, rw, rd] = room.rect;
    const options = [
      ['north', Math.abs(z - rz)], ['south', Math.abs(z - (rz + rd))],
      ['west', Math.abs(x - rx)], ['east', Math.abs(x - (rx + rw))],
    ].sort((p, q) => p[1] - q[1]);
    const wall = options[0][0];
    ac.room = room.id;
    ac.wall = wall;
    const cx = fix(clamp(round(x), rx + 0.6, rx + rw - 0.6));
    const cz = fix(clamp(round(z), rz + 0.6, rz + rd - 0.6));
    ac.pos = wall === 'north' ? [cx, rz] : wall === 'south' ? [cx, fix(rz + rd)] : wall === 'west' ? [rx, cz] : [fix(rx + rw), cz];
  }

  // Every room edge on this floor: a wall running along `axis` at `c`, from `a` to `b`.
  function walls() {
    const out = [];
    for (const r of levelRooms()) {
      const [x, z, w, d] = r.rect;
      out.push({ axis: 'x', c: z, a: x, b: x + w }, { axis: 'x', c: z + d, a: x, b: x + w },
        { axis: 'z', c: x, a: z, b: z + d }, { axis: 'z', c: x + w, a: z, b: z + d });
    }
    return out;
  }

  // Lays a door or a window of length `len` on the wall nearest to the point, centred there.
  function placeOpening(o, [px, pz], len) {
    let best = null;
    for (const wall of walls()) {
      if (wall.b - wall.a < len - 1e-6) continue;
      const along = wall.axis === 'x' ? px : pz;
      const across = wall.axis === 'x' ? pz : px;
      const t = clamp(along, wall.a + len / 2, wall.b - len / 2);
      const dist = Math.hypot(along - t, across - wall.c);
      if (!best || dist < best.dist) best = { wall, t, dist };
    }
    if (!best) return;
    const { wall } = best;
    const t = clamp(round(best.t), wall.a + len / 2, wall.b - len / 2);
    const [a, b] = [fix(t - len / 2), fix(t + len / 2)];
    const c = fix(wall.c);
    if (wall.axis === 'x') { o.from = [a, c]; o.to = [b, c]; } else { o.from = [c, a]; o.to = [c, b]; }
  }

  // The room edges (on this floor, and the one under it) a moving edge can snap to.
  function edgeLines(skip) {
    const xs = [];
    const zs = [];
    const rooms = [...levelRooms(), ...(below() ? levelRooms(below().id) : [])];
    for (const r of rooms) {
      if (r === skip) continue;
      xs.push(r.rect[0], r.rect[0] + r.rect[2]);
      zs.push(r.rect[1], r.rect[1] + r.rect[3]);
    }
    return { xs, zs };
  }

  // The nearest line to any of `values` within reach: how far to move to sit on it, and where it is.
  function snapTo(values, lines) {
    let best = null;
    const reach = pixels(9);
    for (const v of values) for (const c of lines) {
      const d = c - v;
      if (Math.abs(d) <= reach && (!best || Math.abs(d) < Math.abs(best.d))) best = { d, c };
    }
    return best;
  }

  let drag = null;
  let pan = null; // dragging the plan itself around (Mac)
  plan.addEventListener('pointerdown', (ev) => {
    if (isPhone) return;
    plan.focus({ preventScroll: true });
    const el = ev.target.closest('[data-kind]');
    const kind = el?.dataset.kind;
    plan.setPointerCapture(ev.pointerId);
    // The empty plan, the middle button or the space bar held: the plan moves.
    if (!kind || kind === 'none' || ev.button === 1 || spaceHeld) {
      pan = { x: ev.clientX, y: ev.clientY, v0: box(), moved: false, empty: !kind || kind === 'none' };
      plan.classList.add('panning');
      return;
    }
    startDrag(kind, Number(el.dataset.index), ev, el.dataset.handle);
  });

  // Picks up an item (or a handle of one) under the pointer.
  function startDrag(kind, index, ev, handle) {
    const start = planPoint(ev);
    if (kind === 'resize') {
      drag = { kind, index, start, handle, rect: [...doc.rooms[index].rect] };
      return;
    }
    if (kind === 'oend') {
      const o = doc.openings[index];
      drag = { kind, index, start, handle, from: [...o.from], to: [...o.to] };
      return;
    }
    if (!isSel(kind, index)) select({ kind, index });
    const item = doc[KEYS[kind]][index];
    drag = { kind, index, start, moved: false };
    if (kind === 'room') {
      const [x, z, w, d] = item.rect;
      const inside = ([px, pz]) => px >= x - 1e-6 && px <= x + w + 1e-6 && pz >= z - 1e-6 && pz <= z + d + 1e-6;
      drag.rect = [...item.rect];
      // Everything standing in the room travels with it.
      drag.riders = [
        ...doc.lights.filter((l) => l.room === item.id).map((o) => ({ o, pos: [...o.pos] })),
        ...doc.acs.filter((a) => a.room === item.id).map((o) => ({ o, pos: [...o.pos] })),
        ...doc.furniture.filter((f) => Array.isArray(f.pos) && here('furniture', f) && inside(f.pos)).map((o) => ({ o, pos: [...o.pos] })),
      ];
      drag.openings = doc.openings.filter((o) => here('opening', o) && inside(o.from) && inside(o.to)).map((o) => ({ o, from: [...o.from], to: [...o.to] }));
      drag.lines = edgeLines(item);
    } else if (kind === 'opening') {
      drag.from = [...item.from];
      drag.to = [...item.to];
    } else {
      drag.pos = [...item.pos];
    }
  }

  plan.addEventListener('pointermove', (ev) => {
    if (isPhone) return;
    if (pan) {
      const dx = ev.clientX - pan.x;
      const dy = ev.clientY - pan.y;
      if (!pan.moved && Math.hypot(dx, dy) < 4) return;
      pan.moved = true;
      const rect = plan.getBoundingClientRect();
      view = { ...pan.v0, x: pan.v0.x - dx * pan.v0.w / rect.width, y: pan.v0.y - dy * pan.v0.h / rect.height };
      applyView();
      return;
    }
    moveDrag(ev);
  });

  function moveDrag(ev) {
    if (!drag) return;
    const [px, pz] = planPoint(ev);
    const dx = round(px - drag.start[0]);
    const dz = round(pz - drag.start[1]);
    if (!drag.moved && !dx && !dz) return;
    if (!drag.moved) { drag.moved = true; snapshot(); haptic('tick'); }
    const free = ev.altKey; // ⌥ held: no snapping to other rooms
    drag.guides = [];

    if (drag.kind === 'resize') {
      const item = doc.rooms[drag.index];
      const [x, z, w, d] = drag.rect;
      const lines = edgeLines(item);
      let [x0, z0, x1, z1] = [x, z, x + w, z + d];
      const hd = drag.handle;
      const edge = (v, list, axis) => {
        const s = !free && snapTo([v], list);
        if (s) { drag.guides.push({ axis, c: s.c }); return s.c; }
        return round(v);
      };
      if (hd.includes('w')) x0 = Math.min(edge(x + px - drag.start[0], lines.xs, 'x'), x1 - MIN_ROOM);
      if (hd.includes('e')) x1 = Math.max(edge(x + w + px - drag.start[0], lines.xs, 'x'), x0 + MIN_ROOM);
      if (hd.includes('n')) z0 = Math.min(edge(z + pz - drag.start[1], lines.zs, 'z'), z1 - MIN_ROOM);
      if (hd.includes('s')) z1 = Math.max(edge(z + d + pz - drag.start[1], lines.zs, 'z'), z0 + MIN_ROOM);
      item.rect = [fix(x0), fix(z0), fix(x1 - x0), fix(z1 - z0)];
    } else if (drag.kind === 'oend') {
      const o = doc.openings[drag.index];
      const alongX = drag.from[1] === drag.to[1];
      const k = alongX ? 0 : 1;
      const other = drag.handle === 'from' ? drag.to : drag.from;
      const moved = round(drag[drag.handle][k] + (k ? pz - drag.start[1] : px - drag.start[0]));
      const sign = Math.sign(drag[drag.handle][k] - other[k]) || 1;
      const end = [...drag[drag.handle]];
      end[k] = fix(sign > 0 ? Math.max(moved, other[k] + 0.4) : Math.min(moved, other[k] - 0.4));
      o[drag.handle] = end;
    } else if (drag.kind === 'room') {
      const item = doc.rooms[drag.index];
      let mx = round(px - drag.start[0]);
      let mz = round(pz - drag.start[1]);
      const [x, z, w, d] = drag.rect;
      if (!free) {
        const sx = snapTo([x + mx, x + w + mx], drag.lines.xs);
        const sz = snapTo([z + mz, z + d + mz], drag.lines.zs);
        if (sx) { mx = fix(mx + sx.d); drag.guides.push({ axis: 'x', c: sx.c }); }
        if (sz) { mz = fix(mz + sz.d); drag.guides.push({ axis: 'z', c: sz.c }); }
      }
      item.rect[0] = fix(x + mx);
      item.rect[1] = fix(z + mz);
      for (const r of drag.riders) r.o.pos = [fix(r.pos[0] + mx), fix(r.pos[1] + mz)];
      for (const r of drag.openings) {
        r.o.from = [fix(r.from[0] + mx), fix(r.from[1] + mz)];
        r.o.to = [fix(r.to[0] + mx), fix(r.to[1] + mz)];
      }
    } else if (drag.kind === 'opening') {
      const item = doc.openings[drag.index];
      const len = Math.hypot(drag.to[0] - drag.from[0], drag.to[1] - drag.from[1]);
      const mid = [(drag.from[0] + drag.to[0]) / 2 + px - drag.start[0], (drag.from[1] + drag.to[1]) / 2 + pz - drag.start[1]];
      if (free) {
        item.from = [fix(drag.from[0] + dx), fix(drag.from[1] + dz)];
        item.to = [fix(drag.to[0] + dx), fix(drag.to[1] + dz)];
      } else placeOpening(item, mid, len); // doors and windows slide along the walls, and jump to the nearest one
    } else if (drag.kind === 'ac') {
      snapAC(doc.acs[drag.index], [px, pz]);
    } else {
      const item = doc[KEYS[drag.kind]][drag.index];
      item.pos = [fix(drag.pos[0] + dx), fix(drag.pos[1] + dz)];
      if (drag.kind === 'light') {
        const room = roomAt(item.pos);
        if (room) item.room = room.id;
      }
    }
    touch();
  }

  const endDrag = () => {
    const guides = drag?.guides?.length;
    drag = null;
    lastSnapshotKey = null;
    if (guides) renderPlan();
  };
  const endPointer = (ev) => {
    if (isPhone) return;
    if (pan) {
      if (!pan.moved && pan.empty && ev.type === 'pointerup') select({ kind: 'home' });
      pan = null;
      plan.classList.remove('panning');
    }
    endDrag();
  };
  plan.addEventListener('pointerup', endPointer);
  plan.addEventListener('pointercancel', endPointer);

  // Two fingers on a trackpad scroll the plan; a pinch (or ⌘ / Ctrl and the wheel) zooms.
  plan.addEventListener('wheel', (ev) => {
    ev.preventDefault();
    if (ev.ctrlKey || ev.metaKey) {
      zoomAt(Math.exp(-ev.deltaY * (ev.deltaMode === 1 ? 0.05 : 0.0075)), ev.clientX, ev.clientY);
      return;
    }
    const rect = plan.getBoundingClientRect();
    const v = box();
    const k = ev.deltaMode === 1 ? 16 : 1;
    view = { ...v, x: v.x + ev.deltaX * k * v.w / rect.width, y: v.y + ev.deltaY * k * v.h / rect.height };
    applyView();
  }, { passive: false });
  let spaceHeld = false;
  window.addEventListener('keyup', (ev) => { if (ev.code === 'Space') { spaceHeld = false; plan.classList.remove('can-pan'); } });

  /* ---------- inspector ---------- */

  // A labelled input bound to a getter/setter; edits redraw everything except the form itself.
  function bind(label, input, { get, set, parse = (v) => v, event = 'input' }) {
    const v = get();
    if (input.type === 'checkbox') input.checked = Boolean(v);
    else input.value = v ?? '';
    input.addEventListener(event, () => {
      const raw = input.type === 'checkbox' ? input.checked : input.value;
      const next = parse(raw);
      if (next === undefined) return;
      snapshot(label + sel.kind + sel.index);
      set(next);
      // Pickers and checkboxes can change which fields exist; typing must keep its focus.
      touch({ inspector: event === 'change' });
    });
    return h('label.field', h('span', label), input);
  }

  const number = (step = 0.05) => h('input', { type: 'number', step, inputmode: 'decimal' });
  const parseNum = (v) => (v === '' || Number.isNaN(Number(v)) ? undefined : Number(v));
  const text = () => h('input', { type: 'text', spellcheck: 'false' });
  const choice = (options) => h('select', options.map((o) => (Array.isArray(o) ? h('option', { value: o[0] }, o[1]) : h('option', { value: o }, o))));

  const prop = (obj, key, fallback) => ({ get: () => obj[key] ?? fallback, set: (v) => { obj[key] = v; } });
  const at = (obj, key, i) => ({ get: () => obj[key][i], set: (v) => { obj[key][i] = v; } });
  const optional = (obj, key) => ({
    get: () => obj[key] ?? '',
    set: (v) => { if (v === '' || v == null) delete obj[key]; else obj[key] = v; },
  });
  const optNum = (v) => (v === '' ? '' : Number.isNaN(Number(v)) ? undefined : Number(v));

  const row = (...fields) => h('div.fields', fields);
  const section = (title, ...nodes) => h('section.block', h('h3', title), nodes);
  // A button that asks once more before it does something big.
  function confirmButton(label, run) {
    const b = h('button.btn.wide.danger', {
      onclick: () => {
        if (b.dataset.armed) { run(); return; }
        b.dataset.armed = '1';
        b.textContent = 'Tap again to remove';
        haptic('medium');
        setTimeout(() => { delete b.dataset.armed; b.textContent = label; }, 3000);
      },
    }, label);
    return b;
  }

  // Linking to a real device: links.deviceSection / links.sensorSection (connections.js).
  const linkHooks = { snapshot: () => snapshot(), changed: (note) => { touch(); if (note) toast(note); } };

  function renderInspector() {
    const kind = sel.kind;
    const item = sel.index != null ? doc[KEYS[kind]]?.[sel.index] : null;
    const nodes = [];
    const head = (title, sub) => nodes.push(isPhone
      ? h('div.insp-head', h('div.insp-titles', h('h2', title), sub ? h('span', sub) : null), phone.headActions())
      : h('div.insp-head', h('h2', title), sub ? h('span', sub) : null));

    if (kind === 'home') {
      head('Home', 'Global settings of this plan');
      doc.camera ||= { azimuth: 34, elevation: 47 };
      if (isPhone) nodes.push(section('Real devices', links.sidebarRow(false, () => select({ kind: 'connections' }))));
      nodes.push(section('Building',
        row(bind('Wall height, m', number(0.1), { ...prop(doc, 'wallHeight', 2.6), parse: parseNum }),
          bind('Inner walls shown, m', number(0.05), { ...prop(doc, 'interiorWallHeight', 1.25), parse: parseNum })),
        bind('Outdoor temperature, °C', number(1), { ...prop(doc, 'outdoorTemp', 27), parse: parseNum })),
      section('Default camera',
        row(bind('Azimuth, °', number(1), { ...prop(doc.camera, 'azimuth', 34), parse: parseNum }),
          bind('Elevation, °', number(1), { ...prop(doc.camera, 'elevation', 47), parse: parseNum })),
        h('p.note', 'Walls facing the camera are cut away, so the azimuth decides which side of the home is open.')),
      isPhone ? null : section('Shortcuts',
        h('dl.keys',
          h('dt', 'Scroll · ⌘ scroll or pinch'), h('dd', 'Move around · zoom'),
          h('dt', 'Drag the empty plan · Space-drag'), h('dd', 'Move around'),
          h('dt', '⌘D · R · ⇧R'), h('dd', 'Duplicate · turn 90° · turn 15°'),
          h('dt', 'Arrows · ⇧ arrows'), h('dd', 'Nudge 5 cm · 50 cm'),
          h('dt', '⌥ while dragging'), h('dd', 'No snapping'),
          h('dt', 'Page Up · Page Down'), h('dd', 'Floor above · below'),
          h('dt', '⌘0 · Esc · ⌫'), h('dd', 'Whole floor · deselect · remove'))),
      section('How it works',
        h('p.note', isPhone
          ? 'Tap anything on the plan, or find it under Items, to edit it. “Save” keeps the plan on this iPhone and sends it to your paired computer. Coordinates are metres: x grows to the right (east), z grows downwards (south).'
          : 'Pick anything on the plan or in the list to edit it. “Save & apply” writes the plan to disk and reloads the menu bar panel. Coordinates are metres: x grows to the right (east), z grows downwards (south).')));
    } else if (kind === 'level') {
      const l = levelList().find((x) => x.id === sel.id) || levelList().find((x) => x.id === level);
      const list = levelList();
      const i = list.indexOf(l);
      const rooms = levelRooms(l.id);
      const under = below(l.id);
      head(l.name, `${rooms.length} rooms · floor ${i + 1} of ${list.length}`);
      const own = Array.isArray(doc.levels) ? doc.levels.find((x) => x.id === l.id) : null;
      // A home without "levels" gets them as soon as its one floor is named or given a height.
      const editable = () => {
        if (!Array.isArray(doc.levels) || !doc.levels.length) {
          doc.levels = [{ id: 'ground', name: l.name }];
          level = 'ground';
          sel = { kind: 'level', id: 'ground' };
        }
        return doc.levels.find((x) => x.id === sel.id);
      };
      nodes.push(section('Floor',
        bind('Name', text(), { get: () => l.name, set: (v) => { editable().name = v; } }),
        bind('Ceiling height, m', number(0.1), {
          get: () => own?.wallHeight ?? '',
          set: (v) => { const x = editable(); if (v === '') delete x.wallHeight; else x.wallHeight = v; },
          parse: optNum,
        }),
        h('p.note', `Empty: the home’s wall height (${doc.wallHeight ?? 2.6} m). Floors stack in this order; the 3D view shows one floor at a time, with the floors under it.`)),
      section('Arrange',
        h('div.fields',
          h('button.btn', { disabled: i === list.length - 1, onclick: () => moveLevel(l.id, 1) }, icon('stairs', 14, 2.2), 'Move up'),
          h('button.btn', { disabled: i === 0, onclick: () => moveLevel(l.id, -1) }, icon('down', 14, 2.2), 'Move down')),
        h('div.fields',
          h('button.btn', { onclick: () => addLevel('above') }, icon('plus', 14, 2.2), 'Floor above'),
          i === 0 ? h('button.btn', { onclick: () => addLevel('below') }, icon('plus', 14, 2.2), 'Basement') : null),
        under && !rooms.length ? h('button.btn.primary.wide', { onclick: () => copyRoomsFromBelow(l.id) }, icon('copy', 14, 2.2), `Copy the rooms of ${under.name}`) : null,
        under ? h('p.note', `${under.name} shows faintly under this floor, with its stairs, so walls and stairs line up.`) : null),
      list.length > 1 ? section('Remove',
        confirmButton(`Remove ${l.name}`, () => removeLevel(l.id)),
        h('p.note', `Takes its ${rooms.length} rooms with their lamps, ACs, furniture, doors and windows.`)) : null);
    } else if (kind === 'connections') {
      head('Connections', 'Where your real lamps and air conditioners live');
      if (isPhone) nodes.push(h('button.back-link', { onclick: () => select({ kind: 'home' }) }, icon('back', 14, 2.2), 'Home'));
      nodes.push(...links.overview());
    } else if (kind === 'service') {
      nodes.push(h('button.back-link', { onclick: () => { links.stopPairing(); select({ kind: 'connections' }); } }, icon('back', 14, 2.2), 'Connections'));
      nodes.push(h('div.insp-head.svc-head', links.tile(sel.service, 40),
        h('div', h('h2', links.title(sel.service)), h('span', links.blurb(sel.service)))));
      nodes.push(...[links.detail(sel.service, tuyaPanel)].flat());
    } else if (!item) {
      head('Nothing selected');
      if (isPhone) nodes.push(h('p.note', 'Tap a room, a lamp or anything else on the plan.'));
    } else if (kind === 'room') {
      head(item.name || item.id, `id: ${item.id}`);
      const list = levelList();
      nodes.push(section('Room',
        bind('Name', text(), prop(item, 'name', '')),
        row(bind('Flooring', choice(FLOOR_KINDS), { ...prop(item, 'floor', 'oak'), event: 'change' }),
          list.length > 1 ? bind('On floor', choice(list.map((l) => [l.id, l.name])), {
            get: () => item.level ?? firstLevel(), set: (v) => moveRoomToLevel(sel.index, v), event: 'change',
          }) : null),
        h('div.fields',
          h('button.btn', { onclick: () => splitRoom(sel.index) }, icon('split', 14, 2.2), 'Split in two'),
          h('button.btn', { onclick: duplicate }, icon('duplicate', 14, 2.2), 'Duplicate'))),
      section('Position & size, m',
        row(bind('X', number(0.1), { ...at(item, 'rect', 0), parse: parseNum }), bind('Z', number(0.1), { ...at(item, 'rect', 1), parse: parseNum })),
        row(bind('Width', number(0.1), { ...at(item, 'rect', 2), parse: parseNum }), bind('Depth', number(0.1), { ...at(item, 'rect', 3), parse: parseNum })),
        h('p.note', isPhone ? 'Drag the dots on its corners and sides to resize it. Rooms that share an edge get an interior wall there; add a door or an “open” gap to connect them.'
          : 'Drag the dots on its corners and sides to resize it; edges snap to other rooms (hold ⌥ not to). Rooms that share an edge get an interior wall there; add a door or an “open” gap to connect them.')));
    } else if (kind === 'light') {
      head(item.name || item.id, `id: ${item.id}`);
      item.capabilities ||= [];
      const cap = (name) => ({
        get: () => item.capabilities.includes(name),
        set: (on) => { item.capabilities = item.capabilities.filter((c) => c !== name); if (on) item.capabilities.push(name); },
      });
      nodes.push(section('Light',
        bind('Name', text(), prop(item, 'name', '')),
        row(bind('Room', choice(doc.rooms.map((r) => [r.id, r.name || r.id])), { ...prop(item, 'room'), event: 'change' }),
          bind('Fixture', choice(LIGHT_KINDS), { ...prop(item, 'type'), event: 'change' }))),
      section('Position, m',
        row(bind('X', number(), { ...at(item, 'pos', 0), parse: parseNum }), bind('Z', number(), { ...at(item, 'pos', 1), parse: parseNum })),
        row(bind('Height (auto if empty)', number(), { ...optional(item, 'y'), parse: optNum }),
          bind('Rotation, °', number(15), { ...prop(item, 'rot', 0), parse: parseNum })),
        item.type === 'strip' ? bind('Strip length, m', number(0.1), { ...prop(item, 'length', 1), parse: parseNum }) : null),
      section('What it can do',
        h('div.checks',
          bind('Dimming', h('input', { type: 'checkbox' }), { ...cap('brightness'), event: 'change' }),
          bind('White temperature', h('input', { type: 'checkbox' }), { ...cap('temp'), event: 'change' }),
          bind('Colour', h('input', { type: 'checkbox' }), { ...cap('color'), event: 'change' })),
        h('p.note', 'Leave all three off for a lamp on a plain smart plug: it is then a simple on/off switch.')),
      links.deviceSection(item, 'light', linkHooks));
    } else if (kind === 'ac') {
      head(item.name || item.id, `id: ${item.id}`);
      nodes.push(section('Air conditioner',
        bind('Name', text(), prop(item, 'name', '')),
        row(bind('Room', choice(doc.rooms.map((r) => [r.id, r.name || r.id])), { ...prop(item, 'room'), event: 'change' }),
          bind('Mounted on wall', choice(WALLS), { ...prop(item, 'wall', 'north'), event: 'change' }))),
      section('Position, m',
        row(bind('X', number(), { ...at(item, 'pos', 0), parse: parseNum }), bind('Z', number(), { ...at(item, 'pos', 1), parse: parseNum })),
        row(bind('Height', number(), { ...prop(item, 'y', 2.2), parse: parseNum }),
          bind('Min / max °C', text(), {
            get: () => `${item.min ?? 16}-${item.max ?? 30}`,
            set: ([a, b]) => { item.min = a; item.max = b; },
            parse: (v) => { const m = /^(\d+)\s*-\s*(\d+)$/.exec(v.trim()); return m && +m[1] < +m[2] ? [+m[1], +m[2]] : undefined; },
          })),
        h('p.note', 'Dragging the unit on the plan snaps it to the nearest wall of its room.')),
      links.deviceSection(item, 'ac', linkHooks),
      links.sensorSection(item, linkHooks));
    } else if (kind === 'furniture') {
      const stairs = item.type === 'stairs';
      head(stairs ? 'Stairs' : item.type, stairs ? 'Up to the floor above' : 'Decoration only');
      nodes.push(section('Furniture',
        bind('Type', choice(FURNITURE_TYPES), { ...prop(item, 'type'), event: 'change' }),
        row(bind('X', number(), { ...at(item, 'pos', 0), parse: parseNum }), bind('Z', number(), { ...at(item, 'pos', 1), parse: parseNum })),
        row(bind('Rotation, °', number(15), { ...prop(item, 'rot', 0), parse: parseNum }),
          bind('Width, m', number(0.1), { ...optional(item, 'width'), parse: optNum })),
        stairs ? bind('Length, m', number(0.1), { ...optional(item, 'depth'), parse: optNum }) : bind('Colour (hex, optional)', text(), optional(item, 'color')),
        h('div.fields',
          h('button.btn', { onclick: () => rotate(90) }, icon('rotateCw', 14, 2.2), 'Turn 90°'),
          h('button.btn', { onclick: duplicate }, icon('duplicate', 14, 2.2), 'Duplicate')),
        h('p.note', stairs ? 'Stairs climb in the direction of the arrow and reach the floor above; the floor above shows them faintly, to line its landing up.'
          : 'The short line on the plan marks the front. Rotation 0° faces south (towards the bottom of the plan).')));
    } else if (kind === 'opening') {
      head(item.type || 'door', 'A gap or a window in a wall');
      nodes.push(section('Opening',
        bind('Type', choice([['door', 'Door'], ['open', 'Open passage'], ['window', 'Window']]), { ...prop(item, 'type', 'door'), event: 'change' }),
        row(bind('From X', number(), { ...at(item, 'from', 0), parse: parseNum }), bind('From Z', number(), { ...at(item, 'from', 1), parse: parseNum })),
        row(bind('To X', number(), { ...at(item, 'to', 0), parse: parseNum }), bind('To Z', number(), { ...at(item, 'to', 1), parse: parseNum })),
        item.type === 'window' ? row(bind('Sill, m', number(), { ...prop(item, 'sill', 0.85), parse: parseNum }),
          bind('Head, m', number(), { ...prop(item, 'head', 2.1), parse: parseNum })) : null,
        h('p.note', (isPhone
          ? 'Drag it along a wall. To turn it, drag it onto a wall that runs the other way: it snaps to that wall and turns with it. Drag the dots at its ends to make it wider.'
          : 'Drag it along a wall. To turn it, drag it onto a wall that runs the other way: it snaps to that wall and turns with it (hold ⌥ not to snap). Drag the dots at its ends to make it wider.')
          + ' Windows only show on the far walls; the walls facing the camera are cut away.')));
    } else if (kind === 'scene') {
      head(item.name || item.id, `id: ${item.id}`);
      item.lights ||= {};
      const rule = (id) => ({
        get: () => (item.lights[id]?.on === true ? 'on' : item.lights[id]?.on === false ? 'off' : ''),
        set: (v) => {
          if (v === '') delete item.lights[id];
          else item.lights[id] = { ...(item.lights[id] || {}), on: v === 'on' };
        },
      });
      const tri = () => choice([['', 'Leave as is'], ['on', 'On'], ['off', 'Off']]);
      nodes.push(section('Scene',
        row(bind('Name', text(), prop(item, 'name', '')), bind('Icon', choice(SCENE_ICONS), { ...prop(item, 'icon', 'sun'), event: 'change' })),
        bind('On/off button', h('input', { type: 'checkbox' }), {
          get: () => item.toggle === true,
          set: (v) => { if (v) item.toggle = true; else delete item.toggle; },
          event: 'change',
        }),
        h('p.note', item.toggle
          ? 'A tap turns on the lights set to On; the next tap, while any of them is on, turns them off again.'
          : 'Tick it for a room button: one tap on, the next tap off.')),
      section('Lights',
        bind('All lights (default)', tri(), { ...rule('*'), event: 'change' }),
        doc.lights.map((l) => bind(`${l.name} · ${roomName(l.room)}`, tri(), { ...rule(l.id), event: 'change' })),
        h('p.note', 'Brightness, temperature and colour per light are kept from the plan file; edit them there for fine control.')),
      section('Air conditioners',
        bind('All ACs', choice([['', 'Leave as is'], ['off', 'Turn off'], ['on', 'Turn on']]), {
          get: () => (item.acs?.['*']?.on === true ? 'on' : item.acs?.['*']?.on === false ? 'off' : ''),
          set: (v) => { item.acs ||= {}; if (v === '') delete item.acs['*']; else item.acs['*'] = { on: v === 'on' }; },
          event: 'change',
        })));
    }
    const key = `${sel.kind}:${sel.index ?? sel.service ?? sel.id ?? ''}`;
    const same = key === inspector.dataset.key;
    const top = same ? inspector.scrollTop : 0;
    // A refresh of the same screen (devices arriving) keeps the field being typed in.
    const fields = () => [...inspector.querySelectorAll('input, select, textarea')];
    const focused = same ? fields().indexOf(document.activeElement) : -1;
    const caret = focused >= 0 ? [document.activeElement.selectionStart, document.activeElement.selectionEnd] : null;
    inspector.dataset.key = key;
    inspector.replaceChildren(...nodes.flat(2).filter(Boolean));
    inspector.scrollTop = top;
    if (focused >= 0) {
      const el = fields()[focused];
      el?.focus();
      try { if (caret?.[0] != null) el.setSelectionRange(caret[0], caret[1]); } catch { /* not a text field */ }
    }
  }

  /* ---------- Smart Life ---------- */

  let loginTimer = 0;
  function stopLoginPolling() { clearInterval(loginTimer); loginTimer = 0; }

  async function fetchDevices() {
    tuya.busy = true; tuya.error = null;
    if (sel.kind === 'service') renderInspector();
    try {
      tuya.devices = (await call('tuya.devices')).devices;
    } catch (e) {
      tuya.error = e.message;
      tuya.devices = null;
    }
    tuya.busy = false;
    renderSidebar();
    if (sel.kind === 'service') renderInspector();
  }

  function deviceList() {
    if (tuya.busy) return h('p.note', 'Talking to Smart Life…');
    if (tuya.error) return h('p.note.bad', tuya.error);
    if (!tuya.devices) return null;
    if (!tuya.devices.length) return h('p.note.bad', 'Connected, but this account has no devices yet.');
    const used = new Map([...doc.lights, ...doc.acs].filter((d) => d.tuya?.deviceId).map((d) => [d.tuya.deviceId, d.name]));
    return h('div.devices-list', h('h3', `${tuya.devices.length} devices in your account`), tuya.devices.map((d) => h('div.device',
      h(`span.dot${d.online ? '.on' : ''}`),
      h('div', h('b', d.name), h('span', `${d.product || d.category || 'device'} · ${d.codes.join(', ') || 'no functions reported'}`)),
      used.has(d.id) ? h('span.pill.on', used.get(d.id)) : null)));
  }

  function tuyaPanel() {
    const nodes = [];
    if (!isNative) nodes.push(h('p.note.bad', 'Connecting works inside the House Control app (this is the browser preview).'));

    if (tuya.account.connected) {
      nodes.push(section('Smart Life account',
        h('div.device', h('span.dot.on'), h('div', h('b', tuya.account.account || 'Signed in'), h('span', `User Code ${tuya.account.userCode}`))),
        h('div.fields',
          h('button.btn', { onclick: fetchDevices }, 'Refresh devices'),
          h('button.btn', { onclick: async () => {
            stopLoginPolling();
            tuya.account = await call('smartlife.signOut');
            tuya.devices = null; tuya.qr = null;
            renderSidebar(); renderInspector();
            smartLifeChanged();
          } }, 'Sign out')),
        h('p.note', 'Pick a lamp or an AC on the plan, choose its device under “Smart Life device”, then press “Save & apply”.')),
      deviceList());
      if (!tuya.devices && !tuya.busy && !tuya.error && isNative) setTimeout(fetchDevices, 0);
    } else {
      const codeInput = text();
      codeInput.value = tuya.account.userCode || '';
      codeInput.placeholder = 'e.g. aB12cD3';
      const message = h('p.note');
      const qrBox = h('div.qr');
      const start = async () => {
        stopLoginPolling();
        message.className = 'note';
        message.textContent = 'Requesting a login code…';
        qrBox.replaceChildren();
        try {
          const userCode = codeInput.value.trim();
          const { token, qr } = await call('smartlife.begin', { userCode });
          qrBox.replaceChildren(h('img', { src: qr, alt: 'Smart Life login QR code', width: 220, height: 220 }));
          message.textContent = 'Scan this code with the Smart Life app (the scan icon on the Home tab) and confirm the login. Waiting…';
          let tries = 0;
          loginTimer = setInterval(async () => {
            if (++tries > 90) { stopLoginPolling(); message.className = 'note bad'; message.textContent = 'The code expired. Press “Show QR code” again.'; return; }
            const r = await call('smartlife.poll', { token, userCode }).catch(() => null);
            if (!r?.connected) return;
            stopLoginPolling();
            tuya.account = r.info;
            renderSidebar();
            renderInspector();
            smartLifeChanged();
          }, 2000);
        } catch (e) {
          message.className = 'note bad';
          message.textContent = e.message;
        }
      };
      nodes.push(section('Sign in with the Smart Life app',
        h('ol.steps',
          h('li', 'In the Smart Life app open Me → ⚙ Settings → Account and Security and copy the User Code at the bottom.'),
          h('li', 'Type it here and press “Show QR code”.'),
          h('li', 'Scan the code with the Smart Life app and confirm.')),
        h('label.field', h('span', 'User Code'), codeInput),
        h('button.btn.primary.wide', { onclick: start, disabled: !isNative }, 'Show QR code'),
        qrBox, message,
        h('p.note', 'Free and needs no Tuya developer account: this is the same sign-in the Home Assistant integration uses. The session is stored only on this Mac.')));
    }

    // The developer-project route stays available for those who already have one.
    const idInput = text();
    idInput.value = tuya.info.accessId || '';
    idInput.placeholder = 'Access ID / Client ID';
    const secretInput = h('input', { type: 'password', autocomplete: 'off' });
    secretInput.placeholder = tuya.info.hasSecret ? '•••••••• (saved — leave empty to keep)' : 'Access Secret / Client Secret';
    const region = choice(REGIONS.map(([id, label]) => [id, `${label} (${id})`]));
    region.value = tuya.info.region || 'eu';
    const saveCloud = async () => {
      try {
        tuya.info = await call('tuya.save', { accessId: idInput.value, accessSecret: secretInput.value, region: region.value });
        renderSidebar();
        smartLifeChanged();
        if (tuya.info.configured) await fetchDevices(); else renderInspector();
      } catch (e) { toast(e.message, true); }
    };
    nodes.push(h('details.advanced', h('summary', 'Advanced: Tuya Cloud project instead'),
      h('p.note', 'Only if you already have a project on platform.tuya.com with your app account linked. The QR sign-in above takes priority when both are set.'),
      h('label.field', h('span', 'Access ID'), idInput),
      h('label.field', h('span', 'Access Secret'), secretInput),
      h('label.field', h('span', 'Data center'), region),
      h('button.btn.wide', { onclick: saveCloud, disabled: !isNative }, 'Save & fetch devices'),
      tuya.account.connected ? null : deviceList()));
    return nodes;
  }

  /* ---------- file actions ---------- */

  async function save() {
    if (!valid) return;
    if (!isNative) {
      download();
      toast('Browser preview: the plan was downloaded instead of applied');
      return;
    }
    try {
      await call('savePlan', { config: doc });
      dirty = false;
      validate();
      haptic('success');
      toast(isPhone ? 'Saved' : 'Saved — the menu bar panel now shows this home');
    } catch (e) {
      toast(e.message, true);
    }
  }

  function download() {
    const a = h('a', { href: URL.createObjectURL(new Blob([JSON.stringify(doc, null, 2)], { type: 'application/json' })), download: `${slug(doc.name)}.json` });
    a.click();
    setTimeout(() => URL.revokeObjectURL(a.href), 1000);
  }

  async function exportPlan() {
    if (!isNative) { download(); return; }
    try {
      const r = await call('exportPlan', { config: doc });
      if (r.ok) toast('Plan exported');
    } catch (e) { toast(e.message, true); }
  }

  async function importPlan() {
    const load = (json) => {
      try {
        normalize(structuredClone(json));
      } catch (e) {
        toast(`Not a valid plan: ${e.message}`, true);
        return;
      }
      snapshot();
      doc = json;
      for (const key of Object.values(KEYS)) doc[key] ||= [];
      nameInput.value = doc.name || 'Home';
      sel = { kind: 'home' };
      checkLevel();
      view = null;
      touch();
      toast('Plan imported — review it and press “Save & apply”');
    };
    if (isNative) {
      try {
        const r = await call('importPlan');
        if (r.config) load(r.config);
      } catch (e) { toast(e.message, true); }
      return;
    }
    const input = h('input', { type: 'file', accept: 'application/json,.json' });
    input.addEventListener('change', async () => {
      try { load(JSON.parse(await input.files[0].text())); } catch (e) { toast(`Could not read the file: ${e.message}`, true); }
    });
    input.click();
  }

  /* ---------- keyboard ---------- */

  window.addEventListener('keydown', (ev) => {
    const typing = /^(INPUT|SELECT|TEXTAREA)$/.test(document.activeElement?.tagName || '');
    const cmd = ev.metaKey || ev.ctrlKey;
    const key = ev.key.toLowerCase();
    if (cmd && key === 'z' && !typing) {
      ev.preventDefault();
      if (ev.shiftKey) stepHistory(redo, undo); else stepHistory(undo, redo);
    } else if (cmd && key === 's') {
      ev.preventDefault();
      save();
    } else if (typing) {
      // the field gets the key
    } else if (cmd && key === 'd') {
      ev.preventDefault();
      duplicate();
    } else if (cmd && (key === '0' || key === '=' || key === '+' || key === '-')) {
      ev.preventDefault();
      if (key === '0') reveal(); else zoomBy(key === '-' ? 1 / 1.35 : 1.35);
    } else if (ev.code === 'Space' && !isPhone) {
      ev.preventDefault();
      spaceHeld = true;
      plan.classList.add('can-pan');
    } else if (ev.key === 'Escape') {
      if (sel.kind !== 'home') select({ kind: 'home' });
    } else if (key === 'r' && !cmd) {
      rotate(ev.shiftKey ? 15 : 90);
    } else if (ev.key === 'PageUp' || ev.key === 'PageDown') {
      ev.preventDefault();
      const list = levelList();
      const next = list[list.findIndex((l) => l.id === level) + (ev.key === 'PageUp' ? 1 : -1)];
      if (next) setLevel(next.id);
    } else if ((ev.key === 'Backspace' || ev.key === 'Delete') && sel.index != null) {
      ev.preventDefault();
      remove(sel.kind, sel.index);
    } else if (ev.key.startsWith('Arrow') && sel.index != null) {
      const item = doc[KEYS[sel.kind]][sel.index];
      const targets = item.from ? [item.from, item.to] : [item.pos || item.rect].filter(Boolean);
      if (!targets.length) return;
      ev.preventDefault();
      const stepSize = ev.shiftKey ? 0.5 : 0.05;
      snapshot(`nudge${sel.kind}${sel.index}`);
      for (const target of targets) {
        if (ev.key === 'ArrowLeft') target[0] = fix(target[0] - stepSize);
        if (ev.key === 'ArrowRight') target[0] = fix(target[0] + stepSize);
        if (ev.key === 'ArrowUp') target[1] = fix(target[1] - stepSize);
        if (ev.key === 'ArrowDown') target[1] = fix(target[1] + stepSize);
      }
      touch();
    }
  });

  /* ---------- iPhone ---------- */

  // The plan fills the screen; a bar on top (close, name, undo, save), tools at the bottom
  // (add, items, 3D, home) and the inspector as a sheet that rises when something is picked.
  function buildPhoneLayout() {
    const canvas = h('main.canvas');
    const sheet = h('section.p-sheet', { 'aria-label': 'Details' });
    const grip = h('div.p-grip', { role: 'button', 'aria-label': 'Resize details' }, h('span'));
    const scrim = h('div.p-scrim');
    const listSheet = h('section.p-modal', { 'aria-label': 'Items' });
    const addSheet = h('section.p-modal.p-add', { 'aria-label': 'Add' });
    const confirmSheet = h('section.p-modal.p-confirm', { 'aria-label': 'Unsaved changes' });
    const undoBtn = h('button.p-icon', { 'aria-label': 'Undo', onclick: () => { stepHistory(undo, redo); haptic('light'); } }, icon('undo', 19, 2.1));
    const redoBtn = h('button.p-icon', { 'aria-label': 'Redo', onclick: () => { stepHistory(redo, undo); haptic('light'); } }, icon('redo', 19, 2.1));
    const doneBtn = h('button.p-save', { onclick: () => (dirty ? save() : close()) });
    const issue = h('div.p-issue');
    const fitBtn = h('button.p-float', { 'aria-label': 'Show the whole floor', onclick: () => { reveal(); haptic('light'); } }, icon('fit', 18, 2));
    const tool = (name, label, onclick) => h('button.p-tool', { onclick }, icon(name, 22, 1.9), h('span', label));
    const view3d = tool('box', '3D', () => setShow3D(!ui.show3D));
    const tools = h('nav.p-tools',
      tool('plus', 'Add', () => openModal(addSheet)),
      tool('list', 'Items', () => openModal(listSheet)),
      view3d,
      tool('home', 'Home', () => { select({ kind: 'home' }); setSheet('full'); }));

    nameInput.setAttribute('enterkeyhint', 'done');
    nameInput.addEventListener('keydown', (ev) => { if (ev.key === 'Enter') nameInput.blur(); });
    sidebar.classList.add('p-list');
    listSheet.append(h('div.p-modal-head', h('b', 'Items'), h('button.p-text', { onclick: closeModals }, 'Done')), sidebar);
    const addables = [
      ...addable(),
      ['level', 'layers', 'Floor', () => addLevel()],
      ['scene', 'sparkles', 'Scene', () => add('scene')],
    ];
    addSheet.append(h('div.p-modal-head', h('b', 'Add to the plan'), h('button.p-text', { onclick: closeModals }, 'Cancel')),
      h('div.p-add-grid', addables.map(([, name, label, run]) => h('button.p-add-item', {
        onclick: () => { closeModals(); run(); haptic('light'); if (sel.kind !== 'level') setSheet('peek'); else setSheet('full'); },
      }, icon(name, 24, 1.8), h('span', label)))));
    confirmSheet.append(h('div.p-modal-head', h('b', 'Unsaved changes')),
      h('p.note', 'Save them before closing? Saved plans reach your paired computer too.'),
      h('div.p-confirm-actions',
        h('button.btn.primary.wide', { onclick: async () => { closeModals(); await save(); if (!dirty) close(); } }, 'Save and close'),
        h('button.btn.wide.danger', { onclick: () => { closeModals(); dirty = false; close(); } }, 'Discard changes'),
        h('button.btn.wide', { onclick: closeModals }, 'Keep editing')));

    sheet.append(grip, inspector);
    canvas.append(plan, levelBar, emptyCard, h('div.p-preview', previewHost, previewToggle), issue, fitBtn, hint);
    const shell = h('div.editor.phone',
      h('header.p-bar', h('button.p-icon', { 'aria-label': 'Close', onclick: requestClose }, icon('close', 20, 2.2)),
        nameInput, undoBtn, redoBtn, doneBtn),
      canvas, tools, scrim, sheet, listSheet, addSheet, confirmSheet, toastEl);
    root.replaceChildren(shell);

    /* sheet: closed, peek (the bottom part of the screen) or full */
    function setSheet(next) {
      ui.sheet = next;
      sheet.dataset.state = next;
      shell.dataset.sheet = next;
      sheet.style.height = '';
      document.activeElement?.blur?.();
    }
    let gripDrag = null;
    // Docked beside the plan on a wide screen (editor.css), the details have no height to drag.
    const docked = matchMedia('(min-width: 720px) and (min-aspect-ratio: 23/20)');
    const startGrip = (ev) => {
      if (docked.matches || ev.target.closest('button, input, select, textarea, a')) return;
      gripDrag = { y: ev.clientY, h: sheet.getBoundingClientRect().height, id: ev.pointerId, moved: false };
    };
    grip.addEventListener('pointerdown', startGrip);
    inspector.addEventListener('pointerdown', (ev) => { if (ev.target.closest('.insp-head')) startGrip(ev); });
    window.addEventListener('pointermove', (ev) => {
      if (!gripDrag || ev.pointerId !== gripDrag.id) return;
      const dy = ev.clientY - gripDrag.y;
      if (!gripDrag.moved && Math.abs(dy) < 6) return;
      gripDrag.moved = true;
      sheet.classList.add('dragging');
      sheet.style.height = `${Math.max(80, gripDrag.h - dy)}px`;
    });
    const endGrip = (ev) => {
      if (!gripDrag || ev.pointerId !== gripDrag.id) return;
      const { moved, h: from } = gripDrag;
      gripDrag = null;
      sheet.classList.remove('dragging');
      if (!moved) { if (ev.target.closest('.p-grip')) setSheet(ui.sheet === 'full' ? 'peek' : 'full'); return; }
      const now = sheet.getBoundingClientRect().height;
      const screen = window.innerHeight;
      if (now < Math.min(from, screen * 0.42) * 0.7) closeSheet();
      else setSheet(now > screen * 0.62 ? 'full' : 'peek');
    };
    window.addEventListener('pointerup', endGrip);
    window.addEventListener('pointercancel', endGrip);

    function closeSheet() {
      setSheet('closed');
      if (sel.kind !== 'home') { sel = { kind: 'home' }; renderSidebar(); renderPlan(); renderInspector(); }
    }

    function openModal(el) {
      closeModals();
      if (el === listSheet) renderSidebar();
      el.classList.add('open');
      scrim.classList.add('open');
      haptic('light');
    }
    function closeModals() {
      for (const el of [listSheet, addSheet, confirmSheet]) el.classList.remove('open');
      scrim.classList.remove('open');
    }
    scrim.addEventListener('click', closeModals);

    function requestClose() {
      if (dirty) openModal(confirmSheet); else close();
    }
    function close() { post('close'); }

    function setShow3D(on) {
      ui.show3D = on;
      canvas.classList.toggle('show-3d', on);
      view3d.replaceChildren(icon(on ? 'map' : 'box', 22, 1.9), h('span', on ? 'Plan' : '3D'));
      schedulePreview(0);
      haptic('light');
    }

    // One finger on what is selected drags it; anywhere else it pans, and a tap picks.
    // Two fingers pinch to zoom.
    const fingers = new Map();
    let gesture = null;
    const spread = () => { const [a, b] = [...fingers.values()]; return Math.hypot(a.x - b.x, a.y - b.y); };
    const middle = () => { const [a, b] = [...fingers.values()]; return { x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 }; };

    plan.addEventListener('pointerdown', (ev) => {
      // A first finger starts afresh: a gesture the system took over (a back swipe) never ended here.
      if (ev.isPrimary && (fingers.size || gesture)) {
        fingers.clear();
        gesture = null;
        if (drag) endDrag();
      }
      plan.setPointerCapture(ev.pointerId);
      fingers.set(ev.pointerId, { x: ev.clientX, y: ev.clientY });
      if (fingers.size === 2) {
        if (drag) endDrag();
        const rect = plan.getBoundingClientRect();
        const v = box();
        const mid = middle();
        gesture = { type: 'pinch', d0: spread(), v0: v, at: { x: v.x + (mid.x - rect.left) * v.w / rect.width, y: v.y + (mid.y - rect.top) * v.h / rect.height } };
        return;
      }
      if (fingers.size > 2) return;
      const el = ev.target.closest('[data-kind]');
      const kind = el?.dataset.kind;
      const index = Number(el?.dataset.index);
      // A selected room is grabbed anywhere inside it, even over its furniture and lamps.
      const room = sel.kind === 'room' && doc.rooms[sel.index];
      const [px, pz] = planPoint(ev);
      const inRoom = room && px >= room.rect[0] && px <= room.rect[0] + room.rect[2] && pz >= room.rect[1] && pz <= room.rect[1] + room.rect[3];
      const handle = kind === 'resize' || kind === 'oend';
      if (handle || (kind && kind !== 'none' && isSel(kind, index)) || (inRoom && kind !== 'light' && kind !== 'ac')) {
        const what = handle || isSel(kind, index) ? [kind, index] : ['room', sel.index];
        // The view holds still while something is dragged past the plan's edge.
        if (!view) view = fitBox();
        startDrag(what[0], what[1], ev, el?.dataset.handle);
        gesture = { type: 'drag' };
        return;
      }
      gesture = { type: 'pan', x: ev.clientX, y: ev.clientY, v0: box(), moved: false, kind, index };
    });

    plan.addEventListener('pointermove', (ev) => {
      if (!fingers.has(ev.pointerId)) return;
      fingers.set(ev.pointerId, { x: ev.clientX, y: ev.clientY });
      if (!gesture) return;
      if (gesture.type === 'drag') { moveDrag(ev); return; }
      const rect = plan.getBoundingClientRect();
      if (gesture.type === 'pinch' && fingers.size === 2) {
        const fit = fitBox();
        const w = clamp(gesture.v0.w * gesture.d0 / Math.max(1, spread()), 1.6, Math.max(fit.w * 2.5, 24));
        const hh = w * rect.height / rect.width;
        const mid = middle();
        view = { x: gesture.at.x - (mid.x - rect.left) * w / rect.width, y: gesture.at.y - (mid.y - rect.top) * hh / rect.height, w, h: hh };
        applyView();
      } else if (gesture.type === 'pan') {
        const dx = ev.clientX - gesture.x;
        const dy = ev.clientY - gesture.y;
        if (!gesture.moved && Math.hypot(dx, dy) < 8) return;
        gesture.moved = true;
        const v = gesture.v0;
        view = { ...v, x: v.x - dx * v.w / rect.width, y: v.y - dy * v.h / rect.height };
        applyView();
      }
    });

    const lift = (ev) => {
      if (!fingers.delete(ev.pointerId)) return;
      if (!gesture) return;
      if (gesture.type === 'drag') {
        // A tap on what is already selected (just added, say) brings up its details.
        const tapped = ev.type === 'pointerup' && drag && !drag.moved && drag.kind !== 'resize' && drag.kind !== 'oend';
        endDrag();
        gesture = null;
        if (tapped && ui.sheet === 'closed') { haptic('light'); setSheet('peek'); }
        return;
      }
      if (gesture.type === 'pinch') {
        // One finger stays down: it carries on panning from here.
        const [rest] = [...fingers.values()];
        gesture = rest ? { type: 'pan', x: rest.x, y: rest.y, v0: box(), moved: true } : null;
        return;
      }
      if (gesture.type === 'pan' && !gesture.moved && ev.type === 'pointerup') {
        const { kind, index } = gesture;
        if (kind && kind !== 'none' && kind !== 'resize' && kind !== 'oend') { haptic('light'); select({ kind, index }); }
        else if (ui.sheet !== 'closed') closeSheet();
      }
      gesture = null;
    };
    plan.addEventListener('pointerup', lift);
    plan.addEventListener('pointercancel', lift);

    const ui = {
      sheet: 'closed',
      show3D: false,
      // Something was picked (on the plan, in the list, in 3D): its details come up.
      selected(next) {
        closeModals();
        if (next.kind === 'connections' || next.kind === 'service' || next.kind === 'level') setSheet('full');
        else if (next.kind !== 'home' && ui.sheet === 'closed') setSheet('peek');
      },
      headActions() {
        const nodes = [];
        if (sel.kind === 'furniture' || (sel.kind === 'light' && doc.lights[sel.index]?.type === 'strip')) {
          nodes.push(h('button.p-icon', { 'aria-label': 'Turn 90°', onclick: () => { haptic('light'); rotate(90); } }, icon('rotateCw', 18, 2)));
        }
        if (sel.index != null) {
          nodes.push(h('button.p-icon', { 'aria-label': 'Duplicate', onclick: () => { haptic('light'); duplicate(); } }, icon('duplicate', 18, 2)));
          nodes.push(h('button.p-icon.danger', {
            'aria-label': 'Remove', onclick: () => { haptic('medium'); remove(sel.kind, sel.index); setSheet('closed'); },
          }, icon('trash', 18, 2)));
        }
        nodes.push(h('button.p-icon', { 'aria-label': 'Close details', onclick: closeSheet }, icon('down', 20, 2.2)));
        return h('div.p-head-actions', nodes);
      },
      refresh() {
        doneBtn.textContent = dirty ? 'Save' : 'Done';
        doneBtn.classList.toggle('primary', dirty);
        doneBtn.disabled = dirty && !valid;
        undoBtn.disabled = !undo.length;
        redoBtn.disabled = !redo.length;
        issue.textContent = valid ? '' : status.textContent;
        issue.classList.toggle('show', !valid);
      },
    };
    setSheet(sel.kind === 'connections' || sel.kind === 'service' ? 'full' : 'closed');
    phone = ui;
  }

  renderSidebar();
  renderPlan();
  renderInspector();
  validate();
  dirty = false;
  validate();
  schedulePreview(0);
  incoming.openSection = (at) => select(sectionSel(at));
  // A plan saved on the other device (the Mac, or the paired iPhone) while this editor is open.
  incoming.planArrived = (config, from) => {
    if (dirty) {
      toast(`${from || 'Your other device'} saved a newer plan. Saving here replaces it.`, true);
      return;
    }
    doc = structuredClone(config);
    for (const key of Object.values(KEYS)) doc[key] ||= [];
    nameInput.value = doc.name || 'Home';
    checkLevel();
    if (sel.index != null && !doc[KEYS[sel.kind]]?.[sel.index]) sel = { kind: 'home' };
    if (sel.kind === 'level' && !levelList().some((l) => l.id === sel.id)) sel = { kind: 'home' };
    touch();
    dirty = false;
    validate();
    toast(`Updated from ${from || 'your other device'}`);
  };

  window.__editor = { get doc() { return doc; }, select, tuya, links, phone };
  post('ready');
}
