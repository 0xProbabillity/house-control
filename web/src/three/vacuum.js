// Robot vacuum and its dock. The robot drives the plausible run vacuum-path.js works out
// (its real position is not reported), turning on the spot like the real thing, and keeps
// where it is whenever its status changes: it pauses there, goes home from there, or picks
// the run up again from there.
import * as THREE from 'three';
import { box, cyl, mat, at } from './kit.js';
import { roomGraph, tour, route, dockPose, reach, roomAt } from './vacuum-path.js';

const SPEED = 0.6;     // m/s: a real robot's 0.3, shown twice as fast so the run is visible
const TURN = 3.4;      // rad/s, on the spot
const ALIGNED = 0.3;   // rad: closer than this to its heading, it drives while it finishes turning
const PULSE_FOR = 20;  // s: an error pulses for a while, then stays lit, so the loop can sleep

export const VACUUM_COLORS = {
  cleaning: '#4ade80',
  returning: '#5db2ff',
  docked: '#9fe3b8',
  charging: '#ffb44f',
  paused: '#ffd84a',
  idle: '#c9d2e3',
  error: '#ff4f45',
  unavailable: '#6b7280',
};

const wrap = (a) => Math.atan2(Math.sin(a), Math.cos(a));

export class VacuumUnit {
  constructor(cfg, config, { onDocked } = {}) {
    this.cfg = cfg;
    this.id = cfg.id;
    this.config = config;
    this.onDocked = onDocked;
    this.graph = roomGraph(config);
    const room = config.rooms.find((r) => r.id === cfg.room);
    this.dock = dockPose(room, cfg.pos, cfg.rot);

    this.group = new THREE.Group();
    this.group.add(this.buildDock(), this.buildRobot());

    // Where it is and where it is going.
    this.x = this.dock.docked.x;
    this.z = this.dock.docked.z;
    this.heading = Math.atan2(this.dock.nx, this.dock.nz); // docked: backed on, facing the room
    this.room = cfg.room;
    this.onDock = true;
    this.path = [];        // waypoints still ahead: { x, z, room, back? }
    this.cleaning = null;  // the rest of an interrupted run, to pick up again
    this.goal = 'stay';    // 'clean' | 'home' | 'stay'
    this.status = null;
    this.battery = null;
    this.clock = 0;
    this.errorFor = 0;
    this.hover = 0;
    this.hoverGoal = 0;
    this.place();
  }

  buildDock() {
    const { x, z, nx, nz } = this.dock;
    const dock = new THREE.Group();
    dock.position.set(x, 0, z);
    dock.rotation.y = Math.atan2(nx, nz);
    const shell = mat('#2b3039', { rough: 0.5 });
    this.dockLight = new THREE.MeshStandardMaterial({ color: '#1d2129', emissive: '#000000', roughness: 0.4 });
    dock.add(
      at(box(0.3, 0.012, 0.17, mat('#23272f', { rough: 0.7 }), { r: 0.005 }), 0, 0, 0.05),
      at(box(0.3, 0.11, 0.08, shell, { r: 0.02 }), 0, 0, -0.03),
      at(box(0.14, 0.012, 0.004, this.dockLight, { r: 0 }), 0, 0.07, 0.0115),
    );
    dock.traverse((o) => { if (o.isMesh) { o.castShadow = true; o.receiveShadow = true; } });
    this.dockHit = new THREE.Mesh(new THREE.BoxGeometry(0.36, 0.2, 0.24), new THREE.MeshBasicMaterial());
    this.dockHit.position.set(0, 0.1, 0.02);
    this.dockHit.visible = false;
    this.dockHit.userData = { kind: 'vacuum', id: this.cfg.id };
    dock.add(this.dockHit);
    return dock;
  }

