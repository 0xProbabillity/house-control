// The AI Access window: start and stop the private link, hand it to an assistant, choose
// what the assistant may do, and watch what it does. The native shell owns the link
// (AgentController.swift) and sends its status here; in a plain browser a stand-in
// plays the same states so the page can be worked on with `vite dev`.
import { h, richText } from '../ui/dom.js';
import { icon } from '../ui/icons.js';
import { isNative, post, incoming } from '../bridge.js';
import { t, lang, locale, formatDuration } from '../i18n.js';
import './console.css';

const CLIENT_COLORS = {
  ChatGPT: '#19c37d', Claude: '#e08a5f', 'Claude Code': '#e08a5f', Cursor: '#e6e9f2', Gemini: '#6ea8ff',
  Perplexity: '#3fc1c9', Copilot: '#8ab4ff', 'House Control': '#8a94ab',
};
const clientColor = (name) => CLIENT_COLORS[name] || '#b9a6ff';

const TABS = [
  { id: 'chat', label: t('Any chat') },
  { id: 'claude', label: 'Claude' },
  { id: 'chatgpt', label: 'ChatGPT' },
  { id: 'code', label: t('Code & agents') },
];

export function bootConsole(root) {
  document.documentElement.classList.add('mode-agent');
  let status = window.__HOUSE_BOOT__?.agent || { state: 'off', reach: 'internet', autoStop: '8h', control: true, edit: true, activity: [], tunnel: { installed: true } };
  let tab = 'chat';
  const send = isNative ? post : fakeNative((s) => { status = s; render(); });

  /* ---------- skeleton ---------- */

  // The ring is four still gradients stacked under the core; their opacities drift, so the colours
  // seem to flow around it. Only opacity animates: WebKit composites it without repainting.
  const orb = h('div.orb', h('div.orb-glow'),
    h('div.orb-ring', h('i.c1'), h('i.c2'), h('i.c3'), h('i.dim')),
    h('div.orb-core', icon('sparkles', 30, 1.8)));
  const pill = h('div.pill');
  const primary = h('button.primary', { onclick: () => send(status.state === 'live' || status.state === 'starting' ? 'agent.stop' : 'agent.start', { reach: status.reach }) });
  const reachSeg = segmented([['internet', 'globe', t('Over the internet')], ['local', 'laptop', t('This Mac only')]],
    (v) => send('agent.settings', { reach: v }));
  const callout = h('div.callout');
  const hero = h('header.hero', orb,
    h('h1', t('AI Access')),
    h('p.lede', t('Let ChatGPT, Claude or any AI assistant see and run your home — through a private link that lives only as long as you want it to.')),
    pill, primary, reachSeg.el, callout);

  const urlText = h('span.url-text');
  const linkHint = h('p.hint');
  const chatActions = h('div.actions',
    h('button.action', { onclick: (ev) => { copy(chatPrompt()); flash(ev.currentTarget, t('Copied')); } }, icon('chat', 16), h('span', t('Copy for a chat'))),
    h('button.action', { onclick: () => send('agent.open', { url: status.link }) }, icon('book', 16), h('span', t('Open the guide'))));
  const linkCard = h('section.card.link-card',
    h('div.card-head', h('span.card-title', icon('key', 15), t('Your private link')),
      h('button.ghost', { title: t('Make a new link; the current one stops working'), onclick: () => { send('agent.stop'); setTimeout(() => send('agent.start', { reach: status.reach }), 250); } }, icon('rotate', 13), t('New link'))),
    h('div.url', urlText, copyButton(() => status.link)),
    chatActions, linkHint);

  const tabBar = h('div.tabs');
  const tabBody = h('div.tab-body');
  const connectCard = h('section.card', h('div.card-head', h('span.card-title', icon('link', 15), t('Connect an assistant'))), tabBar, tabBody);

  const controlToggle = toggle((v) => send('agent.settings', { control: v }));
  const editToggle = toggle((v) => send('agent.settings', { edit: v }));
  const stopSeg = segmented([['1h', null, t('1 hour')], ['8h', null, t('8 hours')], ['never', null, t('Never')]], (v) => send('agent.settings', { autoStop: v }));
  const permsCard = h('section.card',
    h('div.card-head', h('span.card-title', icon('shield', 15), t('What it may do'))),
    row('sun', t('Lights, climate and scenes'), t('Switch and dim lights, set air conditioners, run scenes'), controlToggle.el),
    row('box', t('Your 3D home'), t('Rebuild rooms from photos, move furniture, add devices — always undoable'), editToggle.el),
    h('div.row.column', h('div.row-text', h('div.row-title', icon('clock', 15), t('Stop the link automatically'))), stopSeg.el));

  const feed = h('ul.feed');
  const undo = h('button.ghost', { onclick: () => send('agent.undo') }, icon('undo', 13), t('Undo home edit'));
  const activityCard = h('section.card', h('div.card-head', h('span.card-title', icon('activity', 15), t('Activity')), undo), feed);

  const footer = h('footer.privacy',
    h('div.privacy-title', icon('shield', 15), t('Private by design')),
    h('ul',
      h('li', t('Runs on this Mac. No House Control server, no account, nothing stored anywhere else.')),
      h('li', t('The link holds a 128-bit secret. Without it every address answers “not found”.')),
      h('li', t('Stop ends it at once — the address itself stops existing. Each start makes a new one.')),
      h('li', t('Device IDs and sign-ins never leave the Mac. Cloudflare only relays the encrypted connection.'))));

  const page = h('div.agent', hero, linkCard, connectCard, permsCard, activityCard, footer);
  root.replaceChildren(page);

  /* ---------- pieces ---------- */

  function row(iconName, title, text, control) {
    return h('div.row', h('div.row-icon', icon(iconName, 16)), h('div.row-text', h('div.row-title', title), h('div.row-sub', text)), control);
  }

  function toggle(onChange) {
    const el = h('button.ai-switch', { role: 'switch', onclick: () => { const v = el.getAttribute('aria-checked') !== 'true'; set(v); onChange(v); } }, h('i'));
    const set = (v) => el.setAttribute('aria-checked', String(v));
    return { el, set };
  }

  function segmented(options, onChange) {
    const buttons = new Map();
    const el = h('div.seg', options.map(([value, iconName, label]) => {
      const b = h('button', { onclick: () => { if (!el.classList.contains('locked')) { set(value); onChange(value); } } }, iconName ? icon(iconName, 13) : null, label);
      buttons.set(value, b);
      return b;
    }));
    const set = (value) => { for (const [v, b] of buttons) b.classList.toggle('on', v === value); };
    return { el, set };
  }

  function copyButton(text) {
    const b = h('button.copy', { title: t('Copy'), onclick: () => { copy(text()); flash(b, t('Copied')); } }, icon('copy', 14), h('span', t('Copy')));
    return b;
  }

  function flash(button, label) {
    const span = button.querySelector('span');
    if (!span) return;
    const before = span.textContent;
    span.textContent = label;
    button.classList.add('done');
    setTimeout(() => { span.textContent = before; button.classList.remove('done'); }, 1400);
  }

  function copy(text) {
    if (!text) return;
    if (isNative) post('agent.copy', { text });
    else navigator.clipboard?.writeText(text).catch(() => {});
  }

  function chatPrompt() {
    // Pasted by the person as their own message, so in their language.
    return `${t('You can control my home with House Control. Open this private link and follow its instructions: {link}', { link: status.link })}\n\n`;
  }

  function codeBlock(text, label = t('Copy')) {
    const b = h('button.copy.small', { onclick: () => { copy(text); flash(b, t('Copied')); } }, icon('copy', 13), h('span', label));
    return h('div.code', h('code', text), b);
  }

  function steps(...items) {
    const start = typeof items[0] === 'number' ? items.shift() : 1;
    return h('ol.steps', { vars: { '--start': start - 1 } }, items.map((i) => h('li', i)));
  }

  function renderTab() {
    for (const b of tabBar.children) b.classList.toggle('on', b.dataset.id === tab);
    const live = status.state === 'live';
    const mcp = live ? status.mcp : t('Start AI Access to get the address');
    const link = live ? status.link : t('Start AI Access to get the link');
    let body;
    if (tab === 'chat') {
      body = [
        h('p', t('Works with assistants that can open web pages: ChatGPT, Claude, Gemini, Perplexity, Grok.')),
        steps(h('span', richText(t('**Copy for a chat** above and paste it into a new conversation.'))),
          h('span', richText(t('Add what you want: {example}.'), { example: h('em', t('“dim the living room to 30% and cool the bedroom to 22°”')) })),
          h('span', t('The assistant reads the guide behind the link and opens the matching action links. Watch them land below.'))),
        h('p.muted', t('For photos of your rooms and edits to the 3D model, connect it as a connector (Claude, ChatGPT) instead — that needs more than opening links.')),
      ];
    } else if (tab === 'claude') {
      body = [
        steps(h('span', richText(t('In Claude open **Settings → Connectors → Add custom connector**.'))),
          h('span', richText(t('Name it **House Control** and paste this address:')))),
        codeBlock(mcp),
        steps(3, h('span', richText(t('In a chat, turn it on from the tools menu and ask away — or attach photos: {example}.'),
          { example: h('em', t('“here is my living room, rebuild it in 3D”')) }))),
      ];
    } else if (tab === 'chatgpt') {
      body = [
        steps(h('span', richText(t('In ChatGPT open **Settings → Apps & Connectors → Advanced** and turn on **Developer mode**.'))),
          h('span', richText(t('**Create** a connector named **House Control** with this MCP address and no authentication:')))),
        codeBlock(mcp),
        steps(3, h('span', t('In a chat choose Developer mode, add House Control, and talk to your home.'))),
        h('p.muted', t('No developer mode? “Copy for a chat” works in any ChatGPT conversation that can browse.')),
      ];
    } else {
      body = [
        h('p', h('b', 'Claude Code')),
        codeBlock(live ? `claude mcp add --transport http house-control ${status.mcp}` : mcp),
        h('p', h('b', t('Cursor, Windsurf, VS Code and other MCP clients'))),
        codeBlock(live ? JSON.stringify({ mcpServers: { 'house-control': { url: status.mcp } } }) : mcp),
        h('p', richText(t('**Any agent or script** — plain HTTP with JSON. Tools: {list}, run one: {run}, OpenAPI: {openapi}.'), {
          list: h('code.inline', 'GET …/api/tools'), run: h('code.inline', 'POST …/api/<tool>'), openapi: h('code.inline', '…/openapi.json'),
        })),
        codeBlock(link),
      ];
    }
    tabBody.replaceChildren(...body);
  }

  for (const item of TABS) tabBar.append(h('button', { 'data-id': item.id, onclick: () => { tab = item.id; renderTab(); } }, item.label));

  function ago(ms) {
    const s = Math.max(0, (Date.now() - ms) / 1000);
    if (s < 45) return t('now');
    if (s < 3600) return formatDuration(s / 60);
    return new Date(ms).toLocaleTimeString(lang === 'en' ? [] : locale, { hour: 'numeric', minute: '2-digit' });
  }

  function left(ms) {
    const m = Math.max(0, Math.round((ms - Date.now()) / 60000));
    return t('{time} left', { time: formatDuration(m) });
  }

  let shown = new Set();
  let shownLocal = null;
  function renderFeed() {
    const entries = (status.activity || []).slice().reverse();
    // Reads ("Looked at the home") are folded into the action that follows them.
    const visible = entries.filter((e, i) => !e.quiet || i === 0 || !entries[i - 1] || entries[i - 1].client !== e.client).slice(0, 40);
    if (!visible.length) {
      feed.replaceChildren(h('li.empty', icon('sparkles', 16), h('span', status.state === 'live'
        ? t('Waiting for your assistant. What it reads and does shows up here, live.')
        : t('Nothing yet. Start AI Access, give the link to an assistant, and watch it work here.'))));
      return;
    }
    feed.replaceChildren(...visible.map((e) => {
      const key = `${e.time}|${e.title}`;
      const item = h(`li${e.ok ? '' : '.bad'}${e.quiet ? '.quiet' : ''}${shown.has(key) ? '' : '.fresh'}`,
        h('span.who', { vars: { '--c': clientColor(e.client) } }, e.client === 'House Control' ? icon('home', 11, 2.2) : icon('sparkles', 11, 2.2), e.client),
        h('span.what', e.title),
        h('time', ago(e.time)));
      shown.add(key);
      return item;
    }));
  }

  /* ---------- state ---------- */

  function render() {
    const s = status.state;
    page.dataset.state = s;
    const label = {
      off: t('Off'), starting: status.reach === 'local' ? t('Starting…') : t('Opening a private tunnel…'),
      live: status.stopsAt ? `${t('Live')} · ${left(status.stopsAt)}` : t('Live'),
      error: t('Stopped'), setup: t('One-time setup'),
    }[s] || s;
    pill.replaceChildren(h('i.dot'), h('span', label), ...(s === 'live' ? [h('span.pill-reach', status.reach === 'local' ? t('This Mac') : t('Internet'))] : []));
    primary.replaceChildren(...(s === 'live' ? [icon('stop', 15, 2.4), t('Stop AI Access')] : s === 'starting' ? [h('i.spinner'), t('Cancel')] : [icon('sparkles', 17, 2), t('Start AI Access')]));
    primary.classList.toggle('stop', s === 'live' || s === 'starting');
    reachSeg.set(status.reach);
    reachSeg.el.classList.toggle('locked', s === 'live' || s === 'starting');

    if (s === 'setup') {
      const tunnel = status.tunnel || {};
      callout.className = 'callout info';
      callout.replaceChildren(...[
        h('div.callout-title', icon('download', 15), t('Get Cloudflare’s tunnel once')),
        h('p', richText(t('Over the internet, your Mac is reached through Cloudflare’s free quick tunnel ({tool}, about 20 MB, from Cloudflare’s GitHub). No Cloudflare account is needed.'),
          { tool: h('code.inline', 'cloudflared') })),
        tunnel.error ? h('p.err', tunnel.error) : null,
        h('div.callout-actions',
          h('button.primary.small', { disabled: tunnel.downloading || null, onclick: () => send('agent.install') }, tunnel.downloading ? [h('i.spinner'), t('Downloading…')] : [icon('download', 14), t('Download')]),
          h('button.ghost', { onclick: () => send('agent.start', { reach: 'local' }) }, t('Use this Mac only'))),
        h('p.muted', richText(t('Or in Terminal: {command}'), { command: h('code.inline', 'brew install cloudflared') }))].filter(Boolean));
    } else if (s === 'error') {
      callout.className = 'callout bad';
      callout.replaceChildren(h('div.callout-title', icon('close', 15), t('AI Access stopped')), h('p', status.error || t('Something went wrong.')));
    } else {
      callout.className = 'callout hidden';
      callout.replaceChildren();
    }

    linkCard.classList.toggle('hidden', s !== 'live');
    const local = status.reach === 'local';
    if (local !== shownLocal) {
      // Assistants in the cloud cannot reach 127.0.0.1: on this Mac only, apps on the Mac are the audience.
      shownLocal = local;
      if (local && tab === 'chat') tab = 'code';
      if (!local && tab === 'code' && s !== 'live') tab = 'chat';
    }
    chatActions.firstChild.hidden = local;
    linkHint.replaceChildren(...(local
      ? richText(t('Only apps on this Mac can open it: Claude Code, Cursor, VS Code, LM Studio, your own scripts. See **{tab}** below.', { tab: t('Code & agents') }))
      : richText(t('Paste it into any assistant with your request — {example}.'), { example: h('em', t('“turn off every light except the bedroom”')) })));
    if (s === 'live') {
      try {
        const u = new URL(status.link);
        const [token] = u.pathname.slice(1).split('/');
        urlText.replaceChildren(h('span.url-host', u.host), h('span.url-token', `/${token.slice(0, 5)}…`));
      } catch { urlText.textContent = status.link; }
    }
    controlToggle.set(status.control !== false);
    editToggle.set(status.edit !== false);
    stopSeg.set(status.autoStop || '8h');
    undo.disabled = !status.canUndo;
    renderTab();
    renderFeed();
  }

  incoming.agentStatus = (next) => { status = next; render(); };
  setInterval(() => { if (status.state === 'live') { render(); } }, 30000);
  render();
  post('ready', {});
  window.__agent = { get status() { return status; }, set status(s) { status = s; render(); }, render };
}

