import { haptic } from '../bridge.js';
import { t } from '../i18n.js';

// Minimal hyperscript helper: h('div.class', { onclick, style, ... }, ...children)
export function h(spec, props, ...children) {
  const [tag, ...classes] = spec.split('.');
  const el = document.createElement(tag || 'div');
  if (classes.length) el.className = classes.join(' ');
  if (props && (props instanceof Node || typeof props !== 'object' || Array.isArray(props))) {
    children.unshift(props);
    props = null;
  }
  for (const [k, v] of Object.entries(props || {})) {
    if (v == null || v === false) continue;
    if (k.startsWith('on')) el.addEventListener(k.slice(2), v);
    else if (k === 'style') Object.assign(el.style, v);
    else if (k === 'vars') for (const [name, val] of Object.entries(v)) el.style.setProperty(name, val);
    else el.setAttribute(k, v === true ? '' : v);
  }
  for (const c of children.flat(Infinity)) {
    if (c == null || c === false) continue;
    el.append(c instanceof Node ? c : document.createTextNode(String(c)));
  }
  return el;
}

/**
 * A (translated) text as children for h(): `**…**` around the parts drawn in bold, and
 * `{name}` placeholders filled with the nodes in `nodes` (an <em> example, say):
 *   richText(t('Add what you want: {example}.'), { example: h('em', t('“dim the lights”')) })
 */
export function richText(text, nodes = {}) {
  const out = [];
  String(text).split(/\*\*(.+?)\*\*/).forEach((piece, i) => {
    if (i % 2) { out.push(h('b', piece)); return; }
    piece.split(/\{(\w+)\}/).forEach((bit, j) => {
      if (j % 2) out.push(bit in nodes ? nodes[bit] : `{${bit}}`);
      else if (bit) out.push(bit);
    });
  });
  return out;
}

export const clamp = (v, a, b) => Math.min(b, Math.max(a, v));

// A slider or the colour pad on a sheet that scrolls (style.css gives them `touch-action: pan-y`
// there): a touch decides what it is by its first few pixels. Up or down first, it is the sheet
// being scrolled, and the browser takes it (pointercancel) without the value changing; sideways
// first, it drags the value; a tap sets it where it landed. Anywhere else (a mouse, a sheet that
// fits) a touch takes the value at once, as before.
const DECIDE_PX = 8;
function dragGesture(el, { start, move, end }) {
  let g = null;
  const take = (ev) => { g.taken = true; try { el.setPointerCapture(ev.pointerId); } catch { /* a nicety */ } start(ev); };
  el.addEventListener('pointerdown', (ev) => {
    if (ev.button !== 0 && ev.pointerType === 'mouse') return;
    const waits = ev.pointerType === 'touch' && getComputedStyle(el).touchAction.includes('pan-y');
    g = { id: ev.pointerId, x: ev.clientX, y: ev.clientY, taken: false };
    if (!waits) take(ev);
  });
  el.addEventListener('pointermove', (ev) => {
    if (!g || ev.pointerId !== g.id) return;
    if (g.taken) { move(ev); return; }
    const dx = Math.abs(ev.clientX - g.x);
    const dy = Math.abs(ev.clientY - g.y);
    if (Math.max(dx, dy) < DECIDE_PX) return;
    if (dx > dy) { take(ev); move(ev); } else g = null; // a scroll: the value is left alone
  });
  el.addEventListener('pointerup', (ev) => {
    if (!g || ev.pointerId !== g.id) return;
    if (!g.taken) start(ev); // a tap
    g = null;
    end();
  });
  el.addEventListener('pointercancel', (ev) => {
    if (!g || ev.pointerId !== g.id) return;
    const { taken } = g;
    g = null;
    if (taken) end();
  });
  // Once the value has the touch, the sheet must not start scrolling under it.
  el.addEventListener('touchmove', (ev) => { if (g?.taken && ev.cancelable) ev.preventDefault(); }, { passive: false });
}

// Horizontal slider with a gradient fill that reveals under a chunky thumb.
// `detent` is how far the value travels between two haptic ticks on a phone.
export function createSlider({ min, max, step = 1, value, gradient, compact = false, labels, onInput, detent = step }) {
  const fill = h('div.slider-fill');
  const thumb = h('div.slider-thumb');
  const track = h('div.slider-track', { vars: { '--gradient': gradient } }, fill, thumb);
  const el = h(`div.slider${compact ? '.compact' : ''}`, track,
    labels ? h('div.slider-scale', h('span', labels[0]), h('span', labels[1])) : null);

  let current = value;
  let notch = Math.round(value / detent);
  const input = (next) => {
    current = next;
    paint();
    const at = Math.round(next / detent);
    if (at !== notch) { notch = at; haptic('tick'); }
    onInput(current);
  };
  const paint = () => {
    el.style.setProperty('--p', String(clamp((current - min) / (max - min), 0, 1)));
  };
  new ResizeObserver(() => el.style.setProperty('--track-w', `${track.clientWidth}px`)).observe(track);

  const fromEvent = (ev) => {
    const r = track.getBoundingClientRect();
    const size = r.height; // the thumb is square
    const p = clamp((ev.clientX - r.left - size / 2) / (r.width - size), 0, 1);
    const raw = min + p * (max - min);
    return clamp(Math.round(raw / step) * step, min, max);
  };

  const follow = (ev) => {
    const next = fromEvent(ev);
    if (next !== current) input(next);
  };
  dragGesture(track, {
    start: (ev) => { el.classList.add('dragging'); follow(ev); },
    move: follow,
    end: () => el.classList.remove('dragging'),
  });

  paint();
  return {
    el,
    set(v) { if (v !== current && !el.classList.contains('dragging')) { current = v; notch = Math.round(v / detent); paint(); } },
  };
}

