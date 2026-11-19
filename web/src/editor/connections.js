// The editor's "Connections": the smart home platforms House Control can link the plan's
// lamps and ACs to (Smart Life, Home Assistant, Philips Hue, Apple Home), the screens that
// connect each one, and the pickers that link a lamp or an AC to one of their devices.
import { h } from '../ui/dom.js';
import { icon } from '../ui/icons.js';
import { isNative, call } from '../bridge.js';
import { SERVICES, linkOf } from '../config.js';
import { t, tn, lang, locale } from '../i18n.js';

const ORDER = ['smartlife', 'homeassistant', 'hue', 'homekit'];
const LOOK = {
  smartlife: { icon: 'plug', tint: '#ff7a3d', blurb: t('Tuya, Smart Life and the many brands built on them') },
  homeassistant: { icon: 'homeassistant', tint: '#18bcf2', blurb: t('Everything it runs: Zigbee, Matter, Nest, Xiaomi, Sonoff…') },
  hue: { icon: 'bulb', tint: '#c38bff', blurb: t('A Hue Bridge on this network. No account needed') },
  homekit: { icon: 'home', tint: '#ffb340', blurb: t('HomeKit and Matter accessories, through your iPhone') },
};
const KIND_TITLES = { light: t('Lights and plugs'), ac: t('Air conditioners'), sensor: t('Temperature sensors') };
// What a lamp can do, as the note after linking one names it.
const CAPABILITY_LABEL = { brightness: t('brightness'), temp: t('white temperature'), color: t('colour') };

