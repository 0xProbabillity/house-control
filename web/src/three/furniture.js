// Procedural furniture library. Every builder returns a Group standing on y = 0,
// centred on its footprint and facing +z; the plan's "rot" turns it from there.
import * as THREE from 'three';
import { box, cyl, mat, at, rng } from './kit.js';

const WOOD = '#a98459';
const DARK_WOOD = '#5a4334';
const WHITE = '#eceae5';
const BLACK = '#1b1c21';
const METAL = '#9a9fa8';

const group = (...children) => {
  const g = new THREE.Group();
  g.add(...children.flat().filter(Boolean));
  return g;
};

function darker(hex, k = 0.75) {
  return `#${new THREE.Color(hex).multiplyScalar(k).getHexString()}`;
}

function legs(w, d, h, material, inset = 0.06, r = 0.022) {
  const out = [];
  for (const sx of [-1, 1]) for (const sz of [-1, 1]) {
    out.push(at(cyl(r, r * 0.8, h, material, 10), sx * (w / 2 - inset), 0, sz * (d / 2 - inset)));
  }
  return out;
}

function seating(width, depth, color, cushions) {
  const fabric = mat(color, { rough: 1 });
  const dark = mat(darker(color, 0.82), { rough: 1 });
  const arm = 0.2;
  const inner = width - arm * 2;
  const parts = [
    ...legs(width, depth, 0.1, mat(BLACK, { rough: 0.5 }), 0.08),
    at(box(width, 0.2, depth, dark, { r: 0.05 }), 0, 0.1, 0),
    at(box(inner, 0.52, 0.24, dark, { r: 0.09 }), 0, 0.3, -depth / 2 + 0.12),
  ];
  for (const sx of [-1, 1]) parts.push(at(box(arm, 0.36, depth, dark, { r: 0.08 }), sx * (width / 2 - arm / 2), 0.3, 0));
  const cw = inner / cushions;
  for (let i = 0; i < cushions; i++) {
    const x = -inner / 2 + cw * (i + 0.5);
    parts.push(at(box(cw - 0.02, 0.17, depth - 0.3, fabric, { r: 0.06 }), x, 0.3, 0.1));
    const back = at(box(cw - 0.04, 0.36, 0.16, fabric, { r: 0.07 }), x, 0.46, -depth / 2 + 0.3);
    back.rotation.x = -0.14;
    parts.push(back);
  }
  return group(parts);
}

function chair(color = BLACK) {
  const m = mat(color, { rough: 0.7 });
  const back = at(box(0.42, 0.4, 0.04, m, { r: 0.02 }), 0, 0.47, -0.2);
  back.rotation.x = -0.1;
  return group(...legs(0.42, 0.42, 0.44, m, 0.04, 0.015), at(box(0.44, 0.05, 0.44, m, { r: 0.02 }), 0, 0.42, 0), back);
}

function doorLines(width, height, y, z, count, material) {
  const out = [];
  for (let i = 1; i < count; i++) out.push(at(box(0.008, height, 0.006, material, { r: 0 }), -width / 2 + (width / count) * i, y, z));
  return out;
}

export const FURNITURE_VARIANTS = {
  tv: ['console', 'wall'],
  vanity: ['cabinet', 'pedestal'],
  coffeeTable: ['modern', 'woodShelf'],
  sofa: ['pillowed', 'plain'],
};

export function isWallMounted(item) {
  return item?.type === 'tv' && (item.variant === 'wall' || item.wallMounted === true);
}