  buildRobot() {
    const robot = new THREE.Group();
    const body = new THREE.Group();
    body.position.y = 0.012; // the wheels keep it off the floor
    const bumper = new THREE.Mesh(
      new THREE.CylinderGeometry(0.173, 0.173, 0.045, 28, 1, true, -Math.PI / 2, Math.PI).translate(0, 0.0325, 0),
      mat('#3a3f49', { rough: 0.6 }));
    this.led = new THREE.MeshStandardMaterial({ color: '#30343c', emissive: '#000000', roughness: 0.3 });
    this.brush = new THREE.Group();
    this.brush.position.set(0.112, -0.006, 0.108);
    for (let k = 0; k < 3; k++) {
      const bristle = at(box(0.075, 0.003, 0.006, mat('#cfd4dc', { rough: 0.6 }), { r: 0 }), 0.0375, 0, 0);
      const arm = new THREE.Group();
      arm.rotation.y = (k * Math.PI * 2) / 3;
      arm.add(bristle);
      this.brush.add(arm);
    }
    body.add(
      cyl(0.17, 0.17, 0.072, mat('#eceef2', { rough: 0.35 }), 36),
      at(cyl(0.155, 0.158, 0.006, mat('#d6dae1', { rough: 0.3 }), 36), 0, 0.072, 0),
      bumper,
      at(cyl(0.046, 0.046, 0.024, mat('#2b2f37', { rough: 0.4 }), 20), 0, 0.078, -0.045),
      at(new THREE.Mesh(new THREE.SphereGeometry(0.011, 12, 8), this.led), 0, 0.08, 0.085),
      this.brush,
    );
    // It moves while the shadow map stays as it was drawn once: it receives shadows only.
    body.traverse((o) => { if (o.isMesh) { o.castShadow = false; o.receiveShadow = true; } });
    robot.add(body);
    this.body = body;

    this.hit = new THREE.Mesh(new THREE.CylinderGeometry(0.24, 0.24, 0.22, 16), new THREE.MeshBasicMaterial());
    this.hit.position.y = 0.11;
    this.hit.visible = false;
    this.hit.userData = { kind: 'vacuum', id: this.cfg.id };
    robot.add(this.hit);
    this.robot = robot;
    return robot;
  }

  /** Everything a pointer can hit to pick this vacuum: the robot and its dock. */
  get hits() { return [this.hit, this.dockHit]; }

  anchor(out) {
    return out.set(this.x, 0.24, this.z);
  }

  apply(state) {
    const first = this.status === null;
    const status = state?.status || 'docked';
    this.battery = Number.isFinite(state?.battery) ? state.battery : null;
    if (status === this.status) { this.paint(); return; }
    const before = this.status;
    this.status = status;
    if (status === 'error' && before !== 'error') this.errorFor = 0;

    // Out of reach it most likely sleeps on its dock (many robots switch their Wi-Fi off there).
    if (first && !['docked', 'cleaning', 'unavailable'].includes(status)) {
      // Not on its dock and no idea where: just in front of it.
      this.x = this.dock.out.x;
      this.z = this.dock.out.z;
      this.onDock = false;
    }

    if (status === 'cleaning') this.clean();
    else if (status === 'returning' || status === 'docked') this.goHome();
    else this.stop(); // paused, idle, error, unavailable: it stays where it is
    this.paint();
  }

  // A run: off the dock first if it is on it, else on from where it stopped.
  clean() {
    if (this.goal === 'clean') return;
    this.goal = 'clean';
    if (this.cleaning?.length) { this.path = this.back(this.cleaning); return; }
    const start = this.onDock ? { ...this.dock.out, room: this.dock.room } : this.here();
    const lead = this.onDock ? [start] : [];
    this.path = this.back([...lead, ...tour(this.graph, start, this.dock)]);
  }

  goHome() {
    if (this.onDock) { this.goal = 'stay'; this.path = []; return; }
    if (this.goal === 'home') return;
    // A run cut short by going home is over; the next one starts afresh.
    this.cleaning = null;
    this.goal = 'home';
    const way = route(this.graph, this.here(), { ...this.dock.out, room: this.dock.room })
      || [{ ...this.dock.out, room: this.dock.room }]; // a dock it cannot drive to: the shortest way
    this.path = this.back([...way, { ...this.dock.docked, room: this.dock.room, back: true }]);
  }

  stop() {
    if (this.goal === 'clean') this.cleaning = this.path;
    this.goal = 'stay';
    this.path = [];
  }