// In a browser there is no native side: play its part, so the page can be designed and filmed.
function fakeNative(update) {
  let s = { state: 'off', reach: 'internet', autoStop: '8h', control: true, edit: true, activity: [], canUndo: false, tunnel: { installed: true } };
  const set = (patch) => { s = { ...s, ...patch }; update(s); };
  const log = (client, title, quiet = false) => set({ activity: [...s.activity, { time: Date.now(), client, title, ok: true, quiet }] });
  return (type, payload = {}) => {
    if (type === 'agent.start') {
      set({ state: 'starting', reach: payload.reach || s.reach });
      setTimeout(() => {
        const base = s.reach === 'local' ? 'http://127.0.0.1:7419' : 'https://quiet-harbor-lamp-meadow.trycloudflare.com';
        const link = `${base}/k3VbQ9mX2pLr8tNw4yHc0A`;
        set({ state: 'live', link, mcp: `${link}/mcp`, startedAt: Date.now(), stopsAt: s.autoStop === 'never' ? null : Date.now() + (s.autoStop === '1h' ? 1 : 8) * 3600e3 });
        log('House Control', 'Link is live');
      }, 1600);
    } else if (type === 'agent.stop') {
      if (s.state === 'live') log('House Control', 'Stopped — the link no longer works');
      set({ state: 'off', link: null, mcp: null });
    } else if (type === 'agent.settings') {
      set(Object.fromEntries(Object.entries(payload).filter(([, v]) => v != null)));
    } else if (type === 'agent.undo') {
      log('House Control', 'Undid the last floor plan change');
      set({ canUndo: false });
    } else if (type === 'agent.open') {
      window.open(payload.url, '_blank');
    }
  };
}