// Popup menu anchored to an element, opening upwards (the tiles sit at the bottom of the card).
export function openMenu(host, anchor, items, { onClose, title } = {}) {
  const menu = h('div.menu', { role: 'menu' });
  if (title) menu.append(h('div.menu-title', title));
  let closed = false;
  const close = () => {
    if (closed) return;
    closed = true;
    document.removeEventListener('pointerdown', outside, true);
    document.removeEventListener('keydown', onKey, true);
    menu.classList.add('closing');
    setTimeout(() => menu.remove(), 150);
    onClose?.();
  };
  const outside = (ev) => {
    if (menu.contains(ev.target)) return;
    if (anchor.contains(ev.target)) ev.stopPropagation(); // the click that would re-open it
    close();
  };
  const onKey = (ev) => { if (ev.key === 'Escape') { ev.stopPropagation(); close(); } };

  for (const item of items) {
    if (item === '-') { menu.append(h('hr')); continue; }
    menu.append(h(`button${item.selected ? '.selected' : ''}`, {
      onclick: () => { close(); item.action(); },
    }, h('span', item.label), item.icon));
  }

  host.append(menu);
  const hr = host.getBoundingClientRect();
  const ar = anchor.getBoundingClientRect();
  const mw = menu.offsetWidth;
  const mh = menu.offsetHeight;
  const below = ar.top - hr.top < mh + 16;
  const left = clamp(ar.right - hr.left - mw, 10, hr.width - mw - 10);
  menu.style.left = `${left}px`;
  menu.style.top = below ? `${ar.bottom - hr.top + 8}px` : `${ar.top - hr.top - mh - 8}px`;
  const ox = clamp(((ar.left + ar.width / 2 - hr.left - left) / mw) * 100, 10, 90);
  menu.style.setProperty('--origin', `${ox}% ${below ? '0%' : '100%'}`);

  setTimeout(() => {
    document.addEventListener('pointerdown', outside, true);
    document.addEventListener('keydown', onKey, true);
  }, 0);
  return close;
}

/* ---------- colour helpers + picker ---------- */

export function hexToHsv(hex) {
  const n = parseInt(String(hex).replace('#', ''), 16);
  if (Number.isNaN(n)) return null;
  const r = ((n >> 16) & 255) / 255;
  const g = ((n >> 8) & 255) / 255;
  const b = (n & 255) / 255;
  const max = Math.max(r, g, b);
  const d = max - Math.min(r, g, b);
  let hue = 0;
  if (d > 0) {
    if (max === r) hue = ((g - b) / d) % 6;
    else if (max === g) hue = (b - r) / d + 2;
    else hue = (r - g) / d + 4;
    hue = (hue * 60 + 360) % 360;
  }
  return { h: hue, s: max === 0 ? 0 : d / max, v: max };
}

export function hsvToHex(hue, s, v = 1) {
  const f = (k) => {
    const x = (k + hue / 60) % 6;
    return Math.round((v - v * s * Math.max(0, Math.min(x, 4 - x, 1))) * 255).toString(16).padStart(2, '0');
  };
  return `#${f(5)}${f(3)}${f(1)}`;
}

// Hue runs left to right, saturation fades towards white at the bottom.
// Brightness is not part of the pad: the lamp's own brightness slider owns it.
const PAD_MIN_SAT = 0.12;

export function createColorPad({ value, onInput }) {
  const thumb = h('div.pad-thumb');
  const el = h('div.pad', { role: 'slider', tabindex: 0, 'aria-label': t('Colour') }, thumb);
  let dragging = false;

  const place = (x, y, hex) => {
    el.classList.remove('empty');
    thumb.style.left = `${x * 100}%`;
    thumb.style.top = `${y * 100}%`;
    thumb.style.background = hex;
  };
  const show = (hex) => {
    const c = hex && hexToHsv(hex);
    if (!c) { el.classList.add('empty'); return; }
    place(c.h / 360, clamp((1 - c.s) / (1 - PAD_MIN_SAT), 0, 1), hsvToHex(c.h, c.s, 1));
  };
  const pick = (ev) => {
    const r = el.getBoundingClientRect();
    const x = clamp((ev.clientX - r.left) / r.width, 0, 1);
    const y = clamp((ev.clientY - r.top) / r.height, 0, 1);
    const hex = hsvToHex(Math.min(359.9, x * 360), 1 - y * (1 - PAD_MIN_SAT), 1);
    place(x, y, hex);
    onInput(hex);
  };

  dragGesture(el, {
    start: (ev) => { dragging = true; el.classList.add('dragging'); pick(ev); },
    move: pick,
    end: () => { dragging = false; el.classList.remove('dragging'); },
  });
  el.addEventListener('keydown', (ev) => {
    const step = { ArrowLeft: [-0.02, 0], ArrowRight: [0.02, 0], ArrowUp: [0, -0.05], ArrowDown: [0, 0.05] }[ev.key];
    if (!step) return;
    ev.preventDefault();
    const x = clamp((parseFloat(thumb.style.left) || 0) / 100 + step[0], 0, 1);
    const y = clamp((parseFloat(thumb.style.top) || 0) / 100 + step[1], 0, 1);
    const hex = hsvToHex(Math.min(359.9, x * 360), 1 - y * (1 - PAD_MIN_SAT), 1);
    place(x, y, hex);
    onInput(hex);
  });

  show(value);
  return { el, set(hex) { if (!dragging) show(hex); } };
}
