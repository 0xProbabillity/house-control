// Wall-mounted AC unit with an animated airflow made of additive streaks.
import * as THREE from 'three';
import { LineSegments2 } from 'three/addons/lines/LineSegments2.js';
import { LineSegmentsGeometry } from 'three/addons/lines/LineSegmentsGeometry.js';
import { LineMaterial } from 'three/addons/lines/LineMaterial.js';
import { box, mat, at } from './kit.js';

export const MODE_COLORS = {
  cool: '#5db2ff',
  heat: '#ff8c3a',
  dry: '#62e0cf',
  fan: '#cfdcff',
  auto: '#9bd28a',
};

const FAN_SPEED = { auto: 0.42, low: 0.26, medium: 0.42, high: 0.62, turbo: 0.9 };
const SWING_ANGLE = { l1: 12, l2: 24, l3: 38, l4: 52, l5: 66, off: 38 };
const WALL_ROT = { north: 0, south: Math.PI, west: Math.PI / 2, east: -Math.PI / 2 };

const STREAKS = 72;
const REACH = 2.5;

export class ACUnit {
  constructor(cfg) {
    this.cfg = cfg;
    this.id = cfg.id;

    this.group = new THREE.Group();
    this.group.position.set(cfg.pos[0], cfg.y, cfg.pos[1]);
    this.group.rotation.y = WALL_ROT[cfg.wall];

    const body = new THREE.Group();
    body.position.z = 0.1 + 0.105; // sit on the inner face of the wall
    const shell = mat('#f3f4f6', { rough: 0.35 });
    this.led = new THREE.MeshStandardMaterial({ color: '#30343c', emissive: '#000000', roughness: 0.4 });
    this.flap = box(0.8, 0.012, 0.075, mat('#e3e5e9', { rough: 0.35 }), { r: 0.004 });
    this.flapPivot = new THREE.Group();
    this.flapPivot.position.set(0, -0.145, 0.03);
    this.flap.position.set(0, -0.006, 0.0375);
    this.flapPivot.add(this.flap);
    body.add(
      at(box(0.94, 0.29, 0.21, shell, { r: 0.05 }), 0, -0.145, 0),
      at(box(0.82, 0.03, 0.09, mat('#17191d', { rough: 0.6 }), { r: 0.006 }), 0, -0.16, 0.055),
      at(box(0.9, 0.004, 0.006, mat('#c9ccd2'), { r: 0 }), 0, 0.02, 0.105),
      at(box(0.085, 0.022, 0.006, this.led, { r: 0.003 }), 0.34, -0.06, 0.105),
      this.flapPivot,
    );
    body.traverse((o) => { if (o.isMesh) { o.castShadow = true; o.receiveShadow = true; } });
    this.group.add(body);
    this.body = body;

    // Soft coloured wash so the mode reads on the wall and floor.
    this.wash = new THREE.PointLight(0xffffff, 0, 3.4, 2);
    this.wash.position.set(0, -0.5, 0.75);
    this.group.add(this.wash);

    // Fat lines (screen-space width) so the streaks stay readable over lit walls.
    const geo = new LineSegmentsGeometry();
    geo.setPositions(new Float32Array(STREAKS * 6));
    geo.setColors(new Float32Array(STREAKS * 6));
    this.flowPos = geo.attributes.instanceStart.data;
    this.flowCol = geo.attributes.instanceColorStart.data;
    this.flowPos.setUsage(THREE.DynamicDrawUsage);
    this.flowCol.setUsage(THREE.DynamicDrawUsage);
    this.flow = new LineSegments2(geo, new LineMaterial({
      linewidth: 2.4, vertexColors: true, blending: THREE.AdditiveBlending, depthWrite: false, transparent: true, toneMapped: false,
    }));
    this.flow.frustumCulled = false;
    this.flow.position.z = 0.1 + 0.15;
    this.flow.position.y = -0.17;
    this.flow.visible = false;
    this.group.add(this.flow);

    this.seeds = Array.from({ length: STREAKS }, (_, i) => ({
      phase: (i * 0.618034) % 1,
      u: ((i * 0.381966) % 1) * 2 - 1,
      speed: 0.8 + ((i * 0.7548) % 1) * 0.5,
      wobble: (i * 2.399) % (Math.PI * 2),
    }));

    this.hit = new THREE.Mesh(new THREE.BoxGeometry(1.2, 0.6, 0.6), new THREE.MeshBasicMaterial());
    this.hit.position.set(0, -0.15, 0.25);
    this.hit.visible = false;
    this.hit.userData = { kind: 'ac', id: cfg.id };
    this.group.add(this.hit);

    this.power = 0;
    this.goal = 0;
    this.color = new THREE.Color(MODE_COLORS.cool);
    this.goalColor = this.color.clone();
    this.speed = FAN_SPEED.auto;
    this.swing = 'swing';
    this.angle = 38;
    this.clock = 0;
    this.hover = 0;
    this.hoverGoal = 0;
  }