const builders = {
  rug({ size = [2, 1.4], color = '#3b4a66' }) {
    const g = group(
      at(box(size[0], 0.016, size[1], mat(color, { rough: 1 }), { r: 0.006 }), 0, 0, 0),
      at(box(size[0] - 0.24, 0.018, size[1] - 0.24, mat(darker(color, 1.18), { rough: 1 }), { r: 0.006 }), 0, 0, 0),
    );
    g.userData.flat = true;
    return g;
  },

  sofa({ width = 2.2, color = '#8b93a7', variant, throwPillow }) {
    const g = seating(width, 0.95, color, width > 2 ? 3 : 2);
    const plain = variant ? variant === 'plain' : throwPillow === false;
    if (!plain) {
      // throw pillow
      const pillow = at(box(0.36, 0.36, 0.12, mat('#d9b98a', { rough: 1 }), { r: 0.05 }), -width / 2 + 0.42, 0.46, -0.1);
      pillow.rotation.set(-0.25, 0.3, 0.1);
      g.add(pillow);
    }
    return g;
  },

  pillow({ width = 0.38, color = '#d9b98a' }) {
    const cushion = at(box(width, width * 0.92, 0.12, mat(color, { rough: 1 }), { r: 0.05 }), 0, 0.01, 0);
    cushion.rotation.set(-0.2, 0.12, 0.04);
    return group(cushion);
  },

  armchair({ color = '#c28a5a' }) {
    return seating(0.92, 0.88, color, 1);
  },

  coffeeTable({ width = 1.1, depth = 0.58, height = 0.4, color = WOOD, variant, woodShelf = false }) {
    const wood = mat(color, { rough: 0.6 });
    const shelfStyle = variant ? variant === 'woodShelf' : Boolean(woodShelf);
    if (shelfStyle) {
      const topH = 0.036;
      const legH = Math.max(0.12, height - topH);
      const legMat = mat(darker(color, 0.88), { rough: 0.65 });
      const inset = 0.06;
      const sqLegs = [];
      for (const sx of [-1, 1]) for (const sz of [-1, 1]) {
        sqLegs.push(at(box(0.042, legH, 0.042, legMat, { r: 0.008 }), sx * (width / 2 - inset), 0, sz * (depth / 2 - inset)));
      }
      return group(
        at(box(width, topH, depth, wood, { r: 0.012 }), 0, legH, 0),
        at(box(width - 0.12, 0.05, depth - 0.12, legMat, { r: 0.006 }), 0, legH - 0.05, 0),
        at(box(width - 0.14, 0.024, depth - 0.14, wood, { r: 0.008 }), 0, Math.min(0.14, legH * 0.4), 0),
        ...sqLegs,
      );
    }
    const topY = Math.max(0.16, height - 0.04);
    return group(
      at(box(width, 0.04, depth, wood, { r: 0.015 }), 0, topY, 0),
      at(box(width - 0.16, 0.02, Math.max(0.16, depth - 0.14), mat(BLACK, { rough: 0.5 }), { r: 0.008 }), 0, Math.min(0.14, topY * 0.4), 0),
      ...legs(width, depth, topY, mat(BLACK, { rough: 0.5 }), 0.07, 0.015),
      at(box(0.24, 0.035, 0.17, mat('#c9553f', { rough: 0.9 }), { r: 0.006 }), 0.22, topY + 0.04, 0.05),
      at(cyl(0.05, 0.04, 0.09, mat(WHITE, { rough: 0.4 })), -0.3, topY + 0.04, -0.08),
    );
  },

  tv({ width = 1.7, variant, wallMounted = false }) {
    const wall = variant ? variant === 'wall' : Boolean(wallMounted);
    const sw = wall ? width : width * 0.84;
    const sh = sw * 0.5625;
    const screen = new THREE.MeshBasicMaterial({ color: '#0d1320', toneMapped: false });
    if (wall) {
      return group(
        at(box(sw * 0.42, sh * 0.38, 0.02, mat('#15171c', { rough: 0.5, metal: 0.4 }), { r: 0.004 }), 0, sh * 0.31, -0.022),
        at(box(sw + 0.02, sh + 0.02, 0.024, mat(BLACK, { rough: 0.35 }), { r: 0.006 }), 0, 0, 0),
        at(box(sw - 0.015, sh - 0.015, 0.006, screen, { r: 0 }), 0, 0.0175, 0.011),
      );
    }
    return group(
      at(box(width, 0.36, 0.4, mat(DARK_WOOD, { rough: 0.6 }), { r: 0.015 }), 0, 0.1, 0),
      ...legs(width, 0.4, 0.1, mat(BLACK), 0.08, 0.015),
      ...doorLines(width, 0.3, 0.13, 0.2, 3, mat(BLACK)),
      at(box(sw + 0.03, sh + 0.03, 0.035, mat(BLACK, { rough: 0.4 }), { r: 0.008 }), 0, 0.72, -0.15),
      at(box(sw - 0.02, sh - 0.02, 0.01, screen, { r: 0 }), 0, 0.745, -0.129),
      at(box(0.5, 0.07, 0.09, mat('#2a2c33', { rough: 0.7 }), { r: 0.02 }), 0, 0.46, 0.05),
    );
  },

  sideboard({ width = 1.6 }) {
    return group(
      ...legs(width, 0.42, 0.16, mat(BLACK), 0.07, 0.015),
      at(box(width, 0.6, 0.42, mat(WOOD, { rough: 0.6 }), { r: 0.015 }), 0, 0.16, 0),
      ...doorLines(width, 0.54, 0.19, 0.21, 4, mat(DARK_WOOD)),
      at(cyl(0.07, 0.05, 0.26, mat('#3d6b8c', { rough: 0.35 })), -width / 2 + 0.3, 0.76, 0),
      at(box(0.3, 0.05, 0.2, mat('#d8c9a8', { rough: 0.9 }), { r: 0.006 }), width / 2 - 0.35, 0.76, 0),
    );
  },

  diningSet({ width = 1.8, chairs = 6 }) {
    const depth = 0.95;
    const wood = mat('#b48d63', { rough: 0.55 });
    const g = group(
      at(box(width, 0.05, depth, wood, { r: 0.02 }), 0, 0.71, 0),
      ...legs(width, depth, 0.71, mat(BLACK, { rough: 0.5 }), 0.1, 0.028),
      at(cyl(0.16, 0.1, 0.07, mat(WHITE, { rough: 0.4 })), 0, 0.76, 0),
    );
    const perSide = Math.ceil(chairs / 2);
    for (let i = 0; i < chairs; i++) {
      const side = i < perSide ? 1 : -1;
      const k = i < perSide ? i : i - perSide;
      const n = i < perSide ? perSide : chairs - perSide;
      const c = chair('#2b2e37');
      c.position.set(-width / 2 + (width / n) * (k + 0.5), 0, side * (depth / 2 + 0.12));
      c.rotation.y = side > 0 ? Math.PI : 0;
      g.add(c);
    }
    return g;
  },

  island({ width = 2.0, stools = 3 }) {
    const g = group(
      at(box(width - 0.12, 0.88, 0.62, mat('#39424f', { rough: 0.7 }), { r: 0.015 }), 0, 0, -0.04),
      at(box(width, 0.05, 0.86, mat('#e9e7e2', { rough: 0.3 }), { r: 0.015 }), 0, 0.88, 0),
    );
    for (let i = 0; i < stools; i++) {
      const x = -width / 2 + (width / stools) * (i + 0.5);
      g.add(group(
        at(cyl(0.16, 0.16, 0.012, mat(BLACK, { rough: 0.4 })), x, 0, 0.62),
        at(cyl(0.015, 0.015, 0.64, mat(METAL, { rough: 0.3, metal: 0.8 }), 10), x, 0, 0.62),
        at(cyl(0.17, 0.15, 0.05, mat('#c28a5a', { rough: 0.9 })), x, 0.64, 0.62),
      ));
    }
    return g;
  },

  kitchen({ width = 3, upper = true, depth = 0.6, height = 0.9 }) {
    const front = mat('#e4e1da', { rough: 0.6 });
    const seam = mat('#b9b6ae');
    const n = Math.max(2, Math.round(width / 0.6));
    const baseH = Math.max(0.3, height - 0.04);
    const g = group(
      at(box(width, baseH, depth, front, { r: 0.008 }), 0, 0, 0),
      ...doorLines(width, Math.max(0.1, baseH - 0.08), 0.06, depth / 2, n, seam),
      at(box(width + 0.02, 0.04, depth + 0.03, mat('#33363d', { rough: 0.35 }), { r: 0.008 }), 0, baseH, 0.005),
      at(box(0.58, 0.012, Math.min(0.5, depth - 0.1), mat('#0c0d10', { rough: 0.15 }), { r: 0 }), -width / 4, height, 0),
      at(box(0.5, 0.012, Math.min(0.38, depth - 0.2), mat(METAL, { rough: 0.3, metal: 0.9 }), { r: 0 }), width / 4, height, 0.02),
      at(cyl(0.015, 0.015, 0.24, mat(METAL, { rough: 0.25, metal: 0.9 }), 10), width / 4, height, -depth / 2 + 0.08),
    );
    if (upper) {
      const upperZ = -depth / 2 + 0.175;
      g.add(
        at(box(width, 0.72, 0.35, front, { r: 0.008 }), 0, height + 0.58, upperZ),
        ...doorLines(width, 0.66, height + 0.61, upperZ + 0.175, n, seam),
        at(box(0.7, 0.1, 0.42, mat('#2f3239', { rough: 0.4, metal: 0.4 }), { r: 0.008 }), -width / 4, height + 0.52, -depth / 2 + 0.21),
      );
    }
    return g;
  },

  fridge() {
    const body = mat('#c5c9d0', { rough: 0.35, metal: 0.5 });
    return group(
      at(box(0.7, 1.92, 0.68, body, { r: 0.025 }), 0, 0, 0),
      at(box(0.66, 0.008, 0.005, mat('#7c8088'), { r: 0 }), 0, 1.25, 0.34),
      at(box(0.02, 0.5, 0.03, mat('#70747c', { metal: 0.7, rough: 0.3 }), { r: 0.008 }), -0.26, 1.34, 0.35),
      at(box(0.02, 0.4, 0.03, mat('#70747c', { metal: 0.7, rough: 0.3 }), { r: 0.008 }), -0.26, 0.76, 0.35),
    );
  },

  bed({ width = 1.6, color = '#7f8fb5', depth: frameDepth }) {
    const depth = frameDepth === undefined ? 2.1 : frameDepth - 0.04;
    const headboardZ = frameDepth === undefined ? -depth / 2 : -frameDepth / 2 + 0.05;
    const linen = mat('#f1efea', { rough: 1 });
    const g = group(
      at(box(width + 0.1, 0.26, depth + 0.04, mat(DARK_WOOD, { rough: 0.7 }), { r: 0.03 }), 0, 0.04, 0),
      at(box(width + 0.16, 1.02, 0.1, mat(darker(color, 0.6), { rough: 1 }), { r: 0.04 }), 0, 0, headboardZ),
      at(box(width, 0.2, depth - 0.06, linen, { r: 0.07 }), 0, 0.28, 0.02),
      at(box(width + 0.05, 0.13, depth * 0.63, mat(color, { rough: 1 }), { r: 0.06 }), 0, 0.4, depth * 0.17),
      at(box(width + 0.06, 0.05, 0.3, mat(darker(color, 0.8), { rough: 1 }), { r: 0.02 }), 0, 0.5, depth * 0.36),
    );
    for (const sx of [-1, 1]) {
      const pillow = at(box(width / 2 - 0.14, 0.13, 0.42, linen, { r: 0.06 }), sx * width / 4, 0.46, -depth / 2 + 0.36);
      pillow.rotation.x = -0.18;
      g.add(pillow);
    }
    return g;
  },

  nightstand() {
    return group(
      at(box(0.46, 0.44, 0.4, mat(WOOD, { rough: 0.6 }), { r: 0.015 }), 0, 0.06, 0),
      ...legs(0.46, 0.4, 0.06, mat(BLACK), 0.06, 0.014),
      at(box(0.4, 0.006, 0.005, mat(DARK_WOOD), { r: 0 }), 0, 0.28, 0.2),
    );
  },

  dresser({ width = 1.3, depth = 0.45, height = 0.84 }) {
    const bodyH = Math.max(0.2, height - 0.1);
    const g = group(
      ...legs(width, depth, 0.1, mat(BLACK), 0.06, 0.015),
      at(box(width, bodyH, depth, mat(WHITE, { rough: 0.6 }), { r: 0.015 }), 0, 0.1, 0),
      at(cyl(0.09, 0.07, 0.18, mat('#c9a15e', { rough: 0.4 })), width / 2 - 0.3, height, 0),
    );
    for (let i = 1; i < 3; i++) g.add(at(box(width - 0.06, 0.006, 0.005, mat('#b9b6ae'), { r: 0 }), 0, 0.1 + (bodyH / 3) * i, depth / 2 + 0.001));
    return g;
  },

  plant({ height = 1.2 }) {
    const rand = rng(Math.round(height * 1000));
    const leaves = [mat('#3f7d52', { rough: 0.9 }), mat('#4f9462', { rough: 0.9 }), mat('#35694a', { rough: 0.9 })];
    const g = group(
      at(cyl(0.17, 0.12, 0.3, mat('#d7d0c4', { rough: 0.8 })), 0, 0, 0),
      at(cyl(0.15, 0.15, 0.02, mat('#3a2c22', { rough: 1 })), 0, 0.285, 0),
      at(cyl(0.015, 0.02, height * 0.55, mat('#6b4a33', { rough: 1 }), 8), 0, 0.3, 0),
    );
    const count = Math.round(6 + height * 5);
    for (let i = 0; i < count; i++) {
      const t = i / (count - 1);
      const y = 0.5 + t * (height - 0.62);
      const spread = 0.28 * Math.sin(Math.PI * (0.25 + t * 0.7));
      const a = rand() * Math.PI * 2;
      const blob = new THREE.Mesh(new THREE.IcosahedronGeometry(0.13 + rand() * 0.1, 1), leaves[i % 3]);
      blob.position.set(Math.cos(a) * spread * rand(), y, Math.sin(a) * spread * rand());
      blob.scale.y = 0.75 + rand() * 0.3;
      g.add(blob);
    }
    return g;
  },

  vanity({ width = 1.0, variant, pedestal = false }) {
    const mirror = new THREE.MeshStandardMaterial({ color: '#b9c7dc', roughness: 0.12, metalness: 0.9 });
    const isPedestal = variant ? variant === 'pedestal' : Boolean(pedestal);
    if (isPedestal) {
      const ceramic = mat(WHITE, { rough: 0.18 });
      const chrome = mat(METAL, { rough: 0.18, metal: 0.92 });
      const bw = Math.min(width, 0.66);
      const bd = 0.46;
      const cabW = Math.min(width * 0.82, 0.72);
      const spoutCurve = new THREE.CatmullRomCurve3([
        new THREE.Vector3(0, 0.85, -0.15),
        new THREE.Vector3(0, 0.97, -0.14),
        new THREE.Vector3(0, 0.99, -0.07),
        new THREE.Vector3(0, 0.94, -0.04),
      ]);
      const spout = new THREE.Mesh(new THREE.TubeGeometry(spoutCurve, 12, 0.009, 8, false), chrome);
      const bowl = at(cyl(bw * 0.34, bw * 0.24, 0.025, mat('#dfe4ec', { rough: 0.15 })), 0, 0.84, 0.03);
      bowl.scale.z = 0.8;
      return group(
        at(cyl(0.11, 0.15, 0.07, ceramic, 24), 0, 0, -0.02),
        at(cyl(0.085, 0.105, 0.68, ceramic, 24), 0, 0.06, -0.02),
        at(box(bw, 0.13, bd, ceramic, { r: 0.055 }), 0, 0.73, 0.01),
        bowl,
        at(cyl(0.022, 0.022, 0.006, chrome, 16), 0, 0.863, 0.03),
        at(cyl(0.02, 0.024, 0.02, chrome, 14), 0, 0.855, -0.15),
        spout,
        at(box(0.055, 0.012, 0.016, chrome, { r: 0.004 }), 0.035, 0.89, -0.15),
        at(box(cabW, 0.72, 0.13, mat(WHITE, { rough: 0.45 }), { r: 0.01 }), 0, 1.12, -0.175),
        at(box(cabW - 0.03, 0.69, 0.015, mirror, { r: 0.006 }), 0, 1.135, -0.105),
        at(box(0.012, 0.08, 0.018, chrome, { r: 0.004 }), cabW / 2 - 0.035, 1.24, -0.095),
      );
    }
    return group(
      at(box(width, 0.62, 0.48, mat(WOOD, { rough: 0.6 }), { r: 0.012 }), 0, 0.2, 0),
      ...doorLines(width, 0.56, 0.23, 0.24, 2, mat(DARK_WOOD)),
      at(box(width + 0.03, 0.04, 0.5, mat(WHITE, { rough: 0.25 }), { r: 0.012 }), 0, 0.82, 0),
      at(cyl(0.19, 0.15, 0.1, mat(WHITE, { rough: 0.2 })), 0, 0.86, 0.02),
      at(cyl(0.012, 0.012, 0.2, mat(METAL, { rough: 0.2, metal: 0.9 }), 10), 0, 0.86, -0.18),
      at(box(width * 0.82, 0.8, 0.025, mirror, { r: 0.01 }), 0, 1.08, -0.225),
    );
  },

  bathtub() {
    return group(
      at(box(1.7, 0.56, 0.78, mat(WHITE, { rough: 0.25 }), { r: 0.1 }), 0, 0, 0),
      at(box(1.5, 0.02, 0.58, mat('#9fd3ec', { rough: 0.1, emissive: '#1d4f6b', emissiveIntensity: 0.25 }), { r: 0.009 }), 0, 0.545, 0),
      at(cyl(0.014, 0.014, 0.2, mat(METAL, { rough: 0.2, metal: 0.9 }), 10), -0.74, 0.56, 0),
    );
  },

  toilet() {
    const c = mat(WHITE, { rough: 0.25 });
    const bowl = at(cyl(0.19, 0.13, 0.4, c), 0, 0, 0.1);
    bowl.scale.z = 1.25;
    const lid = at(cyl(0.2, 0.2, 0.03, c), 0, 0.4, 0.1);
    lid.scale.z = 1.25;
    return group(at(box(0.38, 0.78, 0.17, c, { r: 0.03 }), 0, 0, -0.24), bowl, lid);
  },

  desk({ width = 1.4, depth = 0.65, height = 0.76 }) {
    const legH = Math.max(0.3, height - 0.04);
    const c = chair('#2b2e37');
    c.position.z = depth / 2 + 0.175;
    c.rotation.y = Math.PI;
    const monitorZ = -depth / 2 + 0.145;
    return group(
      at(box(width, 0.04, depth, mat(WOOD, { rough: 0.55 }), { r: 0.012 }), 0, legH, 0),
      ...legs(width, depth, legH, mat(BLACK), 0.06, 0.02),
      at(box(0.56, 0.34, 0.025, mat(BLACK, { rough: 0.3 }), { r: 0.008 }), 0, height + 0.1, monitorZ),
      at(box(0.2, 0.1, 0.12, mat(BLACK), { r: 0.008 }), 0, height, monitorZ),
      c,
    );
  },

  wardrobe({ width = 1.6, height = 2.1, color = WHITE }) {
    const bodyMat = mat(color, { rough: 0.6 });
    const trimMat = mat(darker(color, 0.78), { rough: 0.65 });
    const handleMat = mat(METAL, { rough: 0.3, metal: 0.8 });
    const toeH = 0.06;
    const corniceH = 0.04;
    const bodyH = Math.max(0.4, height - toeH - corniceH);
    const doors = Math.max(2, Math.round(width / 0.55));
    const handles = [];
    const dw = width / doors;
    for (let i = 0; i < doors; i++) {
      const cx = -width / 2 + dw * (i + 0.5);
      const offset = (i % 2 === 0 ? 1 : -1) * Math.min(dw * 0.32, 0.18);
      handles.push(at(box(0.014, 0.16, 0.02, handleMat, { r: 0.004 }), cx + offset, toeH + bodyH * 0.45, 0.31));
    }
    return group(
      at(box(width - 0.04, toeH, 0.56, trimMat, { r: 0.004 }), 0, 0, -0.015),
      at(box(width, bodyH, 0.6, bodyMat, { r: 0.012 }), 0, toeH, 0),
      at(box(width + 0.03, corniceH, 0.63, trimMat, { r: 0.008 }), 0, toeH + bodyH, 0.005),
      ...doorLines(width, bodyH - 0.04, toeH + 0.02, 0.302, doors, trimMat),
      ...handles,
    );
  },

  bookshelf({ width = 1.0, height = 1.8 }) {
    const rand = rng(Math.round(width * 100 + height * 7));
    const wood = mat(WOOD, { rough: 0.6 });
    const g = group(at(box(width, height, 0.04, wood, { r: 0 }), 0, 0, -0.14));
    for (const sx of [-1, 1]) g.add(at(box(0.03, height, 0.32, wood, { r: 0 }), sx * (width / 2 - 0.015), 0, 0));
    const shelves = Math.round(height / 0.38);
    const colors = ['#c9553f', '#3d6b8c', '#d8c9a8', '#4f9462', '#8b93a7', '#d9b98a'];
    for (let i = 0; i <= shelves; i++) {
      const y = (height - 0.03) * (i / shelves);
      g.add(at(box(width, 0.03, 0.32, wood, { r: 0 }), 0, y, 0));
      if (i === shelves) break;
      let x = -width / 2 + 0.06;
      while (x < width / 2 - 0.12) {
        const bw = 0.03 + rand() * 0.04;
        const bh = 0.2 + rand() * 0.1;
        g.add(at(box(bw, bh, 0.2, mat(colors[Math.floor(rand() * colors.length)], { rough: 0.9 }), { r: 0 }), x + bw / 2, y + 0.03, 0));
        x += bw + 0.004;
        if (rand() < 0.12) x += 0.12;
      }
    }
    return g;
  },

  // A straight flight up to the floor above: you step on at the front (+z) and climb towards the back.
  stairs({ width = 1, depth = 2.8, height = 2.9 }) {
    const steps = Math.max(3, Math.round(height / 0.18));
    const rise = height / steps;
    const run = depth / steps;
    const body = mat('#d9d4cb', { rough: 0.9 });
    const tread = mat(WOOD, { rough: 0.6 });
    const g = new THREE.Group();
    for (let i = 0; i < steps; i++) {
      const z = depth / 2 - run * (i + 0.5);
      g.add(at(box(width, rise * i + rise - 0.03, run, body, { r: 0 }), 0, 0, z));
      g.add(at(box(width + 0.02, 0.03, run + 0.02, tread, { r: 0.008 }), 0, rise * (i + 1) - 0.03, z));
    }
    // A handrail along the open side.
    const rail = mat(BLACK, { rough: 0.5 });
    const slope = Math.atan2(height, depth);
    const length = Math.hypot(height, depth);
    const bar = at(box(0.04, 0.04, length, rail, { r: 0.015 }), width / 2 - 0.03, height / 2 + 0.9, 0);
    bar.rotation.x = slope;
    g.add(bar);
    for (const t of [0.1, 0.5, 0.9]) {
      g.add(at(box(0.025, 0.9, 0.025, rail, { r: 0 }), width / 2 - 0.03, height * t, depth / 2 - depth * t));
    }
    return g;
  },
};

