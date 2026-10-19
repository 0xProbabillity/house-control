// The island: a black tab that hangs from the MacBook's notch. At rest it shows how many
// lights are on; under the pointer it springs open into a small live model of the home
// with scenes and devices; when something changes elsewhere it peeks out to say so.
import './island.css';
import * as THREE from 'three';
import { loadConfig } from '../config.js';
import { createStore } from '../store.js';
import { createWorld } from '../three/world.js';
import { h, clamp } from '../ui/dom.js';
import { icon } from '../ui/icons.js';
import { lightColor } from '../three/lights.js';
import { MODE_COLORS } from '../three/ac.js';
import { post, incoming, isNative } from '../bridge.js';

const MODE_LABEL = { cool: 'Cool', heat: 'Heat', dry: 'Dry', fan: 'Fan', auto: 'Auto' };
const NAVY = new THREE.Color('#17274f');
const tmp = new THREE.Color();
const css = (c) => `#${c.getHexString()}`;
const PEEK_MS = 2400;

export async function bootIsland(root) {
  const boot = window.__HOUSE_BOOT__?.island || {};
  const query = new URLSearchParams(location.search);
  // The notch this island grows out of, in points. A screen without one gets a drawn tab.
  const notch = {
    w: boot.notchWidth ?? (Number(query.get('notch')) || 190),
    h: boot.notchHeight ?? 34,
    real: boot.hasNotch ?? false,
  };

  let config;
  try {
    config = await loadConfig();
  } catch (error) {
    console.error(error);
    post('ready', { error: String(error?.message || error) });
    return;
  }
  const store = createStore(config);
  const { state } = store;
  const roomName = new Map(config.rooms.map((r) => [r.id, r.name]));

  /* ---------- skeleton ---------- */

  const earLeft = h('div.ear.left');
  const earRight = h('div.ear.right');
  const canvas = h('canvas', { tabindex: -1 });
  const title = h('div.isle-title', h('span.isle-badge', icon('home', 14)), h('b', config.name));
  const status = h('div.isle-status');
  const power = h('button.isle-power', { 'aria-label': 'Everything on / off', onclick: toggleEverything }, icon('power', 15, 2.4));
  const scenes = h('div.isle-scenes');
  const list = h('div.isle-list');
  const body = h('div.isle-body',
    h('div.isle-head', title, h('i.isle-gap'), h('div.isle-right', status, power)),
    h('div.isle-main', h('div.isle-stage', canvas), h('div.isle-side', scenes, list)));
  const shape = h('div.isle-shape', earLeft, earRight, body);
  const isle = h('div.isle', h('div.isle-glow'), shape);
  isle.dataset.state = 'collapsed';
  isle.classList.toggle('real', notch.real);
  isle.style.setProperty('--notch-w', `${notch.w}px`);
  isle.style.setProperty('--notch-h', `${notch.h}px`);
  root.replaceChildren(isle);

  /* ---------- scenes ---------- */

  const sceneButtons = new Map();
  for (const s of config.scenes.slice(0, 5)) {
    const b = h('button.isle-scene', { onclick: () => store.applyScene(s.id) }, icon(s.icon, 17), h('span', s.name));
    sceneButtons.set(s.id, b);
    scenes.append(b);
  }
  if (!config.scenes.length) scenes.hidden = true;

  /* ---------- devices ---------- */

  const rows = [];

  for (const cfg of config.acs) {
    const sub = h('div.chip-sub');
    const value = h('span.chip-value');
    const bubble = h('span.chip-bubble');
    const step = (d) => (e) => { e.stopPropagation(); store.setAC(cfg.id, { on: true, target: state.acs[cfg.id].target + d }); };
    const el = h('div.chip.ac',
      bubble,
      h('div.chip-text', h('div.chip-name', cfg.name), sub),
      h('button.chip-step', { 'aria-label': 'Cooler', onclick: step(-1) }, icon('minus', 13, 2.4)),
      value,
      h('button.chip-step', { 'aria-label': 'Warmer', onclick: step(1) }, icon('plus', 13, 2.4)),
      h('button.chip-power', { 'aria-label': `${cfg.name} power`, onclick: () => store.setAC(cfg.id, { on: !state.acs[cfg.id].on }) }, icon('power', 13, 2.4)));
    let shownMode = null;
    list.append(el);
    rows.push(() => {
      const s = state.acs[cfg.id];
      el.classList.toggle('on', s.on);
      el.classList.toggle('idle', s.on && s.idle);
      el.style.setProperty('--c', MODE_COLORS[s.mode]);
      if (shownMode !== s.mode) { bubble.replaceChildren(icon(s.mode, 15)); shownMode = s.mode; }
      value.textContent = `${s.target}°`;
      sub.textContent = `${!s.on ? 'Off' : s.idle ? 'Idle' : MODE_LABEL[s.mode]} · ${s.roomTemp.toFixed(0)}° inside`;
    });
  }

  for (const cfg of config.lights) {
    const dimmable = cfg.capabilities.includes('brightness');
    const sub = h('div.chip-sub');
    const el = h(`div.chip.light${dimmable ? '.dimmable' : ''}`, { role: 'button', 'aria-label': cfg.name },
      h('span.chip-bubble', icon(cfg.capabilities.length ? cfg.type : 'plug', 15)),
      h('div.chip-text', h('div.chip-name', cfg.name), sub),
      h('i.chip-level'));
    // Click toggles, dragging sideways dims: the same gesture as the panel's tiles.
    let gesture = null;
    el.addEventListener('pointerdown', (ev) => {
      if (ev.button !== 0) return;
      el.setPointerCapture(ev.pointerId);
      const s = state.lights[cfg.id];
      gesture = { x: ev.clientX, start: s.on ? s.brightness : 0, moved: false };
      el.classList.add('pressed');
    });
    el.addEventListener('pointermove', (ev) => {
      if (!gesture) return;
      const dx = ev.clientX - gesture.x;
      if (!gesture.moved && dimmable && Math.abs(dx) > 5) gesture.moved = true;
      if (gesture.moved) {
        const b = clamp(gesture.start + dx / el.clientWidth, 0, 1);
        store.setLight(cfg.id, b < 0.04 ? { on: false } : { on: true, brightness: b });
      }
    });
    const finish = (ev) => {
      if (!gesture) return;
      const tapped = !gesture.moved && ev.type === 'pointerup';
      gesture = null;
      el.classList.remove('pressed');
      if (tapped) { world?.lights.get(cfg.id)?.bump(); store.toggleLight(cfg.id); }
    };
    el.addEventListener('pointerup', finish);
    el.addEventListener('pointercancel', finish);
    list.append(el);
    rows.push(() => {
      const s = state.lights[cfg.id];
      el.classList.toggle('on', s.on);
      el.style.setProperty('--c', css(lightColor(s, tmp)));
      el.style.setProperty('--level', s.on ? String(s.brightness) : '0');
      sub.textContent = `${lightLabel(cfg, s)} · ${roomName.get(cfg.room)}`;
    });
  }

  function lightLabel(cfg, s) {
    if (!s.on) return 'Off';
    return cfg.capabilities.includes('brightness') ? `${Math.round(s.brightness * 100)}%` : 'On';
  }

  function toggleEverything() {
    const anyOn = Object.values(state.lights).some((l) => l.on) || Object.values(state.acs).some((a) => a.on);
    if (anyOn) {
      store.setAllLights(false);
      for (const id of Object.keys(state.acs)) store.setAC(id, { on: false });
    } else {
      store.setAllLights(true);
    }
  }

  /* ---------- the model ---------- */

  let world = null;
  let focused = null;
  try {
    world = createWorld(canvas, config, store, {
      background: '#000000',
      onHover: () => {},
      onPick(target) {
        if (!target) return;
        if (target.kind === 'light') store.toggleLight(target.id);
        else if (target.kind === 'ac') store.setAC(target.id, { on: !state.acs[target.id].on });
        else if (target.kind === 'room') {
          focused = focused === target.id ? null : target.id;
          world.focus(focused ? { kind: 'room', id: focused } : null);
        }
      },
    });
    world.setInsets(0, 0);
    new ResizeObserver(() => world.resize()).observe(canvas);
  } catch (error) {
    console.error(error); // no WebGL: the island still works as a remote
  }

  /* ---------- what it shows ---------- */

  function mood() {
    const sum = new THREE.Color(0, 0, 0);
    let weight = 0;
    for (const cfg of config.lights) {
      const s = state.lights[cfg.id];
      if (!s.on) continue;
      const w = cfg.capabilities.includes('brightness') ? s.brightness : 1;
      lightColor(s, tmp);
      sum.r += tmp.r * w; sum.g += tmp.g * w; sum.b += tmp.b * w;
      weight += w;
    }
    if (!weight) return NAVY.clone();
    sum.multiplyScalar(0.6 / weight);
    return NAVY.clone().lerp(sum, clamp(weight / 3, 0.35, 0.9));
  }

  const plainEar = (iconName, text, color) => [h('span.ear-icon', { vars: { '--c': color } }, icon(iconName, 14, 2.2)), text != null ? h('span.ear-text', text) : null];

  let peek = null; // { left: [...nodes], right: text } while something is being announced

  function update() {
    const lights = Object.values(state.lights);
    const onCount = lights.filter((l) => l.on).length;
    const acOn = config.acs.map((a) => state.acs[a.id]).find((a) => a.on);
    const m = css(mood());
    isle.style.setProperty('--mood', m);
    isle.classList.toggle('quiet', onCount === 0 && !acOn);

    if (isle.dataset.state === 'peek' && peek) {
      earLeft.replaceChildren(...peek.left);
      earRight.replaceChildren(h('span.ear-text.strong', peek.right));
    } else {
      earLeft.replaceChildren(...(onCount ? plainEar('home', String(onCount), '#ffb46b') : acOn ? plainEar('home', null, '#8fa3c7') : []));
      earRight.replaceChildren(...(acOn ? plainEar(acOn.mode, `${acOn.target}°`, MODE_COLORS[acOn.mode]) : []));
    }

    status.replaceChildren(
      h('i.dot', { style: onCount || acOn ? {} : { background: 'rgba(255,255,255,.25)', boxShadow: 'none' } }),
      h('b', onCount ? `${onCount} of ${lights.length}` : 'No'), ' lights on', acOn ? ` · ${acOn.target}°` : '');
    power.classList.toggle('on', onCount > 0 || Boolean(acOn));
    for (const [id, b] of sceneButtons) b.classList.toggle('active', state.scene === id);
    for (const row of rows) row();
  }

  /* ---------- states ---------- */

  let peekTimer = 0;
  let introTimer = 0;

  function setState(next) {
    if (isle.dataset.state === next) return;
    const was = isle.dataset.state;
    isle.dataset.state = next;
    body.inert = next !== 'expanded';
    if (next === 'expanded') {
      clearTimeout(peekTimer);
      peek = null;
      world?.setRunning(true);
      // The model sweeps in and its lamps come on once the island has room for it, so
      // the first frames of the spring do not have to wait for the 3D renderer.
      // (With Reduce Motion the camera does not sweep: the model is simply there.)
      if (was !== 'expanded' && !matchMedia('(prefers-reduced-motion: reduce)').matches) {
        clearTimeout(introTimer);
        introTimer = setTimeout(() => world?.intro(), 110);
      }
    } else if (was === 'expanded') {
      // Keep drawing while the island closes over the model, then rest.
      setTimeout(() => { if (isle.dataset.state !== 'expanded') world?.setRunning(false); }, 500);
      if (focused) { focused = null; world?.focus(null); }
    }
    update();
  }

  // Says what just changed somewhere else, unless the island is open (then you see it anyway).
  function announce(before, source) {
    if (isle.dataset.state === 'expanded') return;
    const news = describe(before, source);
    if (!news) return;
    peek = news;
    setState('peek');
    update();
    clearTimeout(peekTimer);
    peekTimer = setTimeout(() => { peek = null; if (isle.dataset.state === 'peek') setState('collapsed'); }, PEEK_MS);
  }

  // A change an AI assistant made (AI Access) wears its sparkles instead of the device's icon.
  function describe(before, source) {
    const ear = (iconName, text, color) => (source ? plainEar('sparkles', text, '#c3b2ff') : plainEar(iconName, text, color));
    if (state.scene && state.scene !== before.scene) {
      const s = config.scenes.find((x) => x.id === state.scene);
      if (s) return { left: ear(s.icon, s.name, '#a9cbff'), right: 'Scene' };
    }
    const lights = config.lights.filter((l) => {
      const [a, b] = [before.lights[l.id], state.lights[l.id]];
      return a && (a.on !== b.on || Math.abs(a.brightness - b.brightness) > 0.02 || a.color !== b.color);
    });
    const acs = config.acs.filter((c) => {
      const [a, b] = [before.acs[c.id], state.acs[c.id]];
      return a && (a.on !== b.on || a.target !== b.target || a.mode !== b.mode);
    });
    if (acs.length === 1 && !lights.length) {
      const [cfg, s] = [acs[0], state.acs[acs[0].id]];
      return { left: ear(s.mode, cfg.name, s.on ? MODE_COLORS[s.mode] : '#8fa3c7'), right: s.on ? `${s.target}°` : 'Off' };
    }
    if (lights.length === 1 && !acs.length) {
      const [cfg, s] = [lights[0], state.lights[lights[0].id]];
      return { left: ear(cfg.capabilities.length ? cfg.type : 'plug', cfg.name, s.on ? css(lightColor(s, tmp)) : '#8fa3c7'), right: lightLabel(cfg, s) };
    }
    if (lights.length + acs.length > 1) {
      const on = Object.values(state.lights).filter((l) => l.on).length;
      return { left: ear('home', config.name, on ? '#ffb46b' : '#8fa3c7'), right: on ? `${on} on` : 'All off' };
    }
    return null;
  }

  const copy = () => JSON.parse(JSON.stringify({ lights: state.lights, acs: state.acs, scene: state.scene }));
  let last = copy();
  store.on((change) => {
    if (change.type === 'tick') { for (const row of rows) row(); return; }
    const before = last;
    last = copy();
    update();
    if (change.remote) announce(before, change.source);
  });

  incoming.islandState = (next) => setState(next === 'expanded' ? 'expanded' : 'collapsed');
  incoming.adopt = (other) => store.adopt(other);
  incoming.applyRemote = (remote) => store.applyRemote(remote);

  // The order the parts of the open island come in: header, model, scenes, devices.
  const stagger = (el, ms) => { el.classList.add('reveal'); el.style.setProperty('--d', `${Math.round(ms)}ms`); };
  stagger(body.querySelector('.isle-head'), 60);
  stagger(body.querySelector('.isle-stage'), 90);
  [...scenes.children].forEach((el, i) => stagger(el, 130 + i * 30));
  [...list.children].forEach((el, i) => stagger(el, 190 + Math.min(i, 9) * 24));

  body.inert = true;
  update();
  if (window.__HOUSE_BOOT__?.island?.expanded || query.get('expanded')) setState('expanded');
  // Without the native shell (vite dev) the pointer drives it, so the page can be worked on.
  if (!isNative) {
    shape.addEventListener('pointerenter', () => setState('expanded'));
    shape.addEventListener('pointerleave', () => setState('collapsed'));
  }
  post('ready', { summary: store.summary() });
  window.__house = { store, world, config, island: { setState, announce } };
}
