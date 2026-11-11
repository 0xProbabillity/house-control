// Light fixtures: a small model, the real three.js light(s) it drives and the
// animation that eases both towards the device state.
import * as THREE from 'three';
import { box, cyl, mat, at } from './kit.js';

const STOPS = [
  [2200, new THREE.Color('#ff9438')],
  [3000, new THREE.Color('#ffbd7a')],
  [4200, new THREE.Color('#ffe2c2')],
  [6500, new THREE.Color('#dfe9ff')],
];

export function tempToColor(kelvin, out = new THREE.Color()) {
  const k = Math.min(6500, Math.max(2200, kelvin));
  for (let i = 0; i < STOPS.length - 1; i++) {
    const [k0, c0] = STOPS[i];
    const [k1, c1] = STOPS[i + 1];
    if (k <= k1) return out.copy(c0).lerp(c1, (k - k0) / (k1 - k0));
  }
  return out.copy(STOPS[STOPS.length - 1][1]);
}

export function lightColor(state, out = new THREE.Color()) {
  return state.color ? out.set(state.color) : tempToColor(state.temp, out);
}

const DARK = '#23262e';

function glowMaterial() {
  return new THREE.MeshStandardMaterial({ color: '#8d8f96', roughness: 0.6, emissive: '#000000', emissiveIntensity: 1 });
}

function spot(intensity, y, { shadow = true, x = 0, z = 0 } = {}) {
  const light = new THREE.SpotLight(0xffffff, 0, 0, 1.2, 0.75, 2);
  light.position.set(x, y, z);
  light.target.position.set(x, y - 1, z);
  light.userData.max = intensity;
  light.userData.canShadow = shadow;
  if (!shadow) return light;
  light.castShadow = true;
  light.shadow.mapSize.set(1024, 1024);
  light.shadow.camera.near = 0.15;
  light.shadow.camera.far = 9;
  light.shadow.bias = -0.0006;
  light.shadow.normalBias = 0.03;
  light.shadow.radius = 5;
  light.userData.max = intensity;
  light.userData.canShadow = true;
  return light;
}

function point(intensity, y, { shadow = true, distance = 0, x = 0, z = 0 } = {}) {
  const light = new THREE.PointLight(0xffffff, 0, distance, 2);
  light.position.set(x, y, z);
  if (shadow) {
    light.castShadow = true;
    light.shadow.mapSize.set(512, 512);
    light.shadow.camera.near = 0.08;
    light.shadow.camera.far = 9;
    light.shadow.bias = -0.003;
    light.shadow.normalBias = 0.03;
    light.shadow.radius = 4;
  }
  light.userData.max = intensity;
  light.userData.canShadow = light.castShadow;
  return light;
}