export const FURNITURE_TYPES = Object.keys(builders);

// Approximate [width, depth] of each piece, for the 2D plan editor.
export function footprint(item) {
  const w = item.width;
  switch (item.type) {
    case 'rug': return item.size || [2, 1.4];
    case 'sofa': return [w || 2.2, 0.95];
    case 'pillow': return [w || 0.38, 0.16];
    case 'armchair': return [0.92, 0.88];
    case 'coffeeTable': return [w || 1.1, item.depth || 0.58];
    case 'tv': return [w || 1.7, isWallMounted(item) ? 0.055 : 0.4];
    case 'sideboard': return [w || 1.6, 0.42];
    case 'diningSet': return [w || 1.8, 1.9];
    case 'island': return [w || 2, 1.1];
    case 'kitchen': return [w || 3, item.depth || 0.62];
    case 'fridge': return [0.7, 0.68];
    case 'bed': return [(w || 1.6) + 0.1, item.depth || 2.14];
    case 'nightstand': return [0.46, 0.4];
    case 'dresser': return [w || 1.3, item.depth || 0.45];
    case 'plant': return [0.45, 0.45];
    case 'vanity': return [w || 1, 0.5];
    case 'bathtub': return [1.7, 0.78];
    case 'toilet': return [0.4, 0.66];
    case 'desk': return [w || 1.4, item.depth || 0.65];
    case 'wardrobe': return [w || 1.6, 0.6];
    case 'bookshelf': return [w || 1, 0.32];
    case 'stairs': return [w || 1, item.depth || 2.8];
    default: return [0.6, 0.6];
  }
}

