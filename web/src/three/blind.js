// A roller blind on the inner face of a wall: a headrail, the fabric and a bottom bar
// that travels down as the blind closes.
import * as THREE from 'three';
import { box, mat, at } from './kit.js';

const EXT_T = 0.2;   // exterior wall thickness (house.js)
const RAIL = 0.07;   // headrail height and depth
const LAYER = 0.035; // a second blind in the same window hangs in front of the first

const FABRIC = {
  roller: { color: '#a3998a', opacity: 0.96 },
  sheer: { color: '#f4f1ea', opacity: 0.42 },
  blackout: { color: '#3d4352', opacity: 0.97 },
};

export class BlindUnit {
  /**
   * `camDir` points from the model to the default camera: a blind on a wall facing it is
   * drawn faint, since that wall is cut away. `layer` is its place among the blinds that
   * share its window.
   */
  constructor(cfg, room, camDir, layer = 0) {
    this.cfg = cfg;
    this.id = cfg.id;

    const alongX = cfg.from[1] === cfg.to[1];
    const a = Math.min(alongX ? cfg.from[0] : cfg.from[1], alongX ? cfg.to[0] : cfg.to[1]);
    const b = Math.max(alongX ? cfg.from[0] : cfg.from[1], alongX ? cfg.to[0] : cfg.to[1]);
    const line = alongX ? cfg.from[1] : cfg.from[0];
    // Which side of the wall the room is on: the blind hangs on that side.
    const roomMid = alongX ? room.z + room.d / 2 : room.x + room.w / 2;
    const inside = Math.sign(roomMid - line) || 1;
    const offset = inside * (EXT_T / 2 + 0.03 + layer * LAYER);

    this.width = b - a + 0.06;
    this.top = cfg.head + 0.05;
    this.drop = this.top - Math.max(0.02, cfg.sill - 0.04); // how far down a closed blind reaches

    this.group = new THREE.Group();
    this.group.position.set(alongX ? (a + b) / 2 : line + offset, 0, alongX ? line + offset : (a + b) / 2);
    this.group.rotation.y = alongX ? 0 : Math.PI / 2;

    const outward = alongX ? new THREE.Vector3(0, 0, -inside) : new THREE.Vector3(-inside, 0, 0);
    const faint = outward.dot(camDir) > 0.15;
    const look = FABRIC[cfg.style] || FABRIC.roller;
    const opacity = faint ? Math.min(look.opacity, 0.3) : look.opacity;
    this.fabric = new THREE.MeshStandardMaterial({
      color: look.color, roughness: 0.92, side: THREE.DoubleSide,
      transparent: opacity < 1, opacity, depthWrite: opacity > 0.9,
    });
    const rail = mat('#c9ccd3', { rough: 0.5, metal: 0.2 });

    this.body = new THREE.Group();
    this.body.add(at(box(this.width + 0.04, RAIL, RAIL, rail, { r: 0.012 }), 0, this.top, 0));
    // The fabric is a unit square scaled to the current drop, hanging from the headrail.
    this.cloth = new THREE.Mesh(new THREE.PlaneGeometry(1, 1).translate(0, -0.5, 0), this.fabric);
    this.cloth.position.y = this.top;
    this.cloth.scale.x = this.width;
    this.bar = box(this.width, 0.022, 0.024, rail, { r: 0.006 });
    this.body.add(this.cloth, this.bar);
    this.body.traverse((o) => { if (o.isMesh) { o.castShadow = !faint && cfg.style !== 'sheer'; o.receiveShadow = true; } });
    this.group.add(this.body);

    // Picking covers the whole window, open or closed.
    this.hit = new THREE.Mesh(new THREE.BoxGeometry(this.width, this.drop, 0.3), new THREE.MeshBasicMaterial());
    this.hit.position.set(0, this.top - this.drop / 2, 0);
    this.hit.visible = false;
    this.hit.userData = { kind: 'blind', id: cfg.id };
    this.group.add(this.hit);

    this.position = 1; // shown
    this.goal = 1;
    this.hover = 0;
    this.hoverGoal = 0;
    this.write();
  }

  anchor(out) {
    return out.set(0, this.top - this.drop * 0.35, 0).applyMatrix4(this.group.matrixWorld);
  }

  apply(state, { instant = false } = {}) {
    this.goal = state.position;
    if (instant) { this.position = this.goal; this.write(); }
  }

  write() {
    const down = Math.max(0.012, this.drop * (1 - this.position));
    this.cloth.scale.y = down;
    this.bar.position.y = this.top - down - 0.011;
  }

  update(dt) {
    // A roller travels at a steady pace, not with a spring.
    const step = dt * 0.45;
    const before = this.position;
    this.position += Math.max(-step, Math.min(step, this.goal - this.position));
    this.moved = this.position !== before;
    if (this.moved) this.write();
    this.hover += (this.hoverGoal - this.hover) * (1 - Math.exp(-dt * 14));
    this.fabric.emissive.setScalar(this.hover * 0.12);
    return this.position !== this.goal || Math.abs(this.hoverGoal - this.hover) > 0.004;
  }

  dispose() {
    this.fabric.dispose();
  }
}