// Each fixture: { parts: Mesh[], glow: Mesh[] (emissive when on), lights: Light[], hit: [w, h, d, y] }
const fixtures = {
  ceiling(cfg, H) {
    const y = cfg.y ?? H - 0.14;
    return {
      parts: [at(cyl(0.012, 0.012, H - y - 0.05, mat(DARK), 8), 0, y + 0.05, 0)],
      glow: [at(cyl(0.27, 0.27, 0.055, glowMaterial(), 40), 0, y, 0)],
      lights: [spot(cfg.intensity ?? 20, y - 0.02)],
      hit: [0.75, 0.5, 0.75, y],
    };
  },

  pendant(cfg, H) {
    const y = cfg.y ?? 1.8;
    const globe = new THREE.Mesh(new THREE.SphereGeometry(0.17, 32, 20), glowMaterial());
    globe.position.set(0, y, 0);
    return {
      parts: [
        at(cyl(0.006, 0.006, H - y - 0.15, mat(DARK), 6), 0, y + 0.15, 0),
        at(cyl(0.04, 0.05, 0.05, mat(DARK, { rough: 0.4, metal: 0.6 }), 16), 0, y + 0.14, 0),
      ],
      glow: [globe],
      lights: [spot(cfg.intensity ?? 9, y - 0.05)],
      hit: [0.6, 0.7, 0.6, y],
    };
  },

  // Several recessed spots on one switch. Every spot is drawn; the light itself comes from
  // at most three sources spread over the group, so a room of eight costs what three lamps do.
  downlights(cfg, H) {
    const y = cfg.y ?? H - 0.05;
    const local = cfg.points.map(([x, z]) => [x - cfg.pos[0], z - cfg.pos[1]]);
    // The model has no ceiling and is seen from above, so the lit face is the one on show.
    const glow = local.map(([x, z]) => at(cyl(0.07, 0.07, 0.03, glowMaterial(), 20), x, y - 0.015, z));
    const parts = local.map(([x, z]) => at(cyl(0.09, 0.09, 0.012, mat(DARK, { rough: 0.5 }), 20), x, y - 0.03, z));
    const n = Math.min(local.length, 3);
    const total = (cfg.intensity ?? 7) * local.length;
    const lights = [];
    for (let i = 0; i < n; i++) {
      const [x, z] = local[Math.round((i + 0.5) * local.length / n - 0.5)];
      lights.push(spot(total / n, y - 0.05, { shadow: i === 0, x, z }));
    }
    const xs = local.map((p) => p[0]);
    const zs = local.map((p) => p[1]);
    return {
      parts, glow, lights,
      hit: [Math.max(...xs) - Math.min(...xs) + 0.4, 0.3, Math.max(...zs) - Math.min(...zs) + 0.4, y],
      hitAt: [(Math.max(...xs) + Math.min(...xs)) / 2, (Math.max(...zs) + Math.min(...zs)) / 2],
      // Grown as one piece the spots would slide apart; each stays where it is drawn.
      rigid: true,
    };
  },

  // Heated towel rail on a wall: "pos" is on the wall line, "rot" turns its front into the room
  // (0 faces south, like furniture). The bars glow when it heats.
  towelRail(cfg) {
    const y = cfg.y ?? 0.75;
    const w = cfg.width ?? 0.5;
    const h = cfg.height ?? 0.8;
    // Dark against the wall, so it reads when it is off as well.
    const steel = mat('#2b2f37', { rough: 0.35, metal: 0.7 });
    const parts = [
      at(cyl(0.02, 0.02, h, steel, 12), -w / 2, y, 0.07),
      at(cyl(0.02, 0.02, h, steel, 12), w / 2, y, 0.07),
    ];
    const glow = [];
    const bars = Math.max(3, Math.round(h / 0.13));
    for (let i = 0; i < bars; i++) {
      const bar = new THREE.Mesh(new THREE.CylinderGeometry(0.016, 0.016, w, 10), glowMaterial());
      bar.rotation.z = Math.PI / 2;
      glow.push(at(bar, 0, y + 0.05 + (h - 0.1) * (i / (bars - 1)), 0.07));
    }
    return { parts, glow, lights: [], hit: [w + 0.2, h + 0.2, 0.35, y + h / 2], onColor: '#ff5a1f', offColor: '#2b2f37', glowGain: 0.55 };
  },

  // Extractor fan in the ceiling: a round grille whose blades turn while it runs.
  fan(cfg, H) {
    const y = cfg.y ?? H - 0.06;
    const rotor = new THREE.Group();
    for (let i = 0; i < 5; i++) {
      const blade = at(box(0.2, 0.012, 0.07, mat('#d7dae0', { rough: 0.5 }), { r: 0 }), 0.11, 0, 0);
      blade.rotation.x = 0.5;
      const arm = new THREE.Group();
      arm.rotation.y = (i / 5) * Math.PI * 2;
      arm.add(blade);
      rotor.add(arm);
    }
    rotor.position.set(0, y - 0.01, 0);
    const ring = new THREE.Mesh(new THREE.TorusGeometry(0.2, 0.012, 10, 40), glowMaterial());
    ring.rotation.x = Math.PI / 2;
    // An open frame, not a plate: seen from above, the blades have to stay visible.
    const frame = new THREE.Mesh(new THREE.TorusGeometry(0.245, 0.03, 12, 44), mat('#eceef2', { rough: 0.45 }));
    frame.rotation.x = Math.PI / 2;
    return {
      parts: [
        at(frame, 0, y, 0),
        at(cyl(0.05, 0.05, 0.05, mat('#eceef2', { rough: 0.4 }), 20), 0, y - 0.03, 0),
        rotor,
      ],
      glow: [at(ring, 0, y, 0)],
      lights: [],
      spin: [rotor],
      hit: [0.7, 0.4, 0.7, y],
      onColor: '#4fd1ff', offColor: '#8d8f96', glowGain: 0.6,
    };
  },

  // Electric kettle on a worktop ("y" is the height of the surface it stands on).
  kettle(cfg) {
    const y = cfg.y ?? 0.9;
    const steel = mat('#d9dce2', { rough: 0.22, metal: 0.85 });
    const dark = mat(DARK, { rough: 0.5 });
    const handle = at(box(0.025, 0.15, 0.03, dark, { r: 0.01 }), -0.115, y + 0.045, 0);
    const spout = at(box(0.05, 0.04, 0.05, steel, { r: 0.012 }), 0.095, y + 0.15, 0);
    return {
      parts: [
        at(cyl(0.095, 0.095, 0.02, dark, 28), 0, y, 0),
        at(cyl(0.07, 0.09, 0.19, steel, 28), 0, y + 0.03, 0),
        at(cyl(0.05, 0.068, 0.02, dark, 24), 0, y + 0.22, 0),
        at(cyl(0.014, 0.014, 0.025, dark, 12), 0, y + 0.24, 0),
        at(box(0.05, 0.02, 0.03, dark, { r: 0.008 }), -0.095, y + 0.185, 0),
        at(box(0.05, 0.02, 0.03, dark, { r: 0.008 }), -0.095, y + 0.045, 0),
        handle, spout,
      ],
      glow: [at(cyl(0.098, 0.098, 0.012, glowMaterial(), 28), 0, y + 0.02, 0)],
      lights: [],
      hit: [0.45, 0.45, 0.45, y + 0.13],
      onColor: '#ff7a2a', offColor: '#3a3f4b', glowGain: 0.8,
    };
  },

  // A light line of several straight runs ("paths"), all on one switch.
  lightLine(cfg) {
    const y = cfg.y ?? 1;
    const glow = [];
    const lights = [];
    const xs = [];
    const zs = [];
    let total = 0;
    const runs = [];
    for (const path of cfg.paths) {
      for (let i = 0; i < path.length - 1; i++) {
        const [ax, az] = [path[i][0] - cfg.pos[0], path[i][1] - cfg.pos[1]];
        const [bx, bz] = [path[i + 1][0] - cfg.pos[0], path[i + 1][1] - cfg.pos[1]];
        const length = Math.hypot(bx - ax, bz - az);
        if (length < 0.01) continue;
        runs.push({ ax, az, bx, bz, length });
        total += length;
        xs.push(ax, bx);
        zs.push(az, bz);
      }
    }
    // One source per metre and a half or so, but never more than six for the whole line.
    const sources = Math.max(1, Math.min(6, Math.round(total / 1.5)));
    const power = (cfg.intensity ?? 1.6) * Math.max(1, total / 2) / sources;
    let placed = 0;
    let walked = 0;
    for (const run of runs) {
      const bar = box(run.length + 0.022, 0.022, 0.022, glowMaterial(), { r: 0.008 });
      bar.rotation.y = -Math.atan2(run.bz - run.az, run.bx - run.ax);
      glow.push(at(bar, (run.ax + run.bx) / 2, y - 0.011, (run.az + run.bz) / 2));
      while (placed < sources && (placed + 0.5) * (total / sources) <= walked + run.length) {
        const t = ((placed + 0.5) * (total / sources) - walked) / run.length;
        lights.push(point(power, y - 0.05, { shadow: false, distance: 3.2, x: run.ax + (run.bx - run.ax) * t, z: run.az + (run.bz - run.az) * t }));
        placed += 1;
      }
      walked += run.length;
    }
    return {
      parts: [], glow, lights,
      hit: [Math.max(...xs) - Math.min(...xs) + 0.3, 0.4, Math.max(...zs) - Math.min(...zs) + 0.3, y],
      hitAt: [(Math.max(...xs) + Math.min(...xs)) / 2, (Math.max(...zs) + Math.min(...zs)) / 2],
      rigid: true,
    };
  },

  // Roller blind on a window: "pos" is on the wall line, "rot" turns its front into the room,
  // "y" is the top of the window and "height" how far the cloth drops when closed.
  // The lamp level is how far it is open: 0 hangs all the way down, 1 is rolled up.
  blind(cfg) {
    const top = cfg.y ?? 2.1;
    const w = cfg.width ?? 1.2;
    const drop = cfg.height ?? 1.25;
    const geo = new THREE.BoxGeometry(w - 0.05, 1, 0.01);
    geo.translate(0, -0.5, 0);
    const cloth = new THREE.Mesh(geo, mat('#e9e4d8', { rough: 0.95 }));
    cloth.position.set(0, top, 0.07);
    const rail = new THREE.Mesh(new THREE.BoxGeometry(w - 0.03, 0.03, 0.03), mat('#c9ccd3', { rough: 0.4, metal: 0.6 }));
    rail.position.set(0, top, 0.07);
    return {
      parts: [at(box(w, 0.08, 0.09, mat('#f1f1f3', { rough: 0.5 }), { r: 0.015 }), 0, top, 0.07), cloth, rail],
      glow: [],
      lights: [],
      hit: [w + 0.1, drop + 0.2, 0.4, top - drop / 2],
      rigid: true,
      animate(level) {
        const len = Math.max(0.04, drop * (1 - level));
        cloth.scale.y = len;
        rail.position.y = cloth.position.y - len;
      },
    };
  },

  // Robot vacuum at its dock ("pos" is where the dock stands, "rot" turns it into the room).
  vacuum(cfg) {
    const body = mat('#f2f3f5', { rough: 0.35 });
    const dark = mat(DARK, { rough: 0.5 });
    const ring = new THREE.Mesh(new THREE.TorusGeometry(0.1, 0.012, 10, 36), glowMaterial());
    ring.rotation.x = Math.PI / 2;
    return {
      parts: [
        at(box(0.2, 0.12, 0.07, dark, { r: 0.015 }), 0, 0, -0.03),
        at(cyl(0.175, 0.175, 0.085, body, 36), 0, 0.01, 0.2),
        at(cyl(0.05, 0.05, 0.022, dark, 24), 0, 0.095, 0.2),
        at(box(0.2, 0.02, 0.02, dark, { r: 0.006 }), 0, 0.03, 0.365),
      ],
      glow: [at(ring, 0, 0.1, 0.2)],
      lights: [],
      hit: [0.5, 0.3, 0.6, 0.1],
      onColor: '#4fd1ff', offColor: '#8d8f96', glowGain: 0.8,
    };
  },

  spots(cfg, H) {
    const y = cfg.y ?? H - 0.16;
    const glow = [-0.32, 0, 0.32].map((x) => at(cyl(0.055, 0.045, 0.1, glowMaterial(), 20), x, y - 0.06, 0));
    return {
      parts: [at(box(0.95, 0.03, 0.05, mat(DARK, { rough: 0.5 }), { r: 0.01 }), 0, y + 0.05, 0)],
      glow,
      lights: [spot(cfg.intensity ?? 20, y - 0.08)],
      hit: [1.1, 0.45, 0.5, y],
    };
  },

  floor(cfg) {
    const shade = cyl(0.14, 0.19, 0.3, glowMaterial(), 32);
    return {
      parts: [
        at(cyl(0.15, 0.16, 0.025, mat(DARK, { rough: 0.4, metal: 0.5 })), 0, 0, 0),
        at(cyl(0.011, 0.011, 1.3, mat(DARK, { rough: 0.4, metal: 0.5 }), 8), 0, 0.02, 0),
      ],
      glow: [at(shade, 0, 1.28, 0)],
      lights: [point(cfg.intensity ?? 3.4, 1.46)],
      hit: [0.6, 1.7, 0.6, 0.85],
    };
  },

  table(cfg) {
    const y = cfg.y ?? 0.5;
    return {
      parts: [
        at(cyl(0.065, 0.075, 0.02, mat(DARK, { rough: 0.4, metal: 0.5 })), 0, y, 0),
        at(cyl(0.01, 0.01, 0.18, mat(DARK, { rough: 0.4, metal: 0.5 }), 8), 0, y + 0.02, 0),
      ],
      glow: [at(cyl(0.085, 0.125, 0.17, glowMaterial(), 28), 0, y + 0.18, 0)],
      lights: [point(cfg.intensity ?? 1.5, y + 0.3)],
      hit: [0.5, 0.6, 0.5, y + 0.2],
    };
  },

  strip(cfg) {
    if (cfg.paths) return fixtures.lightLine(cfg);
    const y = cfg.y ?? 1;
    const length = cfg.length ?? 1;
    const n = Math.max(1, Math.round(length / 1.0));
    const lights = [];
    for (let i = 0; i < n; i++) {
      const x = -length / 2 + (length / n) * (i + 0.5);
      lights.push(point((cfg.intensity ?? 1.6) / n, y, { shadow: false, distance: 3.2, x, z: 0.05 }));
    }
    return {
      parts: [],
      glow: [at(box(length, 0.022, 0.022, glowMaterial(), { r: 0.008 }), 0, y - 0.011, 0)],
      lights,
      hit: [length + 0.2, 0.4, 0.4, y],
    };
  },
};

