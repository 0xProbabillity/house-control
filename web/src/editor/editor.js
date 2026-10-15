// Home editor (a window on the Mac, full screen on the iPhone): a top-down plan you can drag
// things around on, an inspector for the selected item, a live 3D preview and the links to
// real devices. On a phone the same pieces are laid out for a finger: the plan fills the
// screen, the inspector is a sheet from the bottom, pinch zooms and drag pans.
import './editor.css';
import { normalize, loadRawConfig, LIGHT_KINDS, FLOOR_KINDS, isLinked } from '../config.js';
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
const SCENE_ICONS = ['sun', 'sofa', 'film', 'moon', 'door', 'table', 'bed', 'tv', 'sparkles'];
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

  // HOUSE_OPEN_EDITOR=connections|smartlife|homeassistant|hue|homekit opens a connection screen.
  const startAt = window.__HOUSE_BOOT__?.section || new URLSearchParams(location.search).get('section') || '';
  let sel = startAt === 'connections' ? { kind: 'connections' }
    : startAt.startsWith('service:') ? { kind: 'service', service: startAt.slice(8) }
      : startAt === 'tuya' ? { kind: 'service', service: 'smartlife' } : { kind: 'home' };
  let dirty = false;
  let world = null;
  let phone = null; // the iPhone's layout and gestures, set up by buildPhoneLayout()
  let previewLights = true;
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
  const hint = h('div.hint', isPhone ? 'Tap to select · drag what is selected · pinch to zoom'
    : 'Drag rooms, lamps and furniture · drag a room’s corner to resize · everything snaps to 5 cm');
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
    h('main.canvas', plan, hint),
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
    if (sel.index != null && !doc[KEYS[sel.kind]]?.[sel.index]) sel = { kind: 'home' };
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

  /* ---------- validation + preview ---------- */

  let valid = null;
  function validate() {
    try {
      valid = normalize(structuredClone(doc));
      const linked = [...doc.lights, ...doc.acs].filter(isLinked).length;
      status.className = 'status';
      status.replaceChildren(h('span.ok', '●'), ` ${doc.rooms.length} rooms · ${doc.lights.length} lights · ${doc.acs.length} ACs · `,
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
    if (kind === 'opening') return [item.type || 'door', `${fix(Math.hypot(item.to[0] - item.from[0], item.to[1] - item.from[1]))} m`];
    return [item.name || item.id, `${Object.keys(item.lights || {}).length} rules`];
  }

  const roomName = (id) => doc.rooms.find((r) => r.id === id)?.name || id || '';
  const roomAt = ([x, z]) => doc.rooms.find((r) => x >= r.rect[0] && x <= r.rect[0] + r.rect[2] && z >= r.rect[1] && z <= r.rect[1] + r.rect[3]);

  function renderSidebar() {
    const nodes = [h(`button.row.home-row${sel.kind === 'home' ? '.active' : ''}`, { onclick: () => select({ kind: 'home' }) },
      icon('home', 15), h('span.row-name', 'Home settings')),
    links.sidebarRow(sel.kind === 'connections' || sel.kind === 'service', () => select({ kind: 'connections' }))];
    for (const kind of Object.keys(KEYS)) {
      const items = doc[KEYS[kind]];
      nodes.push(h('div.group',
        h('span', `${TITLES[kind]}`), h('span.n', items.length),
        h('button.add', { title: `Add to ${TITLES[kind].toLowerCase()}`, 'aria-label': `Add ${kind}`, onclick: () => add(kind) }, icon('plus', 14, 2.4))));
      items.forEach((item, index) => {
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

  function add(kind) {
    snapshot();
    const room = (sel.kind === 'room' && doc.rooms[sel.index]) || doc.rooms.find((r) => r.id === doc[KEYS[sel.kind]]?.[sel.index]?.room) || doc.rooms[0];
    const center = room ? [fix(room.rect[0] + room.rect[2] / 2), fix(room.rect[1] + room.rect[3] / 2)] : [1, 1];
    const list = doc[KEYS[kind]];
    if (kind === 'room') {
      const maxX = Math.max(0, ...doc.rooms.map((r) => r.rect[0] + r.rect[2]));
      const minZ = Math.min(...doc.rooms.map((r) => r.rect[1]), 0);
      list.push({ id: uniqueId('room'), name: 'New room', rect: [fix(maxX), fix(doc.rooms.length ? minZ : 0), 3, 3], floor: 'oak' });
    } else if (kind === 'light') {
      if (!room) return toast('Add a room first', true);
      list.push({ id: uniqueId(`${room.id}.light`), name: 'New light', room: room.id, type: 'ceiling', pos: freeSpot(room, center), capabilities: [] });
    } else if (kind === 'ac') {
      if (!room) return toast('Add a room first', true);
      list.push({ id: uniqueId(`${room.id}.ac`), name: `${room.name} AC`, room: room.id, wall: 'north', pos: [center[0], room.rect[1]], y: 2.2 });
    } else if (kind === 'furniture') {
      list.push({ type: 'sofa', pos: center, rot: 0 });
    } else if (kind === 'opening') {
      if (!room) return toast('Add a room first', true);
      const z = room.rect[1] + room.rect[3];
      list.push({ type: 'door', from: [fix(center[0] - 0.45), fix(z)], to: [fix(center[0] + 0.45), fix(z)] });
    } else if (kind === 'scene') {
      list.push({ id: uniqueId('scene'), name: 'New scene', icon: 'sparkles', lights: { '*': { on: false } } });
    }
    sel = { kind, index: list.length - 1 };
    touch();
  }

  // The middle of the room, or the nearest place around it no other lamp stands on.
  function freeSpot(room, center) {
    const [x, z, w, d] = room.rect;
    const taken = (p) => doc.lights.some((l) => Math.hypot(l.pos[0] - p[0], l.pos[1] - p[1]) < 0.45);
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
    if (kind === 'room') {
      // Devices cannot outlive their room.
      doc.lights = doc.lights.filter((l) => l.room !== gone.id);
      doc.acs = doc.acs.filter((a) => a.room !== gone.id);
    }
    if (kind === 'light' || kind === 'ac' || kind === 'room') {
      const ids = new Set([...doc.lights, ...doc.acs].map((d) => d.id));
      for (const sc of doc.scenes) {
        for (const map of [sc.lights, sc.acs]) for (const id of Object.keys(map || {})) if (id !== '*' && !ids.has(id)) delete map[id];
      }
    }
    sel = { kind: 'home' };
    touch();
  }

  /* ---------- plan (SVG) ---------- */

  function bounds() {
    const rs = doc.rooms.length ? doc.rooms : [{ rect: [0, 0, 6, 4] }];
    const minX = Math.min(...rs.map((r) => r.rect[0]));
    const minZ = Math.min(...rs.map((r) => r.rect[1]));
    const maxX = Math.max(...rs.map((r) => r.rect[0] + r.rect[2]));
    const maxZ = Math.max(...rs.map((r) => r.rect[1] + r.rect[3]));
    return { minX, minZ, maxX, maxZ };
  }

  const isSel = (kind, index) => sel.kind === kind && sel.index === index;

  function renderPlan() {
    const b = bounds();
    const m = 1.4;
    if (isPhone) phone.applyView();
    else plan.setAttribute('viewBox', `${b.minX - m} ${b.minZ - m} ${b.maxX - b.minX + m * 2} ${b.maxZ - b.minZ + m * 2}`);
    // Fingers are bigger than a mouse pointer: on a phone small things get a wider target.
    const big = isPhone;
    const kids = [
      sv('defs', {}, sv('pattern', { id: 'grid', width: 1, height: 1, patternUnits: 'userSpaceOnUse' },
        sv('path', { d: 'M1 0H0V1', fill: 'none', stroke: 'rgba(255,255,255,0.07)', 'stroke-width': 0.015 }),
        sv('path', { d: 'M0.5 0V1M0 0.5H1', fill: 'none', stroke: 'rgba(255,255,255,0.03)', 'stroke-width': 0.01 }))),
      sv('rect', { x: b.minX - 20, y: b.minZ - 20, width: 60, height: 60, fill: 'url(#grid)', 'data-kind': 'none' }),
    ];

    doc.rooms.forEach((r, i) => {
      const [x, z, w, d] = r.rect;
      const g = sv('g', { class: `p-room${isSel('room', i) ? ' sel' : ''}`, 'data-kind': 'room', 'data-index': i },
        sv('rect', { x, y: z, width: w, height: d, fill: FLOOR_FILL[r.floor] || FLOOR_FILL.oak }),
        sv('text', { x: x + w / 2, y: z + d / 2 - 0.02, class: 'p-label' }, document.createTextNode(r.name || r.id)),
        sv('text', { x: x + w / 2, y: z + d / 2 + 0.3, class: 'p-dim' }, document.createTextNode(`${fix(w)} × ${fix(d)}`)));
      kids.push(g);
    });

    doc.furniture.forEach((f, i) => {
      if (!Array.isArray(f.pos)) return;
      const [w, d] = footprint(f);
      kids.push(sv('g', {
        class: `p-furn${isSel('furniture', i) ? ' sel' : ''}`, 'data-kind': 'furniture', 'data-index': i,
        transform: `translate(${f.pos[0]} ${f.pos[1]}) rotate(${-(f.rot || 0)})`,
      },
        sv('rect', { x: -w / 2, y: -d / 2, width: w, height: d, rx: 0.06 }),
        // a tick marks the front of the piece
        sv('path', { d: `M${-w / 4} ${d / 2}H${w / 4}`, class: 'front' })));
    });

    doc.openings.forEach((o, i) => {
      if (big) kids.push(sv('line', { class: 'p-hit', 'data-kind': 'opening', 'data-index': i, x1: o.from[0], y1: o.from[1], x2: o.to[0], y2: o.to[1] }));
      kids.push(sv('line', {
        class: `p-open ${o.type || 'door'}${isSel('opening', i) ? ' sel' : ''}`, 'data-kind': 'opening', 'data-index': i,
        x1: o.from[0], y1: o.from[1], x2: o.to[0], y2: o.to[1],
      }));
    });

    doc.acs.forEach((a, i) => {
      const rot = { north: 0, east: 90, south: 180, west: 270 }[a.wall] || 0;
      kids.push(sv('g', {
        class: `p-ac${isSel('ac', i) ? ' sel' : ''}`, 'data-kind': 'ac', 'data-index': i,
        transform: `translate(${a.pos[0]} ${a.pos[1]}) rotate(${rot})`,
      }, big ? sv('rect', { x: -0.62, y: -0.12, width: 1.24, height: 0.74, class: 'hit' }) : null,
        sv('rect', { x: -0.47, y: 0.08, width: 0.94, height: 0.24, rx: 0.07 }),
        sv('path', { d: 'M-0.3 0.42v0.22M0 0.42v0.3M0.3 0.42v0.22', class: 'flow' })));
    });

    doc.lights.forEach((l, i) => {
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

    if (sel.kind === 'room' && doc.rooms[sel.index]) {
      const [x, z, w, d] = doc.rooms[sel.index].rect;
      if (big) kids.push(sv('circle', { cx: x + w, cy: z + d, r: 0.55, class: 'hit', 'data-kind': 'resize', 'data-index': sel.index }));
      kids.push(sv('circle', { cx: x + w, cy: z + d, r: big ? 0.24 : 0.16, class: 'p-handle', 'data-kind': 'resize', 'data-index': sel.index }));
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

  let drag = null;
  plan.addEventListener('pointerdown', (ev) => {
    if (isPhone) return;
    const el = ev.target.closest('[data-kind]');
    const kind = el?.dataset.kind;
    if (!kind || kind === 'none') { select({ kind: 'home' }); return; }
    plan.setPointerCapture(ev.pointerId);
    startDrag(kind, Number(el.dataset.index), ev);
  });

  // Picks up an item (or a room's resize handle) under the pointer.
  function startDrag(kind, index, ev) {
    const start = planPoint(ev);
    if (kind === 'resize') {
      drag = { kind, index, start, rect: [...doc.rooms[index].rect] };
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
        ...doc.furniture.filter((f) => Array.isArray(f.pos) && inside(f.pos)).map((o) => ({ o, pos: [...o.pos] })),
      ];
      drag.openings = doc.openings.filter((o) => inside(o.from) && inside(o.to)).map((o) => ({ o, from: [...o.from], to: [...o.to] }));
    } else if (kind === 'opening') {
      drag.from = [...item.from];
      drag.to = [...item.to];
    } else {
      drag.pos = [...item.pos];
    }
  }

  plan.addEventListener('pointermove', (ev) => { if (!isPhone) moveDrag(ev); });

  function moveDrag(ev) {
    if (!drag) return;
    const [px, pz] = planPoint(ev);
    const dx = round(px - drag.start[0]);
    const dz = round(pz - drag.start[1]);
    if (!drag.moved && !dx && !dz) return;
    if (!drag.moved) { drag.moved = true; snapshot(); haptic('tick'); }
    const item = drag.kind === 'resize' ? doc.rooms[drag.index] : doc[KEYS[drag.kind]][drag.index];

    if (drag.kind === 'resize') {
      item.rect[2] = fix(Math.max(1, round(drag.rect[2] + px - drag.start[0], 0.1)));
      item.rect[3] = fix(Math.max(1, round(drag.rect[3] + pz - drag.start[1], 0.1)));
    } else if (drag.kind === 'room') {
      const mx = round(px - drag.start[0], 0.1);
      const mz = round(pz - drag.start[1], 0.1);
      item.rect[0] = fix(drag.rect[0] + mx);
      item.rect[1] = fix(drag.rect[1] + mz);
      for (const r of drag.riders) r.o.pos = [fix(r.pos[0] + mx), fix(r.pos[1] + mz)];
      for (const r of drag.openings) {
        r.o.from = [fix(r.from[0] + mx), fix(r.from[1] + mz)];
        r.o.to = [fix(r.to[0] + mx), fix(r.to[1] + mz)];
      }
    } else if (drag.kind === 'opening') {
      item.from = [fix(drag.from[0] + dx), fix(drag.from[1] + dz)];
      item.to = [fix(drag.to[0] + dx), fix(drag.to[1] + dz)];
    } else if (drag.kind === 'ac') {
      snapAC(item, [px, pz]);
    } else {
      item.pos = [fix(drag.pos[0] + dx), fix(drag.pos[1] + dz)];
      if (drag.kind === 'light') {
        const room = roomAt(item.pos);
        if (room) item.room = room.id;
      }
    }
    touch();
  }

  const endDrag = () => { drag = null; lastSnapshotKey = null; };
  plan.addEventListener('pointerup', () => { if (!isPhone) endDrag(); });
  plan.addEventListener('pointercancel', () => { if (!isPhone) endDrag(); });

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
      section('How it works',
        h('p.note', isPhone
          ? 'Tap anything on the plan, or find it under Items, to edit it. “Save” keeps the plan on this iPhone and sends it to your paired Mac. Coordinates are metres: x grows to the right (east), z grows downwards (south).'
          : 'Pick anything on the plan or in the list to edit it. “Save & apply” writes the plan to disk and reloads the menu bar panel. Coordinates are metres: x grows to the right (east), z grows downwards (south).')));
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
      nodes.push(section('Room',
        bind('Name', text(), prop(item, 'name', '')),
        bind('Floor', choice(FLOOR_KINDS), { ...prop(item, 'floor', 'oak'), event: 'change' })),
      section('Position & size, m',
        row(bind('X', number(0.1), { ...at(item, 'rect', 0), parse: parseNum }), bind('Z', number(0.1), { ...at(item, 'rect', 1), parse: parseNum })),
        row(bind('Width', number(0.1), { ...at(item, 'rect', 2), parse: parseNum }), bind('Depth', number(0.1), { ...at(item, 'rect', 3), parse: parseNum })),
        h('p.note', 'Rooms that share an edge get an interior wall there. Add a door or an “open” gap to connect them.')));
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
      head(item.type, 'Decoration only');
      nodes.push(section('Furniture',
        bind('Type', choice(FURNITURE_TYPES), { ...prop(item, 'type'), event: 'change' }),
        row(bind('X', number(), { ...at(item, 'pos', 0), parse: parseNum }), bind('Z', number(), { ...at(item, 'pos', 1), parse: parseNum })),
        row(bind('Rotation, °', number(15), { ...prop(item, 'rot', 0), parse: parseNum }),
          bind('Width, m', number(0.1), { ...optional(item, 'width'), parse: optNum })),
        bind('Colour (hex, optional)', text(), optional(item, 'color')),
        h('p.note', 'The short line on the plan marks the front. Rotation 0° faces south (towards the bottom of the plan).')));
    } else if (kind === 'opening') {
      head(item.type || 'door', 'A gap or a window in a wall');
      nodes.push(section('Opening',
        bind('Type', choice([['door', 'Door'], ['open', 'Open passage'], ['window', 'Window']]), { ...prop(item, 'type', 'door'), event: 'change' }),
        row(bind('From X', number(), { ...at(item, 'from', 0), parse: parseNum }), bind('From Z', number(), { ...at(item, 'from', 1), parse: parseNum })),
        row(bind('To X', number(), { ...at(item, 'to', 0), parse: parseNum }), bind('To Z', number(), { ...at(item, 'to', 1), parse: parseNum })),
        item.type === 'window' ? row(bind('Sill, m', number(), { ...prop(item, 'sill', 0.85), parse: parseNum }),
          bind('Head, m', number(), { ...prop(item, 'head', 2.1), parse: parseNum })) : null,
        h('p.note', 'Both points must lie on the same wall line (same X or same Z). Windows only show on the far walls; the walls facing the camera are cut away.')));
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
        row(bind('Name', text(), prop(item, 'name', '')), bind('Icon', choice(SCENE_ICONS), { ...prop(item, 'icon', 'sun'), event: 'change' }))),
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
    const key = `${sel.kind}:${sel.index ?? sel.service ?? ''}`;
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
    if ((ev.metaKey || ev.ctrlKey) && ev.key.toLowerCase() === 'z' && !typing) {
      ev.preventDefault();
      if (ev.shiftKey) stepHistory(redo, undo); else stepHistory(undo, redo);
    } else if ((ev.metaKey || ev.ctrlKey) && ev.key.toLowerCase() === 's') {
      ev.preventDefault();
      save();
    } else if ((ev.key === 'Backspace' || ev.key === 'Delete') && !typing && sel.index != null) {
      ev.preventDefault();
      remove(sel.kind, sel.index);
    } else if (ev.key.startsWith('Arrow') && !typing && sel.index != null) {
      const item = doc[KEYS[sel.kind]][sel.index];
      const target = item.pos || item.rect;
      if (!target) return;
      ev.preventDefault();
      const stepSize = ev.shiftKey ? 0.5 : 0.05;
      snapshot(`nudge${sel.kind}${sel.index}`);
      if (ev.key === 'ArrowLeft') target[0] = fix(target[0] - stepSize);
      if (ev.key === 'ArrowRight') target[0] = fix(target[0] + stepSize);
      if (ev.key === 'ArrowUp') target[1] = fix(target[1] - stepSize);
      if (ev.key === 'ArrowDown') target[1] = fix(target[1] + stepSize);
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
    const fitBtn = h('button.p-float', { 'aria-label': 'Show the whole plan', onclick: () => { ui.view = null; ui.applyView(); haptic('light'); } }, icon('fit', 18, 2));
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
      ['room', 'home', 'Room'], ['light', 'bulb', 'Lamp'], ['ac', 'ac', 'Air conditioner'],
      ['opening', 'opening', 'Door or window'], ['furniture', 'furniture', 'Furniture'], ['scene', 'sparkles', 'Scene'],
    ];
    addSheet.append(h('div.p-modal-head', h('b', 'Add to the plan'), h('button.p-text', { onclick: closeModals }, 'Cancel')),
      h('div.p-add-grid', addables.map(([kind, name, label]) => h('button.p-add-item', {
        onclick: () => { closeModals(); add(kind); haptic('light'); ui.reveal(); },
      }, icon(name, 24, 1.8), h('span', label)))));
    confirmSheet.append(h('div.p-modal-head', h('b', 'Unsaved changes')),
      h('p.note', 'Save them before closing? Saved plans reach your paired Mac too.'),
      h('div.p-confirm-actions',
        h('button.btn.primary.wide', { onclick: async () => { closeModals(); await save(); if (!dirty) close(); } }, 'Save and close'),
        h('button.btn.wide.danger', { onclick: () => { closeModals(); dirty = false; close(); } }, 'Discard changes'),
        h('button.btn.wide', { onclick: closeModals }, 'Keep editing')));

    sheet.append(grip, inspector);
    canvas.append(plan, h('div.p-preview', previewHost, previewToggle), issue, fitBtn, hint);
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
    const startGrip = (ev) => {
      if (ev.target.closest('button, input, select, textarea, a')) return;
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

    /* the plan's view: a box in plan metres with the element's aspect, or null to fit */
    function fitBox() {
      const b = bounds();
      const rect = plan.getBoundingClientRect();
      const W = rect.width || 390;
      const H = rect.height || 600;
      // Clear of the fit button on top, a little air on the other sides.
      const pad = { top: 64, side: 18, bottom: 18 };
      const scale = Math.min((W - pad.side * 2) / (b.maxX - b.minX), (H - pad.top - pad.bottom) / (b.maxZ - b.minZ));
      const w = W / scale;
      const hh = H / scale;
      const midY = pad.top + (H - pad.top - pad.bottom) / 2;
      return { x: (b.minX + b.maxX) / 2 - w / 2, y: (b.minZ + b.maxZ) / 2 - midY / scale, w, h: hh };
    }
    new ResizeObserver(() => ui.applyView()).observe(plan);

    // One finger on what is selected drags it; anywhere else it pans, and a tap picks.
    // Two fingers pinch to zoom.
    const fingers = new Map();
    let gesture = null;
    const box = () => ui.view || fitBox();
    const spread = () => { const [a, b] = [...fingers.values()]; return Math.hypot(a.x - b.x, a.y - b.y); };
    const middle = () => { const [a, b] = [...fingers.values()]; return { x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 }; };

    plan.addEventListener('pointerdown', (ev) => {
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
      if (kind === 'resize' || (kind && kind !== 'none' && isSel(kind, index)) || (inRoom && kind !== 'light' && kind !== 'ac')) {
        const what = kind === 'resize' || isSel(kind, index) ? [kind, index] : ['room', sel.index];
        // The view holds still while something is dragged past the plan's edge.
        if (!ui.view) ui.view = fitBox();
        startDrag(what[0], what[1], ev);
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
        ui.view = { x: gesture.at.x - (mid.x - rect.left) * w / rect.width, y: gesture.at.y - (mid.y - rect.top) * hh / rect.height, w, h: hh };
        ui.applyView();
      } else if (gesture.type === 'pan') {
        const dx = ev.clientX - gesture.x;
        const dy = ev.clientY - gesture.y;
        if (!gesture.moved && Math.hypot(dx, dy) < 8) return;
        gesture.moved = true;
        const v = gesture.v0;
        ui.view = { ...v, x: v.x - dx * v.w / rect.width, y: v.y - dy * v.h / rect.height };
        ui.applyView();
      }
    });

    const lift = (ev) => {
      if (!fingers.delete(ev.pointerId)) return;
      if (!gesture) return;
      if (gesture.type === 'drag') { endDrag(); gesture = null; return; }
      if (gesture.type === 'pinch') {
        // One finger stays down: it carries on panning from here.
        const [rest] = [...fingers.values()];
        gesture = rest ? { type: 'pan', x: rest.x, y: rest.y, v0: box(), moved: true } : null;
        return;
      }
      if (gesture.type === 'pan' && !gesture.moved && ev.type === 'pointerup') {
        const { kind, index } = gesture;
        if (kind && kind !== 'none' && kind !== 'resize') { haptic('light'); select({ kind, index }); }
        else if (ui.sheet !== 'closed') closeSheet();
      }
      gesture = null;
    };
    plan.addEventListener('pointerup', lift);
    plan.addEventListener('pointercancel', lift);

    const ui = {
      view: null,
      sheet: 'closed',
      show3D: false,
      applyView() {
        if (ui.view) {
          // The plan's box changed shape (the sheet came up): keep the middle and the zoom.
          const rect = plan.getBoundingClientRect();
          const hh = rect.width ? ui.view.w * rect.height / rect.width : ui.view.h;
          ui.view = { ...ui.view, y: ui.view.y + (ui.view.h - hh) / 2, h: hh };
        }
        const v = ui.view || fitBox();
        plan.setAttribute('viewBox', `${v.x} ${v.y} ${v.w} ${v.h}`);
      },
      // Something was picked (on the plan, in the list, in 3D): its details come up.
      selected(next) {
        closeModals();
        if (next.kind === 'connections' || next.kind === 'service') setSheet('full');
        else if (next.kind !== 'home' && ui.sheet === 'closed') setSheet('peek');
      },
      // The item just added may lie outside what is shown: show everything again.
      reveal() { ui.view = null; ui.applyView(); },
      headActions() {
        const nodes = [];
        if (sel.index != null) {
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
  // A plan saved on the other device (the Mac, or the paired iPhone) while this editor is open.
  incoming.planArrived = (config, from) => {
    if (dirty) {
      toast(`${from || 'Your other device'} saved a newer plan. Saving here replaces it.`, true);
      return;
    }
    doc = structuredClone(config);
    for (const key of Object.values(KEYS)) doc[key] ||= [];
    nameInput.value = doc.name || 'Home';
    if (sel.index != null && !doc[KEYS[sel.kind]]?.[sel.index]) sel = { kind: 'home' };
    touch();
    dirty = false;
    validate();
    toast(`Updated from ${from || 'your other device'}`);
  };

  window.__editor = { get doc() { return doc; }, select, tuya, links, phone };
  post('ready');
}
