// Writes Resources/sample-home.json: the demo apartment in its "Cozy" scene, which the
// widgets show until the app has written the real home (the widget gallery, a fresh install).
//   node widgets/make-sample.mjs
import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

globalThis.window = globalThis;
globalThis.location = { search: '' };
globalThis.localStorage = { getItem: () => null, setItem() {} };

const web = fileURLToPath(new URL('../web/', import.meta.url));
const { normalize } = await import(`${web}src/config.js`);
const { createStore } = await import(`${web}src/store.js`);
const { widgetSnapshot } = await import(`${web}src/widgets.js`);

const config = normalize(JSON.parse(readFileSync(`${web}public/plans/home.json`, 'utf8')));
const store = createStore(config);
store.applyScene('cozy');
store.setAC(config.acs[0].id, { on: true, target: 23 });
for (const ac of Object.values(store.state.acs)) ac.roomTemp = 25.4;
const snapshot = { ...widgetSnapshot(config, store, 'home'), updated: 0 };
writeFileSync(new URL('Resources/sample-home.json', import.meta.url), `${JSON.stringify(snapshot)}\n`);
process.exit(0); // the store's simulation timer would keep node running