const tmp = new THREE.Color();

export class LightUnit {
  constructor(cfg, H) {
    this.cfg = cfg;
    this.id = cfg.id;
    const f = fixtures[cfg.type](cfg, H);

    this.group = new THREE.Group();
    this.group.position.set(cfg.pos[0], 0, cfg.pos[1]);
    this.group.rotation.y = THREE.MathUtils.degToRad(cfg.rot || 0);

    this.model = new THREE.Group();
    this.pivotY = f.hit[3];
    this.model.position.y = this.pivotY;
    for (const m of [...f.parts, ...f.glow]) {
      m.position.y -= this.pivotY;
      m.castShadow = false;
      m.receiveShadow = false;
      this.model.add(m);
    }
    this.group.add(this.model);

    this.glow = f.glow.map((m) => m.material);
    this.lights = f.lights;
    // An appliance shows that it runs in its own colour rather than the colour of a lamp.
    this.onColor = f.onColor ? new THREE.Color(f.onColor) : null;
    this.offColor = new THREE.Color(f.offColor || '#8d8f96');
    this.glowGain = f.glowGain ?? 1;
    this.spin = f.spin || [];
    this.rigid = Boolean(f.rigid);
    this.animate = f.animate || null;
    for (const l of this.lights) {
      this.group.add(l);
      if (l.target) this.group.add(l.target);
    }

    const [hw, hh, hd, hy] = f.hit;
    this.hit = new THREE.Mesh(new THREE.BoxGeometry(hw, hh, hd), new THREE.MeshBasicMaterial());
    this.hit.position.set(f.hitAt?.[0] ?? 0, hy, f.hitAt?.[1] ?? 0);
    this.hit.visible = false;
    this.hit.userData = { kind: 'light', id: cfg.id };
    this.group.add(this.hit);

    this.level = 0;        // eased 0..1 output
    this.goal = 0;
    this.color = new THREE.Color('#ffbd7a');
    this.goalColor = this.color.clone();
    this.hover = 0;
    this.hoverGoal = 0;
    this.pulse = 0;
    this.delay = 0;
    this.write();
  }

