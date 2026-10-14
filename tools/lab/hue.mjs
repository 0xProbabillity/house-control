// A pretend Philips Hue Bridge for testing House Control's Hue support without hardware.
// It speaks the bridge's local API (CLIP v2 over HTTPS with a self-signed certificate,
// link-button pairing, the event stream) for a handful of lamps and a motion sensor with a
// thermometer, and announces itself on the network as a Hue Bridge does.
//
//   cd tools/lab && npm run hue          then: Edit Home… → Connections → Philips Hue
//
// Pairing needs the round button: press Enter here to "press" it (or start with --auto,
// which presses it for every pairing attempt). Changes made by an app are printed.
// Needs openssl (macOS has it) to make the certificate, kept in tools/lab/.hue.
import https from 'node:https';
import { execFileSync, spawn } from 'node:child_process';
import { randomUUID, randomBytes } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const here = path.dirname(fileURLToPath(import.meta.url));
const dir = path.join(here, '.hue');
mkdirSync(dir, { recursive: true });
const PORT = Number(process.env.PORT || 8443);
const AUTO = process.argv.includes('--auto');
const BRIDGE_ID = 'ECB5FAFFFE0LAB01';

// Like a real bridge: a self-signed certificate whose common name is the bridge id.
const keyFile = path.join(dir, 'key.pem'), certFile = path.join(dir, 'cert.pem');
if (!existsSync(certFile)) {
  execFileSync('openssl', ['req', '-x509', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:prime256v1', '-nodes',
    '-keyout', keyFile, '-out', certFile, '-days', '3650', '-subj', `/C=NL/O=Philips Hue/CN=${BRIDGE_ID.toLowerCase()}`], { stdio: 'ignore' });
}

// Paired apps survive a restart.
const keysFile = path.join(dir, 'keys.json');
const keys = new Set(existsSync(keysFile) ? JSON.parse(readFileSync(keysFile, 'utf8')) : []);
let buttonUntil = 0;
const press = () => { buttonUntil = Date.now() + 30_000; console.log('● Link button pressed: pairing is open for 30 s'); };

const id = () => randomUUID();
const resources = [];
const add = (r) => { resources.push(r); return r; };

function device(name, archetype) {
  return add({ id: id(), type: 'device', metadata: { name, archetype }, product_data: { manufacturer_name: 'Signify Netherlands B.V.' }, services: [] });
}
function light(name, room, { dim = true, ct = false, colour = false, archetype = 'classic_bulb' } = {}) {
  const dev = device(name, archetype);
  const l = add({
    id: id(), id_v1: `/lights/${resources.filter((r) => r.type === 'light').length + 1}`, type: 'light',
    owner: { rid: dev.id, rtype: 'device' }, metadata: { name, archetype }, on: { on: false }, mode: 'normal',
  });
  if (dim) l.dimming = { brightness: 80, min_dim_level: 0.2 };
  if (ct) l.color_temperature = { mirek: 366, mirek_valid: true, mirek_schema: { mirek_minimum: 153, mirek_maximum: 500 } };
  if (colour) l.color = { xy: { x: 0.4573, y: 0.41 }, gamut_type: 'C', gamut: { red: { x: 0.6915, y: 0.3083 }, green: { x: 0.17, y: 0.7 }, blue: { x: 0.1532, y: 0.0475 } } };
  dev.services.push({ rid: l.id, rtype: 'light' });
  const zigbee = add({ id: id(), type: 'zigbee_connectivity', owner: { rid: dev.id, rtype: 'device' }, status: 'connected' });
  dev.services.push({ rid: zigbee.id, rtype: 'zigbee_connectivity' });
  room.children.push({ rid: dev.id, rtype: 'device' });
  return l;
}
function room(name, archetype) { return add({ id: id(), type: 'room', metadata: { name, archetype }, children: [], services: [] }); }

const bridgeDevice = device('Hue Bridge Lab', 'bridge_v2');
const bridge = add({ id: id(), type: 'bridge', owner: { rid: bridgeDevice.id, rtype: 'device' }, bridge_id: BRIDGE_ID.toLowerCase(), time_zone: { time_zone: 'Europe/Amsterdam' } });
bridgeDevice.services.push({ rid: bridge.id, rtype: 'bridge' });

const living = room('Living room', 'living_room');
const bedroom = room('Bedroom', 'bedroom');
const kitchen = room('Kitchen', 'kitchen');
light('Hue color lamp', living, { ct: true, colour: true, archetype: 'sultan_bulb' });
light('Hue Play', living, { ct: true, colour: true, archetype: 'hue_play' });
light('Hue white ambiance', bedroom, { ct: true, archetype: 'pendant_round' });
light('Hue white lamp', kitchen, { archetype: 'ceiling_round' });
light('Hue smart plug', living, { dim: false, archetype: 'plug' });
const sensorDevice = device('Hue motion sensor', 'unknown_archetype');
const thermometer = add({ id: id(), type: 'temperature', owner: { rid: sensorDevice.id, rtype: 'device' }, enabled: true,
  temperature: { temperature: 22.4, temperature_valid: true, temperature_report: { changed: new Date().toISOString(), temperature: 22.4 } } });