export function createConnections({ rerender, toast, usedBy, onOpen }) {
  const boot = window.__HOUSE_BOOT__ || {};
  const state = {
    info: boot.services || {},
    devices: null,
    errors: {},
    loading: false,
    found: {},       // service -> discovered servers / bridges
    scanning: {},
    pairing: null,   // { host, until } while waiting for the Hue button
  };

  // The platforms this app offers: the native side lists them (the iPhone's App Store
  // edition has no Smart Life). A plain browser shows them all.
  const offered = () => (isNative && boot.services ? ORDER.filter((id) => id in state.info) : ORDER);
  const connected = (id) => Boolean(state.info[id]?.connected);
  const anyConnected = () => offered().some(connected);
  const devicesOf = (id) => (state.devices || []).filter((d) => d.service === id);

  async function refreshInfo() {
    if (!isNative) return;
    try { state.info = await call('services.info'); } catch { /* keep what we had */ }
  }

  async function load({ quiet = false } = {}) {
    if (!isNative || !anyConnected()) { state.devices = null; rerender(); return; }
    state.loading = true;
    if (!quiet) rerender();
    try {
      const r = await call('devices.all');
      state.devices = r.devices;
      state.errors = r.errors || {};
    } catch (e) {
      state.errors = { all: e.message };
    }
    state.loading = false;
    rerender();
  }

  // The Mac pushes this when the paired iPhone sent its Apple Home devices.
  window.house = window.house || {};
  window.house.servicesChanged = (info) => { state.info = info; load({ quiet: true }); };

  /* ---------- sidebar ---------- */

  function sidebarRow(active, select) {
    const n = offered().filter(connected).length;
    return h(`button.row.tuya-row${active ? '.active' : ''}`, { onclick: select },
      icon('link', 15), h('span.row-name', t('Connections')),
      h(`span.pill${n ? '.on' : ''}`, n ? tn(n, '{n} connected', '{n} connected') : t('Demo mode')));
  }

  /* ---------- overview ---------- */

  function tile(id, size = 34) {
    return h('span.svc-tile', { vars: { '--tint': LOOK[id].tint, '--size': `${size}px` } }, icon(LOOK[id].icon, Math.round(size * 0.52), 2));
  }

  function statusText(id) {
    const info = state.info[id] || {};
    if (id === 'homekit' && info.remote) {
      if (!info.connected) return t('Set up on your iPhone');
      return info.from ? tn(info.count, '{n} device from {device}', '{n} devices from {device}', { device: info.from })
        : tn(info.count, '{n} device from your iPhone', '{n} devices from your iPhone');
    }
    if (!info.connected) return t('Not connected');
    const count = devicesOf(id).length;
    const name = id === 'homeassistant' ? info.name : id === 'hue' ? info.name : id === 'smartlife' ? info.account : '';
    return [name, state.devices ? tn(count, '{n} device', '{n} devices') : null].filter(Boolean).join(' · ') || t('Connected');
  }

  function overview() {
    if (anyConnected() && !state.devices && !state.loading) setTimeout(() => load(), 0);
    return [
      h('div.svc-cards', offered().map((id) => h('button.svc-card', { onclick: () => onOpen(id) },
        tile(id),
        h('div.svc-text', h('b', SERVICES[id].name), h('span', LOOK[id].blurb)),
        h(`span.svc-status${connected(id) ? '.on' : ''}`, connected(id) ? icon('ok', 13, 2.4) : null, statusText(id)),
        icon('next', 16)))),
      h('p.note', t('Lamps and ACs stay simulated until you link them: pick one on the plan, then choose its device under “Real device”. One home can mix them all.')),
      isNative ? null : h('p.note.bad', t('Connecting works inside the House Control app (this is the browser preview).')),
    ];
  }

  /* ---------- shared pieces ---------- */

  const section = (title, ...nodes) => h('section.block', h('h3', title), nodes);

  function deviceList(id) {
    if (state.loading) return h('p.note.busy', icon('spinner', 13), t('Asking for the devices…'));
    if (state.errors[id]) return h('p.note.bad', state.errors[id]);
    const list = devicesOf(id);
    if (!state.devices) return null;
    if (!list.length) return h('p.note', t('Connected, but no lamps, air conditioners or temperature sensors were found.'));
    const used = usedBy();
    const groups = ['light', 'ac', 'sensor'].map((kind) => [kind, list.filter((d) => d.kind === kind)]).filter(([, l]) => l.length);
    return h('div.devices-list', groups.map(([kind, items]) => [
      h('h3', `${KIND_TITLES[kind]} · ${items.length}`),
      items.map((d) => h('div.device',
        h(`span.dot${d.online ? '.on' : ''}`, { title: d.online ? t('Online') : t('Offline') }),
        h('div', h('b', d.name), h('span', [d.room, d.detail].filter(Boolean).join(' · ') || d.id)),
        used.get(`${d.service}|${d.id}`) ? h('span.pill.on', used.get(`${d.service}|${d.id}`)) : null)),
    ]));
  }

  function connectedHeader(id, title, name, line) {
    return section(title,
      h('div.device', h('span.dot.on'), h('div', h('b', name), h('span', line))),
      h('div.fields',
        h('button.btn', { onclick: () => load() }, t('Refresh devices')),
        h('button.btn', { onclick: () => disconnect(id) }, t('Disconnect'))));
  }

  async function disconnect(id) {
    try {
      state.info = await call('service.disconnect', { service: id });
      state.devices = state.devices?.filter((d) => d.service !== id) ?? null;
      toast(t('{service} disconnected', { service: SERVICES[id].name }));
    } catch (e) { toast(e.message, true); }
    rerender();
  }

  async function scan(id) {
    if (!isNative || state.scanning[id]) return;
    state.scanning[id] = true;
    rerender();
    try {
      state.found[id] = (await call('services.discover', { service: id })).found;
    } catch { state.found[id] = []; }
    state.scanning[id] = false;
    rerender();
  }

  /* ---------- Home Assistant ---------- */

  const ha = { url: '', token: '', error: null, busy: false };

  function homeAssistant() {
    const info = state.info.homeassistant || {};
    if (info.connected) {
      if (!state.devices && !state.loading) setTimeout(() => load(), 0);
      return [connectedHeader('homeassistant', t('Server'), info.name, [info.url, info.version && t('version {version}', { version: info.version })].filter(Boolean).join(' · ')),
        deviceList('homeassistant')];
    }
    if (!state.found.homeassistant && !state.scanning.homeassistant) setTimeout(() => scan('homeassistant'), 0);
    const url = h('input', { type: 'url', spellcheck: 'false', placeholder: 'http://homeassistant.local:8123', value: ha.url });
    const token = h('input', { type: 'password', autocomplete: 'off', placeholder: t('Long-lived access token'), value: ha.token });
    const ready = () => isNative && !ha.busy && ha.url.trim() && ha.token.trim();
    url.addEventListener('input', () => { ha.url = url.value; button.disabled = !ready(); });
    token.addEventListener('input', () => { ha.token = token.value; button.disabled = !ready(); });
    const connect = async () => {
      ha.busy = true; ha.error = null; rerender();
      try {
        state.info = await call('homeassistant.connect', { url: ha.url, token: ha.token });
        ha.token = '';
        toast(t('Connected to {name}', { name: state.info.homeassistant?.name || 'Home Assistant' }));
        await load();
      } catch (e) { ha.error = e.message; }
      ha.busy = false;
      rerender();
    };
    const button = h('button.btn.primary.wide', { onclick: connect, disabled: !ready() }, ha.busy ? t('Connecting…') : t('Connect'));
    const found = state.found.homeassistant || [];
    return [
      section(t('On your network'),
        state.scanning.homeassistant ? h('p.note.busy', icon('spinner', 13), t('Looking for Home Assistant…'))
          : found.length ? found.map((s) => h('div.device',
            h('span.dot.on'), h('div', h('b', s.name), h('span', [s.url, s.version && t('version {version}', { version: s.version })].filter(Boolean).join(' · '))),
            h('button.btn', { onclick: () => { ha.url = s.url; rerender(); } }, ha.url === s.url ? t('Selected') : t('Use'))))
            : h('p.note', t('None found by itself. Type its address below.')),
        state.scanning.homeassistant ? null : h('button.btn.link', { onclick: () => scan('homeassistant') }, icon('radar', 13), t('Look again'))),
      section(t('Connect'),
        h('label.field', h('span', t('Address')), url),
        h('label.field', h('span', t('Access token')), token),
        h('ol.steps',
          h('li', t('In Home Assistant, open your profile (your name at the bottom left) → Security.')),
          h('li', t('Under “Long-lived access tokens” press Create token, name it “House Control”, copy it here.'))),
        button,
        ha.error ? h('p.note.bad', ha.error) : null,
        h('p.note', t('The token stays on this Mac (and goes to the iPhones you paired, over their encrypted link). Lights, switches, climate devices and temperature sensors appear here.'))),
    ];
  }

  /* ---------- Philips Hue ---------- */

  let pairTimer = 0;
  function stopPairing() { clearInterval(pairTimer); pairTimer = 0; state.pairing = null; }

  function pairHue(bridge) {
    stopPairing();
    state.pairing = { ...bridge, until: Date.now() + 60_000, error: null };
    const attempt = async () => {
      if (!state.pairing) return;
      if (Date.now() > state.pairing.until) {
        state.pairing.error = t('Nobody pressed the button in time. Try again.');
        clearInterval(pairTimer);
        rerender();
        return;
      }
      try {
        const r = await call('hue.pair', { host: bridge.host, bridgeId: bridge.bridgeId, name: bridge.name });
        if (r.waiting) { rerender(); return; }
        stopPairing();
        state.info = r;
        toast(state.info.hue?.name ? t('Paired with {name}', { name: state.info.hue.name }) : t('Paired with the Hue Bridge'));
        await load();
      } catch (e) {
        if (state.pairing) state.pairing.error = e.message;
        clearInterval(pairTimer);
      }
      rerender();
    };
    attempt();
    pairTimer = setInterval(attempt, 2000);
    rerender();
  }

  const hueManual = { host: '' };

  function hue() {
    const info = state.info.hue || {};
    if (info.connected) {
      if (!state.devices && !state.loading) setTimeout(() => load(), 0);
      return [connectedHeader('hue', t('Bridge'), info.name, [info.host, info.bridgeId].filter(Boolean).join(' · ')),
        deviceList('hue')];
    }
    if (state.pairing) {
      const left = Math.max(0, Math.ceil((state.pairing.until - Date.now()) / 1000));
      return [section(t('Pairing'),
        h('div.press',
          h('div.press-button', h('span')),
          h('div', h('b', t('Press the round button on the bridge')),
            h('span', state.pairing.error || `${state.pairing.name || state.pairing.host} · ${t('waiting {seconds} s', { seconds: left })}`))),
        h('div.fields',
          state.pairing.error ? h('button.btn', { onclick: () => pairHue(state.pairing) }, t('Try again')) : null,
          h('button.btn', { onclick: () => { stopPairing(); rerender(); } }, t('Cancel'))),
        h('p.note', t('The big button on top of the Hue Bridge lets one app in for 30 seconds. House Control keeps the key it gets, on this Mac.')))];
    }
    if (!state.found.hue && !state.scanning.hue) setTimeout(() => scan('hue'), 0);
    const found = state.found.hue || [];
    const host = h('input', { type: 'text', spellcheck: 'false', placeholder: t('e.g. {example}', { example: '192.168.1.20' }), value: hueManual.host });
    const pairButton = h('button.btn.wide', { onclick: () => pairHue({ host: hueManual.host.trim(), name: 'Hue Bridge' }), disabled: !isNative || !hueManual.host.trim() }, t('Pair'));
    host.addEventListener('input', () => { hueManual.host = host.value; pairButton.disabled = !isNative || !host.value.trim(); });
    return [
      section(t('On your network'),
        state.scanning.hue ? h('p.note.busy', icon('spinner', 13), t('Looking for Hue Bridges…'))
          : found.length ? found.map((b) => h('div.device',
            h('span.dot.on'), h('div', h('b', b.name), h('span', [b.host, b.bridgeId].filter(Boolean).join(' · '))),
            h('button.btn.primary', { onclick: () => pairHue(b), disabled: !isNative }, t('Pair'))))
            : h('p.note', t('No bridge found by itself. Type its address below (the Hue app shows it under Settings → My Hue system).')),
        state.scanning.hue ? null : h('button.btn.link', { onclick: () => scan('hue') }, icon('radar', 13), t('Look again'))),
      section(t('Or by address'),
        h('label.field', h('span', t('Bridge address')), host),
        pairButton),
    ];
  }

  /* ---------- Apple Home ---------- */

  function homeKit() {
    const info = state.info.homekit || {};
    const nodes = [];
    if (info.connected) {
      if (!state.devices && !state.loading) setTimeout(() => load(), 0);
      const when = info.updated ? new Date(info.updated * 1000).toLocaleString(lang === 'en' ? [] : locale, { dateStyle: 'medium', timeStyle: 'short' }) : '';
      nodes.push(section(t('From your iPhone'),
        h('div.device', h('span.dot.on'), h('div', h('b', info.from || 'iPhone'),
          h('span', `${tn(info.count, '{n} device', '{n} devices')} · ${t('sent {time}', { time: when })}`))),
        h('div.fields', h('button.btn', { onclick: () => disconnect('homekit') }, t('Forget this list')))),
      deviceList('homekit'));
    }
    nodes.push(section(info.connected ? t('How it works') : t('Set it up on your iPhone'),
      h('ol.steps',
        h('li', t('Pair your iPhone with this Mac: right-click the menu bar icon → Pair Phone….')),
        h('li', t('On the iPhone: House Control → Settings → Apple Home → Connect, and allow access to your Home data.')),
        h('li', t('Its lamps, air conditioners and thermometers appear here. Link them like any other device.'))),
      h('p.note', t('Apple lets only iPhone, iPad and App Store apps use HomeKit, so the iPhone app switches these devices. On the Mac they show what you set, but stay simulated.'))));
    return nodes;
  }

  /* ---------- detail screen ---------- */

  function detail(id, smartLifePanel) {
    if (id === 'smartlife') return smartLifePanel();
    if (id === 'homeassistant') return homeAssistant();
    if (id === 'hue') return hue();
    return homeKit();
  }

  /* ---------- linking a lamp or an AC ---------- */

  function optionLabel(d) {
    const name = d.room ? `${d.name} — ${d.room}` : d.name;
    return d.online ? name : t('{device} (offline)', { device: name });
  }

  function picker(kind, current, include = () => true) {
    const select = h('select');
    select.append(h('option', { value: '' }, kind === 'sensor' ? t('None — estimated') : t('Not linked — simulated')));
    let found = false;
    for (const id of offered()) {
      const list = devicesOf(id).filter((d) => d.kind === kind && include(d));
      if (!list.length) continue;
      select.append(h('optgroup', { label: SERVICES[id].name }, list.map((d) => {
        const value = `${d.service}|${d.id}`;
        if (value === current) found = true;
        return h('option', { value }, optionLabel(d));
      })));
    }
    if (current && !found) {
      const [service, id] = current.split('|');
      select.append(h('option', { value: current }, t('{service}: {id} (not found now)', { service: SERVICES[service]?.short || service, id })));
    }
    select.value = current;
    return select;
  }

  const find = (value) => (state.devices || []).find((d) => `${d.service}|${d.id}` === value);

  /** The "Real device" section of a lamp or an AC. `onLinked(device)` adapts the item. */
  function deviceSection(item, kind, { snapshot, changed }) {
    const link = linkOf(item);
    const current = link ? `${link.service}|${link.id}` : '';
    if (!anyConnected()) {
      return section(t('Real device'),
        h('p.note', t('Simulated. Connect Smart Life, Home Assistant, Philips Hue or Apple Home to control the real one.')),
        h('button.btn.wide', { onclick: () => onOpen(null) }, icon('link', 14), t('Open Connections')));
    }
    if (!state.devices && !state.loading) setTimeout(() => load({ quiet: true }), 0);
    const select = picker(kind, current);
    select.addEventListener('change', () => {
      snapshot();
      const value = select.value;
      delete item.link;
      if (item.tuya) { delete item.tuya.deviceId; delete item.tuya.sceneSwitch; if (!Object.keys(item.tuya).length) delete item.tuya; }
      const device = find(value);
      if (value) {
        const [service, id] = value.split('|');
        if (service === 'smartlife') item.tuya = { ...(item.tuya || {}), deviceId: id };
        else item.link = { service, id };
        // Smart Life sensors only work beside a Smart Life AC.
        if (service !== 'smartlife' && item.tuya) delete item.tuya;
      }
      let note = null;
      if (device && kind === 'light' && device.capabilities) {
        item.capabilities = [...device.capabilities];
        note = device.capabilities.length
          ? t('Matched what it can do: {capabilities}', { capabilities: device.capabilities.map((c) => CAPABILITY_LABEL[c] || c).join(', ') })
          : t('Matched: an on/off switch');
      }
      if (device && kind === 'ac' && device.min != null) { item.min = Math.round(device.min); item.max = Math.round(device.max); }
      changed(note);
    });
    const device = find(current);
    const info = device ? [SERVICES[device.service].name, device.detail, device.room].filter(Boolean).join(' · ')
      : current && state.devices ? t('This device was not found in its platform right now.')
        : state.loading ? t('Loading your devices…') : '';
    const offline = device && !device.online;
    return section(t('Real device'),
      h('label.field', h('span', t('Device')), select),
      info ? h(`p.note${offline ? '.bad' : ''}`, offline ? `${info} · ${t('offline')}` : info) : null,
      item.tuya?.sceneSwitch ? h('p.note', t('On/off sends the linked Smart Life Tap-to-Run IR commands. Power state is estimated.')) : null,
      device?.service === 'homekit' && state.info.homekit?.remote ? h('p.note', t('Switched from your iPhone; simulated on this Mac.')) : null,
      Object.keys(state.errors).length ? h('p.note.bad', Object.entries(state.errors).map(([s, e]) => `${SERVICES[s]?.name || s}: ${e}`).join(' · ')) : null);
  }

  /** An AC's thermometer: any platform's sensor (a Smart Life one only beside a Smart Life AC). */
  function sensorSection(item, { snapshot, changed }) {
    const link = linkOf(item);
    const current = item.sensor?.id ? `${item.sensor.service}|${item.sensor.id}`
      : item.tuya?.sensorId ? `smartlife|${item.tuya.sensorId}` : '';
    const select = picker('sensor', current, (d) => d.service !== 'smartlife' || link?.service === 'smartlife');
    select.addEventListener('change', () => {
      snapshot();
      delete item.sensor;
      if (item.tuya) delete item.tuya.sensorId;
      const [service, id] = select.value ? select.value.split('|') : [];
      if (service === 'smartlife') item.tuya = { ...(item.tuya || {}), sensorId: id };
      else if (service) item.sensor = { service, id };
      changed();
    });
    return section(t('Room temperature'),
      h('label.field', h('span', t('Thermometer')), select),
      h('p.note', t('A temperature sensor in the same room. Without one, the AC’s own reading is used, or the temperature is estimated.')));
  }

  /** "id → plan item name" for every device the plan links, to mark them in the lists. */
  function usedMap(doc) {
    const out = new Map();
    for (const d of [...doc.lights, ...doc.acs]) {
      const l = linkOf(d);
      if (l) out.set(`${l.service}|${l.id}`, d.name || d.id);
      if (d.sensor?.id) out.set(`${d.sensor.service}|${d.sensor.id}`, t('{name} · room', { name: d.name || d.id }));
      if (d.tuya?.sensorId) out.set(`smartlife|${d.tuya.sensorId}`, t('{name} · room', { name: d.name || d.id }));
    }
    return out;
  }

  return {
    state, load, refreshInfo, sidebarRow, overview, detail, tile, deviceSection, sensorSection, usedMap,
    connected, stopPairing,
    title: (id) => SERVICES[id]?.name,
    blurb: (id) => LOOK[id]?.blurb,
  };
}