  // Anchor used for tooltips.
  anchor(out) {
    return out.set(0, this.pivotY + 0.25, 0).applyMatrix4(this.group.matrixWorld);
  }

  apply(state, { instant = false, delay = 0 } = {}) {
    const dimmable = this.cfg.capabilities.includes('brightness');
    this.goal = state.on ? (dimmable ? state.brightness : 1) : 0;
    if (this.onColor) this.goalColor.copy(this.onColor); else lightColor(state, this.goalColor);
    this.delay = delay;
    if (instant) {
      this.level = this.goal;
      this.color.copy(this.goalColor);
      this.write();
    } else if (this.level < 0.01) {
      this.color.copy(this.goalColor); // nothing visible yet: no need to fade the hue
    }
  }

  bump() { this.pulse = 1; }

  update(dt) {
    if (this.delay > 0) { this.delay -= dt; return true; }
    // Blades keep turning for as long as the fan runs, so the scene keeps drawing.
    const spinning = this.spin.length > 0 && this.level > 0.01;
    if (spinning) for (const s of this.spin) s.rotation.y += dt * 11 * this.level;
    const k = 1 - Math.exp(-dt * (this.goal > this.level ? 7 : 5));
    const dl = this.goal - this.level;
    const dh = this.hoverGoal - this.hover;
    const dc = Math.abs(this.color.r - this.goalColor.r) + Math.abs(this.color.g - this.goalColor.g)
      + Math.abs(this.color.b - this.goalColor.b);
    const moving = Math.abs(dl) > 0.002 || Math.abs(dh) > 0.004 || dc > 0.004 || this.pulse > 0.004;
    if (!moving) {
      if (this.level !== this.goal || this.hover !== this.hoverGoal || this.pulse !== 0) {
        this.level = this.goal; this.hover = this.hoverGoal; this.pulse = 0;
        this.color.copy(this.goalColor);
        this.write();
        return true;
      }
      return spinning;
    }
    this.level += dl * k;
    this.hover += dh * (1 - Math.exp(-dt * 14));
    this.pulse *= Math.exp(-dt * 7);
    this.color.lerp(this.goalColor, 1 - Math.exp(-dt * 6));
    this.write();
    return true;
  }

  write() {
    const out = Math.pow(this.level, 1.5);
    for (const l of this.lights) {
      l.intensity = l.userData.max * out;
      l.color.copy(this.color);
    }
    // Lamp bodies stay faintly readable when off and hot enough to bloom when on.
    const e = this.level > 0.001 ? (0.8 + 1.7 * Math.pow(this.level, 0.7)) * this.glowGain : 0;
    for (const m of this.glow) {
      m.emissive.copy(this.color);
      m.emissiveIntensity = e + this.hover * 0.5;
      if (this.level < 0.001) m.emissive.copy(tmp.set('#5b6b93'));
      m.color.copy(this.offColor).lerp(this.color, Math.min(1, this.level * 2));
    }
    this.animate?.(this.level);
    const s = this.rigid ? 1 : 1 + this.hover * 0.14 + Math.sin(this.pulse * Math.PI) * 0.22;
    this.model.scale.setScalar(s);
  }
}
