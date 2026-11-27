// The 3D stage: renderer, camera rig, picking and the per-frame animation loop.
import * as THREE from 'three';
import { EffectComposer } from 'three/addons/postprocessing/EffectComposer.js';
import { RenderPass } from 'three/addons/postprocessing/RenderPass.js';
import { UnrealBloomPass } from 'three/addons/postprocessing/UnrealBloomPass.js';
import { OutputPass } from 'three/addons/postprocessing/OutputPass.js';
import { buildHouse } from './house.js';
import { buildFurniture } from './furniture.js';
import { LightUnit } from './lights.js';
import { ACUnit } from './ac.js';

export const STAGE_BG = '#0a0e1a';

const rad = THREE.MathUtils.degToRad;
const clamp = THREE.MathUtils.clamp;
const EL_MIN = 6;          // almost level with the floor
const EL_MAX = 89;         // straight down, short of where "up" stops meaning anything
const ZOOM_MIN = 0.3;      // closest
const ZOOM_MAX = 1.2;
const PAN_MARGIN = 1;      // metres the view's centre may go past the edge of the floor
const PAN_TILT_MIN = 0.35; // keeps a two-finger drag sane when looking almost along the floor

export function createWorld(canvas, config, store, { onHover, onPick, onLevel = () => {}, onView = () => {}, level: firstLevel, background = STAGE_BG }) {
  const renderer = new THREE.WebGLRenderer({ canvas, antialias: false, alpha: false, powerPreference: 'high-performance' });
  renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2));
  renderer.toneMapping = THREE.ACESFilmicToneMapping;
  renderer.toneMappingExposure = 1.05;
  renderer.shadowMap.enabled = true;
  renderer.shadowMap.type = THREE.PCFShadowMap;
  renderer.shadowMap.autoUpdate = false; // the model is static: shadow maps are rendered once

  const scene = new THREE.Scene();
  scene.background = new THREE.Color(background);

  const camera = new THREE.PerspectiveCamera(24, 1, 0.5, 120);

  const { minX, minZ, maxX, maxZ } = config.bounds;
  const center = new THREE.Vector3((minX + maxX) / 2, 0, (minZ + maxZ) / 2);
  const span = Math.max(maxX - minX, maxZ - minZ);
  // A home on several floors shows one at a time, with the floors under it: `level` is it.
  const levelById = new Map(config.levels.map((l) => [l.id, l]));
  let level = levelById.get(firstLevel) || config.levels[0];

  const baseAz = config.camera.azimuth;
  const baseEl = config.camera.elevation;

  /* ---------- content ---------- */

  let shadowFrames = 3; // shadow maps are rendered again for this many frames
  let wallsMoved = false; // the lamps' shadow maps are out of date
  const floors = new Map(); // level id -> { group, house }
  for (const l of config.levels) {
    const group = new THREE.Group();
    group.position.y = l.elevation;
    const house = buildHouse(config, l);
    group.add(house.group, buildFurniture(config.furniture.filter((f) => f.level === l.id)));
    scene.add(group);
    floors.set(l.id, { group, house });
  }

  const lights = new Map();
  // A lamp's shadows only change when the walls do, and they are the costly ones: six faces a
  // lamp. They are drawn on request, the moon's whenever any shadow map is.
  const lampShadows = [];
  for (const cfg of config.lights) {
    const unit = new LightUnit(cfg, levelById.get(cfg.level).wallHeight);
    lights.set(cfg.id, unit);
    floors.get(cfg.level).group.add(unit.group);
    for (const l of unit.lights) {
      if (l.userData.canShadow) { l.shadow.autoUpdate = false; lampShadows.push(l.shadow); }
    }
  }

  // Every shadow-casting lamp costs the shader a texture sampler, and WebGL caps how many
  // one program may use (16 on Apple GPUs — and the moonlight takes one of them too). Past
  // the cap the program no longer links, three.js logs `useProgram: program not valid` on
  // every draw and the whole stage renders black. The bundled demo plans have 11 lamps, so
  // this only shows up on a real floor plan. Give the most important lamps the shadow slots
  // and let the rest light the room without casting.
  const SHADOW_PRIORITY = { ceiling: 0, pendant: 1, floor: 2, spots: 3, table: 4, strip: 9 };
  const canShadow = (unit) => unit.lights.some((l) => l.userData.canShadow);
  const shadowCap = Math.max(1, Math.min(8, renderer.capabilities.maxTextures - 6));
  // Only the floor on show lights its rooms, so the slots go to its lamps.
  function assignShadows() {
    const ranked = [...lights.values()].filter((u) => u.cfg.level === level.id).sort((a, b) =>
      (SHADOW_PRIORITY[a.cfg.type] ?? 9) - (SHADOW_PRIORITY[b.cfg.type] ?? 9));
    // One lamp per room first, so every room keeps some depth, then fill up to the cap.
    const shadowOrder = [];
    const seenRooms = new Set();
    for (const unit of ranked) {
      if (shadowOrder.length >= shadowCap) break;
      if (canShadow(unit) && !seenRooms.has(unit.cfg.room)) { shadowOrder.push(unit); seenRooms.add(unit.cfg.room); }
    }
    for (const unit of ranked) {
      if (shadowOrder.length >= shadowCap) break;
      if (canShadow(unit) && !shadowOrder.includes(unit)) shadowOrder.push(unit);
    }
    for (const unit of lights.values()) {
      const keep = shadowOrder.includes(unit);
      for (const l of unit.lights) if (l.userData.canShadow) l.castShadow = keep;
    }
  }

  const acs = new Map();
  for (const cfg of config.acs) {
    const unit = new ACUnit(cfg);
    acs.set(cfg.id, unit);
    floors.get(cfg.level).group.add(unit.group);
  }
  let hitTargets = [];

  // The floors above the one on show are lifted off; the ones under it stay, unlit, as its base.
  function showLevel() {
    for (const [id, { group }] of floors) group.visible = levelById.get(id).elevation <= level.elevation;
    for (const unit of [...lights.values(), ...acs.values()]) unit.group.visible = unit.cfg.level === level.id;
    hitTargets = [
      ...[...lights.values()].filter((u) => u.group.visible).map((u) => u.hit),
      ...[...acs.values()].filter((u) => u.group.visible).map((u) => u.hit),
      ...floors.get(level.id).house.floors,
    ];
    assignShadows();
    moon.target.position.set(center.x, level.elevation, center.z);
    shadowFrames = 3;
  }

  // The moon goes round with the camera, steep and from the viewer's side, so the faces we
  // look at stay readable. Its shadows catch up when the camera comes to rest.
  function placeMoon(az) {
    const a = rad(baseAz);
    const x = Math.sin(a) * 3.2 + 1.5;
    const z = Math.cos(a) * 3.2 - 1.5;
    const turn = rad(az - baseAz);
    const c = Math.cos(turn);
    const s = Math.sin(turn);
    moon.position.set(center.x + x * c + z * s, level.elevation + 10, center.z + z * c - x * s);
  }

  // Night-time ambience: enough to read the model with every lamp off.
  scene.add(new THREE.HemisphereLight(0x8ea6ff, 0x0b0e17, 0.42));
  const moon = new THREE.DirectionalLight(0xa9c0ff, 0.6);
  moon.castShadow = true;
  moon.shadow.mapSize.set(2048, 2048);
  const sc = moon.shadow.camera;
  sc.left = sc.bottom = -span * 0.85;
  sc.right = sc.top = span * 0.85;
  sc.near = 1;
  sc.far = 30;
  showLevel();
  moon.shadow.bias = -0.0008;
  moon.shadow.normalBias = 0.04;
  moon.shadow.radius = 4;
  scene.add(moon, moon.target);

  /* ---------- post-processing ---------- */

  const target = new THREE.WebGLRenderTarget(4, 4, { type: THREE.HalfFloatType, samples: 4 });
  const composer = new EffectComposer(renderer, target);
  composer.addPass(new RenderPass(scene, camera));
  const bloom = new UnrealBloomPass(new THREE.Vector2(4, 4), 0.34, 0.5, 1.0);
  composer.addPass(bloom);
  composer.addPass(new OutputPass());

  /* ---------- camera rig ---------- */

  const rig = {
    az: baseAz, el: baseEl, dist: 30, target: center.clone(),
    goal: { az: baseAz, el: baseEl, dist: 30, target: center.clone() },
    zoom: 1, focus: null,
    pan: new THREE.Vector3(), // the view's centre, moved off what it is framing
    framed: center.clone(),   // the centre of what it is framing
  };
  // Where the person has put the camera: a room is framed from this angle, and leaving a room
  // or a device goes back to this whole view.
  const home = { az: baseAz, el: baseEl, zoom: 1, pan: new THREE.Vector3() };
  // The same direction as `az`, the fewest degrees from `from`, so a full turn is not unwound.
  const nearestAz = (az, from) => from + ((((az - from) % 360) + 540) % 360) - 180;
  let width = 1;
  let height = 1;
  let topInset = 0;    // pixels at the top covered by the header
  let bottomInset = 0; // pixels at the bottom covered by the panel

  const v = new THREE.Vector3();
  const right = new THREE.Vector3();
  const up = new THREE.Vector3();
  const fwd = new THREE.Vector3();

  function basis(az, el) {
    const a = rad(az);
    const e = rad(el);
    fwd.set(-Math.sin(a) * Math.cos(e), -Math.sin(e), -Math.cos(a) * Math.cos(e));
    right.set(Math.cos(a), 0, -Math.sin(a));
    up.crossVectors(right, fwd);
  }

  // Smallest distance at which `box` fits the usable part of the viewport.
  function fitDistance(box, az, el, fill) {
    basis(az, el);
    const c = box.getCenter(new THREE.Vector3());
    const usableH = Math.max(0.3, (height - topInset - bottomInset) / height);
    const tanV = Math.tan(rad(camera.fov / 2)) * fill * usableH;
    const tanH = Math.tan(rad(camera.fov / 2)) * camera.aspect * fill;
    let dist = 0;
    for (let i = 0; i < 8; i++) {
      v.set(i & 1 ? box.max.x : box.min.x, i & 2 ? box.max.y : box.min.y, i & 4 ? box.max.z : box.min.z).sub(c);
      const depth = v.dot(fwd);
      dist = Math.max(dist, Math.abs(v.dot(right)) / tanH - depth, Math.abs(v.dot(up)) / tanV - depth);
    }
    return { dist, center: c };
  }

  function frameGoal() {
    const f = rig.focus;
    let box;
    let fill = 0.96;
    const y = level.elevation;
    const H = level.wallHeight;
    if (f?.kind === 'room') {
      const r = config.rooms.find((x) => x.id === f.id);
      box = new THREE.Box3(new THREE.Vector3(r.x, y, r.z), new THREE.Vector3(r.x + r.w, y + H * 0.75, r.z + r.d));
      fill = 0.84;
    } else if (f?.kind === 'ac') {
      const unit = acs.get(f.id);
      const p = unit.group.getWorldPosition(new THREE.Vector3());
      const out = new THREE.Vector3(0, 0, 1).applyQuaternion(unit.group.quaternion);
      box = new THREE.Box3().setFromCenterAndSize(
        new THREE.Vector3(p.x + out.x * 1.3, y + 1.25, p.z + out.z * 1.3), new THREE.Vector3(3.6, 2.6, 3.6));
      fill = 0.92;
    } else {
      const b = level.bounds;
      box = new THREE.Box3(new THREE.Vector3(b.minX, y, b.minZ), new THREE.Vector3(b.maxX, y + H * 0.8, b.maxZ));
    }
    const { dist, center: c } = fitDistance(box, rig.goal.az, rig.goal.el, fill);
    rig.goal.dist = dist * rig.zoom;
    rig.framed.copy(c);
    const b = level.bounds;
    rig.goal.target.copy(c).add(rig.pan);
    rig.goal.target.x = clamp(rig.goal.target.x, b.minX - PAN_MARGIN, b.maxX + PAN_MARGIN);
    rig.goal.target.z = clamp(rig.goal.target.z, b.minZ - PAN_MARGIN, b.maxZ + PAN_MARGIN);
    rig.pan.subVectors(rig.goal.target, c);
  }

  // Where on the floor a point `px, py` pixels off the view's centre lies, relative to that centre.
  function floorOffset(px, py, dist) {
    const a = rad(rig.goal.az);
    const scale = (2 * dist * Math.tan(rad(camera.fov / 2))) / height;
    const away = (-py * scale) / Math.max(PAN_TILT_MIN, Math.sin(rad(rig.goal.el)));
    return {
      x: Math.cos(a) * px * scale - Math.sin(a) * away,
      z: -Math.sin(a) * px * scale - Math.cos(a) * away,
    };
  }

  // Tells the page whether the camera is somewhere it can be sent back from.
  let viewMoved = false;
  function reportView() {
    const off = Math.abs(nearestAz(rig.goal.az, baseAz) - baseAz) > 1 || Math.abs(rig.goal.el - baseEl) > 1
      || Math.abs(rig.zoom - 1) > 0.01 || rig.pan.lengthSq() > 0.01;
    if (off !== viewMoved) { viewMoved = off; onView(off); }
  }

  // The person moved the camera: remember it, so it is still there after a room or a device.
  function userMoved() {
    if (rig.focus?.kind !== 'ac') { home.az = rig.goal.az; home.el = rig.goal.el; }
    if (!rig.focus) { home.zoom = rig.zoom; home.pan.copy(rig.pan); }
    reportView();
  }

  function updateRig(dt, instant = false) {
    // Two fingers move the model with them, so it stays under them; the rest glides.
    const held = pinch || magnify || performance.now() < wheelUntil;
    const k = instant ? 1 : 1 - Math.exp(-dt * (held ? 28 : 5.5));
    const g = rig.goal;
    const delta = Math.abs(g.az - rig.az) + Math.abs(g.el - rig.el) + Math.abs(g.dist - rig.dist) * 2
      + rig.target.distanceTo(g.target) * 4;
    rig.az += (g.az - rig.az) * k;
    rig.el += (g.el - rig.el) * k;
    rig.dist += (g.dist - rig.dist) * k;
    rig.target.lerp(g.target, k);
    basis(rig.az, rig.el);
    camera.position.copy(rig.target).addScaledVector(fwd, -rig.dist);
    camera.up.set(0, 1, 0);
    camera.lookAt(rig.target);
    const a = rad(rig.az);
    for (const { house } of floors.values()) house.view(Math.sin(a), Math.cos(a));
    placeMoon(rig.az);
    return delta > 0.002;
  }

  // The outer walls follow the camera. The shadows wait for it to stop, so turning never stutters.
  function updateWalls(dt) {
    let active = false;
    for (const { house } of floors.values()) {
      const state = house.update(dt);
      if (state) active = true;
      if (state === 'stopped') wallsMoved = true;
    }
    return active;
  }

  /* ---------- state sync ---------- */

  function syncAll(opts = {}) {
    let i = 0;
    for (const [id, unit] of lights) {
      unit.apply(store.state.lights[id], { ...opts, delay: opts.stagger ? 0.25 + i++ * 0.06 : 0 });
    }
    for (const [id, unit] of acs) unit.apply(store.state.acs[id], opts);
    wake();
  }

  const unsubscribe = store.on((change) => {
    if (change.type === 'tick') return;
    if (change.type === 'light') lights.get(change.id).apply(store.state.lights[change.id]);
    else if (change.type === 'ac') acs.get(change.id).apply(store.state.acs[change.id]);
    else syncAll();
    wake();
  });

  /* ---------- picking ---------- */

  const raycaster = new THREE.Raycaster();
  const ndc = new THREE.Vector2();
  let hovered = null;
  let drag = null;

  function pick(ev) {
    const r = canvas.getBoundingClientRect();
    ndc.set(((ev.clientX - r.left) / r.width) * 2 - 1, -((ev.clientY - r.top) / r.height) * 2 + 1);
    raycaster.setFromCamera(ndc, camera);
    const hits = raycaster.intersectObjects(hitTargets, false);
    if (!hits.length) return null;
    // Devices win over the floor they stand on.
    const device = hits.find((h) => h.object.userData.kind !== 'room');
    return (device || hits[0]).object.userData;
  }

  function unitOf(t) {
    return t?.kind === 'light' ? lights.get(t.id) : t?.kind === 'ac' ? acs.get(t.id) : null;
  }

  function screenAnchor(t) {
    const unit = unitOf(t);
    if (!unit) return null;
    unit.anchor(v).project(camera);
    return { x: (v.x * 0.5 + 0.5) * width, y: (-v.y * 0.5 + 0.5) * height };
  }

  function setHover(t) {
    const same = hovered?.kind === t?.kind && hovered?.id === t?.id;
    if (same) return;
    const prev = unitOf(hovered);
    if (prev) prev.hoverGoal = 0;
    hovered = t && t.kind !== 'room' ? t : null;
    const next = unitOf(hovered);
    if (next) next.hoverGoal = 1;
    canvas.style.cursor = hovered ? 'pointer' : drag?.moved ? 'grabbing' : 'grab';
    onHover(hovered ? { ...hovered, ...screenAnchor(hovered) } : null);
    wake();
  }

  // Two fingers move the model and pinch to zoom, keeping what is under them under them.
  // A mouse moves it the same way, with the right or middle button or Shift held.
  const fingers = new Map();
  let pinch = null;
  let magnify = null;  // a trackpad's pinch
  let wheelMode = null;
  let wheelAt = 0;
  let wheelUntil = 0;
  const pair = () => {
    const [a, b = a] = fingers.values();
    return [a, b];
  };
  const spread = () => {
    const [a, b] = pair();
    return Math.max(1, Math.hypot(a.x - b.x, a.y - b.y));
  };
  // A point of the window, in pixels off the centre of the view.
  const offCentre = (x, y) => {
    const r = canvas.getBoundingClientRect();
    return { x: x - r.left - width / 2, y: y - r.top - height / 2 - (topInset - bottomInset) / 2 };
  };
  const between = () => {
    const [a, b] = pair();
    return offCentre((a.x + b.x) / 2, (a.y + b.y) / 2);
  };
  // The spot on the floor at a point off the centre, and moving the view to put it back there.
  const spotAt = (m) => {
    const off = floorOffset(m.x, m.y, rig.goal.dist);
    return { x: rig.goal.target.x + off.x, z: rig.goal.target.z + off.z };
  };
  function holdSpot(spot, m) {
    const off = floorOffset(m.x, m.y, rig.goal.dist);
    rig.pan.set(spot.x - off.x - rig.framed.x, 0, spot.z - off.z - rig.framed.z);
    frameGoal();
    userMoved();
    wake();
  }
  function zoomTo(zoom, spot, m) {
    rig.zoom = clamp(zoom, ZOOM_MIN, ZOOM_MAX);
    frameGoal();
    holdSpot(spot, m);
  }
  function startPinch() {
    pinch = { fingers: Math.min(2, fingers.size), spread: spread(), zoom: rig.zoom, spot: spotAt(between()) };
  }
  const movePinch = () => zoomTo(pinch.zoom * pinch.spread / spread(), pinch.spot, between());

  canvas.addEventListener('pointerdown', (ev) => {
    canvas.setPointerCapture(ev.pointerId);
    fingers.set(ev.pointerId, { x: ev.clientX, y: ev.clientY });
    const mouseMoves = ev.pointerType === 'mouse' && (ev.button === 1 || ev.button === 2 || ev.shiftKey);
    if (fingers.size === 2 || mouseMoves) {
      startPinch();
      drag = null;
      setHover(null);
      if (mouseMoves) canvas.style.cursor = 'grabbing';
      return;
    }
    if (fingers.size > 2) return;
    drag = { x: ev.clientX, y: ev.clientY, az: rig.goal.az, el: rig.goal.el, moved: false };
  });
  canvas.addEventListener('pointermove', (ev) => {
    if (fingers.has(ev.pointerId)) fingers.set(ev.pointerId, { x: ev.clientX, y: ev.clientY });
    if (pinch) {
      if (fingers.size >= pinch.fingers) movePinch();
      return;
    }
    if (drag) {
      const dx = ev.clientX - drag.x;
      const dy = ev.clientY - drag.y;
      if (!drag.moved && Math.hypot(dx, dy) > 5) { drag.moved = true; setHover(null); canvas.style.cursor = 'grabbing'; }
      if (drag.moved) {
        rig.goal.az = drag.az - dx * 0.35;
        rig.goal.el = clamp(drag.el + dy * 0.3, EL_MIN, EL_MAX);
        frameGoal();
        userMoved();
        wake();
      }
      return;
    }
    setHover(pick(ev));
  });
  const release = (ev) => {
    fingers.delete(ev.pointerId);
    if (pinch) { // lifting after a pinch picks nothing
      if (!fingers.size) { pinch = null; canvas.style.cursor = 'grab'; }
      else if (fingers.size >= 2) startPinch();
      return;
    }
    if (!drag) return;
    const wasDrag = drag.moved;
    drag = null;
    canvas.style.cursor = 'grab';
    if (wasDrag) return;
    const t = pick(ev);
    if (!t) { onPick(null); return; }
    if (t.kind === 'light') lights.get(t.id).bump();
    onPick(t);
    wake();
  };
  canvas.addEventListener('pointerup', release);
  canvas.addEventListener('pointercancel', (ev) => {
    fingers.delete(ev.pointerId);
    if (!fingers.size) { pinch = null; canvas.style.cursor = 'grab'; }
    else if (pinch && fingers.size >= 2) startPinch();
    drag = null;
  });
  canvas.addEventListener('contextmenu', (ev) => ev.preventDefault());
  canvas.addEventListener('pointerleave', () => { if (!drag) setHover(null); });
  // Two fingers on a trackpad move the model. A mouse wheel, which clicks by whole notches,
  // zooms, and so does ⌘ / Ctrl with either. One burst of scrolling is all one or the other.
  canvas.addEventListener('wheel', (ev) => {
    ev.preventDefault();
    const held = ev.ctrlKey || ev.metaKey;
    const notch = ev.deltaMode === 1 || (ev.deltaX === 0 && ev.wheelDeltaY !== 0 && ev.wheelDeltaY % 120 === 0);
    if (ev.timeStamp - wheelAt > 160) wheelMode = notch ? 'zoom' : 'pan';
    wheelAt = ev.timeStamp;
    wheelUntil = performance.now() + 200;
    const unit = ev.deltaMode === 1 ? 16 : 1;
    if (held || wheelMode === 'zoom') {
      const m = offCentre(ev.clientX, ev.clientY);
      zoomTo(rig.zoom * Math.exp(ev.deltaY * unit * (held ? 0.0075 : 0.0015)), spotAt(m), m);
      return;
    }
    const off = floorOffset(ev.deltaX * unit, ev.deltaY * unit, rig.goal.dist);
    rig.pan.x += off.x;
    rig.pan.z += off.z;
    frameGoal();
    userMoved();
    wake();
  }, { passive: false });
  // A pinch on a trackpad (Safari's and WKWebView's own events; a finger pinch never gets here).
  canvas.addEventListener('gesturestart', (ev) => {
    if (fingers.size) return;
    ev.preventDefault();
    const m = offCentre(ev.clientX, ev.clientY);
    magnify = { zoom: rig.zoom, spot: spotAt(m), m };
  });
  canvas.addEventListener('gesturechange', (ev) => {
    if (!magnify) return;
    ev.preventDefault();
    zoomTo(magnify.zoom / ev.scale, magnify.spot, magnify.m);
  });
  canvas.addEventListener('gestureend', () => { magnify = null; });
  canvas.style.cursor = 'grab';

  /* ---------- loop ---------- */

  let raf = 0;
  let last = 0;
  let awake = 0;       // frames still owed after the last change
  let running = false;
  let shadowAz = baseAz; // where the moon was when its shadows were last drawn

  function wake(frames = 2) {
    awake = Math.max(awake, frames);
    if (running && !raf) { last = performance.now(); raf = requestAnimationFrame(frame); }
  }

  function frame(now) {
    raf = 0;
    const dt = Math.min(0.05, (now - last) / 1000);
    last = now;
    let active = updateRig(dt);
    active = updateWalls(dt) || active;
    for (const unit of lights.values()) active = unit.update(dt) || active;
    for (const unit of acs.values()) active = unit.update(dt) || active;
    if (shadowFrames > 0 || (!active && (wallsMoved || Math.abs(rig.az - shadowAz) > 1))) {
      if (shadowFrames > 0 || wallsMoved) for (const shadow of lampShadows) shadow.needsUpdate = true;
      renderer.shadowMap.needsUpdate = true;
      shadowFrames = Math.max(0, shadowFrames - 1);
      wallsMoved = false;
      shadowAz = rig.az;
      active = true;
    }
    if (active || awake > 0) {
      composer.render(dt);
      awake = Math.max(0, awake - 1);
      if (hovered && active) onHover({ ...hovered, ...screenAnchor(hovered) });
    }
    if (running && (active || awake > 0)) raf = requestAnimationFrame(frame);
  }

  function resize() {
    const r = canvas.getBoundingClientRect();
    if (!r.width || !r.height) return;
    width = r.width;
    height = r.height;
    const pr = Math.min(window.devicePixelRatio || 1, 2);
    renderer.setPixelRatio(pr);
    renderer.setSize(width, height, false);
    composer.setPixelRatio(pr);
    composer.setSize(width, height);
    camera.aspect = width / height;
    // Centre the model between header and panel by shifting the projection window.
    camera.setViewOffset(width, height, 0, -(topInset - bottomInset) / 2, width, height);
    camera.updateProjectionMatrix();
    frameGoal();
    wake(3);
  }

  const world = {
    lights,
    acs,

    setInsets(top, bottom) { topInset = top; bottomInset = bottom; resize(); },
    resize,

    get level() { return level.id; },

    // Shows another floor of the home (and the ones under it).
    setLevel(id) {
      const next = levelById.get(id);
      if (!next || next === level) return;
      level = next;
      showLevel();
      if (rig.focus && levelOf(rig.focus) !== level.id) rig.focus = null;
      placeMoon(rig.az);
      frameGoal();
      userMoved();
      wake(4);
      onLevel(level.id);
    },

    focus(next) {
      const on = next && levelOf(next);
      if (on && on !== level.id) world.setLevel(on);
      rig.focus = next;
      rig.zoom = next ? 1 : home.zoom;
      if (next) rig.pan.set(0, 0, 0);
      else rig.pan.copy(home.pan);
      rig.goal.az = nearestAz(next?.kind === 'ac' ? acView(acs.get(next.id).cfg) : home.az, rig.goal.az);
      rig.goal.el = next?.kind === 'ac' ? 30 : home.el;
      frameGoal();
      reportView();
      wake();
    },

    // Back to the plan's own view, of whatever is in focus.
    resetView() {
      home.az = baseAz;
      home.el = baseEl;
      home.zoom = 1;
      home.pan.set(0, 0, 0);
      rig.zoom = 1;
      rig.pan.set(0, 0, 0);
      rig.goal.az = nearestAz(rig.focus?.kind === 'ac' ? acView(acs.get(rig.focus.id).cfg) : baseAz, rig.goal.az);
      rig.goal.el = rig.focus?.kind === 'ac' ? 30 : baseEl;
      frameGoal();
      reportView();
      wake();
    },

    // Camera sweep + staggered light-up, played whenever the panel appears.
    intro() {
      syncAll({ instant: true });
      for (const unit of lights.values()) { unit.level = 0; unit.write(); }
      for (const unit of acs.values()) unit.power = 0;
      syncAll({ stagger: true });
      frameGoal();
      rig.az = rig.goal.az - 16;
      rig.el = rig.goal.el + 9;
      rig.dist = rig.goal.dist * 1.28;
      rig.target.copy(rig.goal.target);
      wake(4);
    },

    setRunning(on) {
      running = on;
      if (on) wake(4);
      else if (raf) { cancelAnimationFrame(raf); raf = 0; }
    },

    dispose() {
      unsubscribe();
      running = false;
      if (raf) cancelAnimationFrame(raf);
      raf = 0;
      composer.dispose();
      target.dispose();
      renderer.dispose();
      renderer.forceContextLoss();
    },

    // Jump every running animation to its end state (used by tests and screenshots).
    settle(seconds = 6) {
      for (let t = 0; t < seconds; t += 0.05) {
        updateRig(0.05);
        updateWalls(0.05);
        for (const unit of lights.values()) unit.update(0.05);
        for (const unit of acs.values()) unit.update(0.05);
      }
      for (const shadow of lampShadows) shadow.needsUpdate = true;
      renderer.shadowMap.needsUpdate = true;
      composer.render(0);
    },
  };

  // Looking at an AC slightly from the side shows its airflow better.
  const acView = (cfg) => baseAz + (WALL_SIDE[cfg.wall] ?? 0);

  // The floor a room, a lamp or an AC is on.
  function levelOf(t) {
    if (t.kind === 'room') return config.rooms.find((r) => r.id === t.id)?.level;
    return (t.kind === 'ac' ? acs : lights).get(t.id)?.cfg.level;
  }

  syncAll({ instant: true });
  resize();
  updateRig(0, true);
  return world;
}

const WALL_SIDE = { north: -14, west: 14, south: 0, east: 0 };
