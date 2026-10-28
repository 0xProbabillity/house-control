// Where the 3D stage ends and the controls begin on a phone's screen. Every iPhone stacks
// them; a wide screen (iPhone Duo open, or the app given a wide window) puts them side by
// side, one on each half; and a half-folded iPhone Duo breaks the two exactly at its fold,
// so nothing ever sits across the crease:
//   'stack'  3D above, controls below. `start` is the stage's height when the screen asks
//            for one (the flat Duo held upright: its crease), else the CSS decides.
//   'split'  3D on the leading side up to `start`, controls on the trailing side from `end`.
//   'table'  half-folded like a laptop on a table: 3D on the upper half up to `start`,
//            controls on the lower half from `end`.
// `fold` is the active fold as the native app reports it (a rect in page px), or null when
// the screen is flat or has none.

const SPLIT_MIN_WIDTH = 720;    // narrower than this, a landscape screen still stacks
const PANEL_MIN = 360;
const PANEL_MAX = 480;
const TALL_WIDE = 600;          // an upright screen this wide is a Duo's inner one: stack on its crease

export function phoneLayout(width, height, fold) {
  if (fold && fold.width > 0 && fold.height > fold.width) {
    return { kind: 'split', start: fold.x, end: fold.x + fold.width };
  }
  if (fold && fold.height > 0) {
    return { kind: 'table', start: fold.y, end: fold.y + fold.height };
  }
  if (width >= SPLIT_MIN_WIDTH && width > height * 1.15) {
    const panel = Math.min(PANEL_MAX, Math.max(PANEL_MIN, width / 2));
    return { kind: 'split', start: width - panel, end: width - panel };
  }
  if (width >= TALL_WIDE && height > width) {
    return { kind: 'stack', start: Math.round(height / 2) };
  }
  return { kind: 'stack', start: null };
}

export const sameLayout = (a, b) => a && b && a.kind === b.kind && a.start === b.start && a.end === b.end;
