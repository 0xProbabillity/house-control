// Underfloor heating: the room's floor shows the heating loop, glowing while it warms.
// It stands in for an AC unit in the scene (same interface as ACUnit), driven by a thermostat.
import * as THREE from 'three';
import { MODE_COLORS } from './ac.js';

// The loop as a texture: one serpentine pipe, drawn once per room size.
function loopTexture(w, d) {
  const scale = 160; // pixels per metre
  const c = document.createElement('canvas');
  c.width = Math.max(64, Math.round(w * scale));
  c.height = Math.max(64, Math.round(d * scale));
  const g = c.getContext('2d');
  const pitch = 0.22 * scale;
  const margin = 0.16 * scale;
  g.strokeStyle = '#ffffff';
  g.lineWidth = 0.045 * scale;
  g.lineCap = 'round';
  g.lineJoin = 'round';
  g.beginPath();
  let y = margin;
  let right = true;
  g.moveTo(margin, y);
  while (y <= c.height - margin) {
    g.lineTo(right ? c.width - margin : margin, y);
    if (y + pitch > c.height - margin) break;
    g.lineTo(right ? c.width - margin : margin, y + pitch);
    y += pitch;
    right = !right;
  }
  g.stroke();
  const tex = new THREE.CanvasTexture(c);
  tex.colorSpace = THREE.SRGBColorSpace;
  tex.anisotropy = 4;
  return tex;
}

export class FloorHeat {
  constructor(cfg, room) {
    this.cfg = cfg;
    this.id = cfg.id;
    const inset = 0.1;
    const w = Math.max(0.3, room.w - inset * 2);
    const d = Math.max(0.3, room.d - inset * 2);

    this.group = new THREE.Group();
    this.group.position.set(room.x + room.w / 2, 0, room.z + room.d / 2);

    this.material = new THREE.MeshBasicMaterial({
      map: loopTexture(w, d), color: MODE_COLORS.heat, transparent: true, opacity: 0,
      blending: THREE.AdditiveBlending, depthWrite: false, toneMapped: false,
    });
    this.loop = new THREE.Mesh(new THREE.PlaneGeometry(w, d), this.material);
    this.loop.rotation.x = -Math.PI / 2;
    this.loop.position.y = 0.012;
    this.loop.renderOrder = 2;
    this.group.add(this.loop);

    this.wash = new THREE.PointLight(MODE_COLORS.heat, 0, Math.max(w, d) * 1.2, 2);
    this.wash.position.set(0, 0.35, 0);
    this.group.add(this.wash);

    // The middle of the floor is the handle; the edges stay free for whatever stands there.
    this.hit = new THREE.Mesh(new THREE.BoxGeometry(w * 0.6, 0.06, d * 0.6), new THREE.MeshBasicMaterial());
    this.hit.position.y = 0.03;
    this.hit.visible = false;
    this.hit.userData = { kind: 'ac', id: cfg.id };
    this.group.add(this.hit);

    this.power = 0;      // eased 0..1: heating right now
    this.goal = 0;
    this.standby = 0;    // eased 0..1: switched on (the loop stays faintly visible while idle)
    this.standbyGoal = 0;
    this.clock = 0;
    this.hover = 0;
    this.hoverGoal = 0;
  }

  anchor(out) {
    return out.set(0, 0.35, 0).applyMatrix4(this.group.matrixWorld);
  }

  apply(state, { instant = false } = {}) {
    this.goal = state.on && !state.idle ? 1 : 0;
    this.standbyGoal = state.on ? 1 : 0;
    if (instant) { this.power = this.goal; this.standby = this.standbyGoal; }
  }

  update(dt) {
    const ease = (v, goal, rate) => {
      const next = v + (goal - v) * (1 - Math.exp(-dt * rate));
      return Math.abs(goal - next) < 0.002 ? goal : next;
    };
    this.power = ease(this.power, this.goal, 2.5);
    this.standby = ease(this.standby, this.standbyGoal, 2.5);
    this.hover = ease(this.hover, this.hoverGoal, 14);
    this.clock += dt;

    const breathe = 0.85 + 0.15 * Math.sin(this.clock * 1.4);
    this.material.opacity = Math.min(1, this.standby * 0.12 + this.power * 0.6 * breathe + this.hover * 0.25);
    this.loop.visible = this.material.opacity > 0.003;
    this.wash.intensity = this.power * 0.9 * breathe;

    const heating = this.power > 0.004;
    return heating || this.power !== this.goal || this.standby !== this.standbyGoal || this.hover !== this.hoverGoal;
  }
}