  // Where it is now, as a waypoint in the room it is in.
  here() {
    const room = roomAt(this.config, [this.x, this.z], this.room);
    if (room) this.room = room.id;
    return { x: this.x, z: this.z, room: this.room };
  }

  // Stopped in a doorway, it first backs into the room it was in, straight through the
  // doorway, so the next leg cannot cut a wall's corner.
  back(path) {
    if (this.onDock) return path;
    const r = reach(this.config.rooms.find((x) => x.id === this.room));
    const x = Math.min(r.x1, Math.max(r.x0, this.x));
    const z = Math.min(r.z1, Math.max(r.z0, this.z));
    if (Math.hypot(x - this.x, z - this.z) < 1e-3) return path;
    return [{ x, z, room: this.room }, ...path];
  }

  paint() {
    const s = this.status;
    const charging = s === 'docked' && this.battery != null && this.battery < 100;
    this.color = VACUUM_COLORS[charging ? 'charging' : s] || VACUUM_COLORS.idle;
    this.led.emissive.set(this.color);
    this.led.emissiveIntensity = s === 'unavailable' ? 0.5 : s === 'idle' || s === 'paused' ? 1.2 : 2.2;
    // The dock's light shows it is charging the robot sitting on it.
    const home = this.onDock && (s === 'docked' || s === 'returning');
    this.dockLight.emissive.set(home ? this.color : '#5db2ff');
    this.dockLight.emissiveIntensity = home ? 1.6 : 0.35;
  }

  place() {
    this.robot.position.set(this.x, 0, this.z);
    this.robot.rotation.y = this.heading;
  }

  update(dt) {
    this.clock += dt;
    this.hover += (this.hoverGoal - this.hover) * (1 - Math.exp(-dt * 14));
    this.body.scale.setScalar(1 + this.hover * 0.12);
    let active = Math.abs(this.hoverGoal - this.hover) > 0.004;

    if (this.path.length) {
      this.drive(dt);
      active = true;
    } else if (this.goal === 'clean') {
      // A run done while the vacuum still says it is cleaning: another round.
      this.goal = null;
      this.cleaning = null;
      this.clean();
      active = true;
    }
    if (this.goal === 'clean' && this.path.length) this.brush.rotation.y -= dt * 22;

    if (this.status === 'error' && this.errorFor < PULSE_FOR) {
      this.errorFor += dt;
      this.led.emissiveIntensity = 0.6 + 2.4 * (0.5 + 0.5 * Math.sin(this.clock * 7));
      if (this.errorFor >= PULSE_FOR) this.led.emissiveIntensity = 2.2;
      active = true;
    }
    this.place();
    return active;
  }

  drive(dt) {
    const t = this.path[0];
    const dx = t.x - this.x;
    const dz = t.z - this.z;
    const dist = Math.hypot(dx, dz);
    if (dist < 1e-4) { this.arrive(t); return; }
    if (this.onDock && !t.back) this.onDock = false;
    // Backing onto the dock it faces away from where it goes.
    const want = t.back ? Math.atan2(-dx, -dz) : Math.atan2(dx, dz);
    const diff = wrap(want - this.heading);
    // Eases into the new heading instead of snapping to it.
    const turn = Math.sign(diff) * Math.min(Math.abs(diff), TURN * dt, Math.abs(diff) * 10 * dt + 0.002);
    this.heading = wrap(this.heading + turn);
    const left = Math.abs(diff - turn);
    if (left > ALIGNED) return; // turning on the spot
    const step = Math.min(dist, SPEED * dt * Math.cos(left) * (t.back ? 0.5 : 1));
    this.x += (dx / dist) * step;
    this.z += (dz / dist) * step;
    if (step >= dist - 1e-6) this.arrive(t);
  }

  arrive(t) {
    this.x = t.x;
    this.z = t.z;
    this.room = t.room;
    this.path.shift();
    if (t.back) {
      this.onDock = true;
      this.goal = 'stay';
      this.paint();
      this.onDocked?.(this.id);
    }
  }
}
