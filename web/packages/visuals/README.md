# @house-control/visuals (proposed)

Shared browser-independent floor-plan parsing and Three.js model rendering for House Control applications.

This package currently lives in the main repository's `web/packages/visuals` directory. It is **private and not published**. The main web app consumes it as a local `file:` dependency. A TV port can consume it after upstream agrees on versioning and distribution. This extraction intentionally does not change any scene execution or provider logic.

```js
import { normalize, createWorld } from '@house-control/visuals';

const plan = normalize(rawPlan);
const world = createWorld(canvas, plan, store, {
  onHover() {},
  onPick() {},
});
```

The caller supplies the canvas, normalized plan, and state store with `state.lights`, `state.acs`, and an `on(listener)` subscription function. Lifecycle, credentials, device APIs, TV navigation, app services, and floor-plan loading remain the caller's responsibility.

The original `web/src/config.js` and `web/src/three/*.js` locations remain compatibility re-exports, so the Mac/iPhone web bundle does not need a UI rewrite.

Before external distribution, agree on package name, public API compatibility, ownership of Three.js versions, and whether to publish an npm package or vendor a pinned source revision.