  anchor(out) {
    return out.set(0, 0.12, 0.2).applyMatrix4(this.group.matrixWorld);
  }

  apply(state, { instant = false } = {}) {
    this.goal = state.on ? 1 : 0;
    this.goalColor.set(MODE_COLORS[state.mode] || MODE_COLORS.cool);
    this.speed = FAN_SPEED[state.fan] ?? FAN_SPEED.auto;
    if (state.sleep) this.speed *= 0.6;
    this.swing = state.swing;
    if (instant) { this.power = this.goal; this.color.copy(this.goalColor); }
  }

  update(dt) {
    this.power += (this.goal - this.power) * (1 - Math.exp(-dt * 3.5));
    if (Math.abs(this.goal - this.power) < 0.002) this.power = this.goal;
    this.color.lerp(this.goalColor, 1 - Math.exp(-dt * 5));
    this.hover += (this.hoverGoal - this.hover) * (1 - Math.exp(-dt * 14));
    this.clock += dt;

    const target = this.swing === 'swing'
      ? 38 + Math.sin(this.clock * 0.9) * 26
      : SWING_ANGLE[this.swing] ?? 38;
    this.angle += (target - this.angle) * (1 - Math.exp(-dt * 4));

    this.flapPivot.rotation.x = THREE.MathUtils.degToRad(this.angle * 0.9 + 10) * this.power;
    this.led.emissive.copy(this.color);
    this.led.emissiveIntensity = this.power * 3;
    this.wash.color.copy(this.color);
    this.wash.intensity = this.power * 1.4;
    this.body.scale.setScalar(1 + this.hover * 0.06);

    const running = this.power > 0.004;
    this.flow.visible = running;
    if (running) this.writeFlow();
    return running || Math.abs(this.hoverGoal - this.hover) > 0.004 || this.goal !== this.power;
  }

  writeFlow() {
    const pos = this.flowPos;
    const col = this.flowCol;
    const a = THREE.MathUtils.degToRad(this.angle);
    const sin = Math.sin(a);
    const cos = Math.cos(a);
    const { r, g, b } = this.color;

    const sample = (seed, t, out, o) => {
      const d = REACH * t;
      const spread = 0.36 + 0.5 * t;
      const sway = Math.sin(this.clock * 1.6 + seed.wobble + t * 5) * 0.035 * t;
      out[o] = seed.u * spread + sway;
      out[o + 1] = -sin * d - 0.35 * t * t;
      out[o + 2] = cos * d;
    };

    for (let i = 0; i < STREAKS; i++) {
      const seed = this.seeds[i];
      const t = (seed.phase + this.clock * this.speed * seed.speed) % 1;
      const tail = Math.max(0, t - 0.085);
      sample(seed, t, pos.array, i * 6);
      sample(seed, tail, pos.array, i * 6 + 3);
      const fade = Math.pow(Math.sin(Math.PI * t), 0.7) * this.power * 1.25;
      col.array[i * 6] = r * fade; col.array[i * 6 + 1] = g * fade; col.array[i * 6 + 2] = b * fade;
      col.array[i * 6 + 3] = r * fade * 0.1; col.array[i * 6 + 4] = g * fade * 0.1; col.array[i * 6 + 5] = b * fade * 0.1;
    }
    pos.needsUpdate = true;
    col.needsUpdate = true;
  }
}
