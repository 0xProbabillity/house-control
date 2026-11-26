// Pure surface-stacking helpers for the 2D plan editor (no DOM dependencies).
import { footprint, surfaceHeight, isWallMounted } from '../three/furniture.js';

/**
 * True if world point `[px, pz]` lies inside `target`'s rotated footprint.
 *
 * In Three.js (right-handed, Y-up) with `rotation.y = a`:
 *   dx =  lx * cos(a) + lz * sin(a)
 *   dz = -lx * sin(a) + lz * cos(a)
 * Inverse transform into `target`'s local frame:
 *   lx =  dx * cos(a) - dz * sin(a)
 *   lz =  dx * sin(a) + dz * cos(a)
 */
export function pointInFootprint([px, pz], target) {
  if (!Array.isArray(target?.pos)) return false;
  const [tx, tz] = target.pos;
  const [w, d] = footprint(target);
  const a = ((target.rot || 0) * Math.PI) / 180;
  const cos = Math.cos(a);
  const sin = Math.sin(a);
  const dx = px - tx;
  const dz = pz - tz;
  const lx = dx * cos - dz * sin;
  const lz = dx * sin + dz * cos;
  return Math.abs(lx) <= w / 2 + 0.01 && Math.abs(lz) <= d / 2 + 0.01;
}

/**
 * Returns the highest top-surface elevation `(other.y || 0) + surfaceHeight(other)`
 * among same-level furniture items (not in `excludedIndices`) whose footprint contains `item.pos`,
 * or `0` if none support it.
 */
export function supportElevation(item, furnitureList, excludedIndices = new Set(), levelOf) {
  if (!Array.isArray(item?.pos) || !Array.isArray(furnitureList)) return 0;
  const itemLevel = levelOf ? levelOf(item) : item.level;
  let best = 0;
  for (let i = 0; i < furnitureList.length; i++) {
    if (excludedIndices.has(i)) continue;
    const other = furnitureList[i];
    if (!other || !Array.isArray(other.pos)) continue;
    if ((levelOf ? levelOf(other) : other.level) !== itemLevel) continue;
    const h = surfaceHeight(other);
    if (!(typeof h === 'number' && Number.isFinite(h) && h > 0)) continue;
    if (!pointInFootprint(item.pos, other)) continue;
    const top = (other.y || 0) + h;
    if (top > best) best = top;
  }
  return best;
}

/**
 * Returns a Set of indices of all same-level items resting directly or transitively
 * on top of `furnitureList[rootIndex]`.
 */
export function stackedRiders(rootIndex, furnitureList, levelOf) {
  const riders = new Set();
  if (!Array.isArray(furnitureList) || rootIndex < 0 || rootIndex >= furnitureList.length) return riders;
  const visited = new Set([rootIndex]);
  const queue = [rootIndex];
  while (queue.length) {
    const idx = queue.shift();
    const base = furnitureList[idx];
    if (!base || !Array.isArray(base.pos)) continue;
    const h = surfaceHeight(base);
    if (!(typeof h === 'number' && Number.isFinite(h) && h > 0)) continue;
    const topY = (base.y || 0) + h;
    const baseLevel = levelOf ? levelOf(base) : base.level;
    for (let j = 0; j < furnitureList.length; j++) {
      if (visited.has(j)) continue;
      const candidate = furnitureList[j];
      if (!candidate || !Array.isArray(candidate.pos)) continue;
      if (isWallMounted(candidate)) continue;
      if ((levelOf ? levelOf(candidate) : candidate.level) !== baseLevel) continue;
      if (Math.abs((candidate.y || 0) - topY) < 0.04 && pointInFootprint(candidate.pos, base)) {
        visited.add(j);
        riders.add(j);
        queue.push(j);
      }
    }
  }
  return riders;
}