// Top-surface height in metres above `item.y || 0` for any support piece, or null for non-supports.
export function surfaceHeight(item) {
  switch (item?.type) {
    case 'sofa':
    case 'armchair': return 0.47;
    case 'bed': return 0.48;
    case 'coffeeTable': return item.height ?? 0.4;
    case 'sideboard':
    case 'diningSet': return 0.76;
    case 'island': return 0.93;
    case 'kitchen': return item.height ?? 0.9;
    case 'fridge': return 1.92;
    case 'nightstand': return 0.5;
    case 'dresser': return item.height ?? 0.84;
    case 'desk': return item.height ?? 0.76;
    case 'bookshelf': return item.height ?? 1.8;
    case 'wardrobe': return item.height ?? 2.1;
    case 'tv': return isWallMounted(item) ? null : 0.46;
    case 'rug':
    case 'plant':
    case 'bathtub':
    case 'toilet':
    case 'stairs':
    case 'pillow':
    default: return null;
  }
}

export function buildFurniture(items) {
  const root = new THREE.Group();
  for (const item of items) {
    const make = builders[item.type];
    if (!make || !Array.isArray(item.pos)) {
      console.warn(`[plan] skipping furniture of unknown type "${item.type}"`);
      continue;
    }
    const g = make(item);
    g.position.set(item.pos[0], item.y || 0, item.pos[1]);
    g.rotation.y = THREE.MathUtils.degToRad(item.rot || 0);
    const flat = g.userData.flat;
    g.traverse((o) => {
      if (o.isMesh) { o.castShadow = !flat; o.receiveShadow = true; }
    });
    root.add(g);
  }
  return root;
}
