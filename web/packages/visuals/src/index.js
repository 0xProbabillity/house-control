// Pure floor-plan model and renderer; no native bridge or device transport.
export { ConfigError, LIGHT_KINDS, LINK_FIELDS, SERVICES, FLOOR_KINDS, SLAB, levelsOf, wallMount, linkOf, isLinked, normalize } from './config.js';
export { STAGE_BG, createWorld } from './three/world.js';
export { FURNITURE_TYPES, footprint } from './three/furniture.js';