sensorDevice.services.push({ rid: thermometer.id, rtype: 'temperature' });
living.children.push({ rid: sensorDevice.id, rtype: 'device' });

// The event stream.
const listeners = new Set();
function emit(type, data) {
  const event = `id: ${Date.now()}:0\ndata: ${JSON.stringify([{ creationtime: new Date().toISOString(), id: id(), type, data }])}\n\n`;
  for (const res of listeners) res.write(event);
}
setInterval(() => {
  const t = Math.round((thermometer.temperature.temperature + (Math.random() - 0.5) * 0.4) * 10) / 10;
  thermometer.temperature.temperature = t;
  thermometer.temperature.temperature_report = { changed: new Date().toISOString(), temperature: t };
  emit('update', [{ id: thermometer.id, type: 'temperature', temperature: thermometer.temperature }]);
}, 30_000);

const json = (res, status, body) => { res.writeHead(status, { 'Content-Type': 'application/json' }); res.end(JSON.stringify(body)); };
const merge = (target, patch) => {
  for (const [k, v] of Object.entries(patch)) {
    if (v && typeof v === 'object' && !Array.isArray(v) && target[k] && typeof target[k] === 'object') merge(target[k], v);
    else target[k] = v;
  }
};

const server = https.createServer({ key: readFileSync(keyFile), cert: readFileSync(certFile) }, (req, res) => {
  let body = '';
  req.on('data', (c) => { body += c; });
  req.on('end', () => {
    const url = new URL(req.url, 'https://bridge');
    if (req.method === 'POST' && url.pathname === '/api') {
      if (AUTO) press();
      if (Date.now() > buttonUntil) return json(res, 200, [{ error: { type: 101, address: '', description: 'link button not pressed' } }]);
      const username = randomBytes(20).toString('hex');
      keys.add(username);
      writeFileSync(keysFile, JSON.stringify([...keys]));
      console.log(`✓ Paired ${JSON.parse(body || '{}').devicetype || 'an app'}`);
      return json(res, 200, [{ success: { username, clientkey: randomBytes(16).toString('hex').toUpperCase() } }]);
    }
    if (!keys.has(req.headers['hue-application-key'])) return json(res, 403, { errors: [{ description: 'unauthorized user' }], data: [] });

    if (url.pathname === '/eventstream/clip/v2') {
      res.writeHead(200, { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache', Connection: 'keep-alive', 'X-Content-Type-Options': 'nosniff' });
      res.write(': hi\n\n');
      listeners.add(res);
      res.on('close', () => listeners.delete(res));
      return;
    }
    const m = url.pathname.match(/^\/clip\/v2\/resource\/([a-z_]+)(?:\/([0-9a-f-]+))?$/);
    if (!m) return json(res, 404, { errors: [{ description: `unknown resource ${url.pathname}` }], data: [] });
    const [, type, rid] = m;
    const list = resources.filter((r) => r.type === type && (!rid || r.id === rid));
    if (req.method === 'GET') return json(res, rid && !list.length ? 404 : 200, { errors: [], data: list });
    if (req.method === 'PUT' && rid && list.length) {
      let patch;
      try { patch = JSON.parse(body); } catch { return json(res, 400, { errors: [{ description: 'body contains invalid JSON' }], data: [] }); }
      const target = list[0];
      if (patch.color_temperature?.mirek != null) { patch.color_temperature.mirek_valid = true; }
      if (patch.color?.xy && target.color_temperature) { target.color_temperature.mirek = null; target.color_temperature.mirek_valid = false; }
      if (patch.dimming && !target.dimming) return json(res, 400, { errors: [{ description: 'device (dimming) is not available' }], data: [] });
      merge(target, patch);
      console.log(`${new Date().toLocaleTimeString()}  ${target.metadata?.name.padEnd(20)} ${JSON.stringify(patch)}`);
      emit('update', [{ id: target.id, type, ...patch }]);
      return json(res, 200, { errors: [], data: [{ rid: target.id, rtype: type }] });
    }
    json(res, 405, { errors: [{ description: 'method not available' }], data: [] });
  });
});

server.listen(PORT, () => {
  // Announce it the way a bridge does (dns-sd ships with macOS).
  const announcer = spawn('dns-sd', ['-R', 'Hue Bridge Lab', '_hue._tcp', 'local', String(PORT), `bridgeid=${BRIDGE_ID.toLowerCase()}`, 'modelid=BSB002'], { stdio: 'ignore' });
  process.on('exit', () => announcer.kill());
  process.on('SIGINT', () => process.exit(0));
  console.log(`Hue Bridge Lab is on https://localhost:${PORT} and announced as “Hue Bridge Lab”.`);
  console.log(AUTO ? 'The link button presses itself for every pairing attempt.' : 'Press Enter to press the link button.');
});
process.stdin.on('data', press);
