// Authenticated, same-origin transport. Tokens are never stored in browser storage.
export const isServer = window.__HOUSE_SERVER__ === true;
let csrfToken = '';
let events;
export async function request(path, body) {
  const response = await fetch(path, {
    method: body === undefined ? 'GET' : 'POST', credentials: 'same-origin',
    headers: body === undefined ? {} : { 'Content-Type': 'application/json', 'X-CSRF-Token': csrfToken },
    body: body === undefined ? undefined : JSON.stringify(body),
    signal: AbortSignal.timeout(20000),
  });
  const result = await response.json();
  if (!response.ok) {
    if (response.status === 401) window.dispatchEvent(new Event('house:unauthorized'));
    throw Object.assign(new Error(result.error || `HTTP ${response.status}`), { status: response.status, detail: result });
  }
  if (result.csrfToken) csrfToken = result.csrfToken;
  if (result.server?.csrfToken) csrfToken = result.server.csrfToken;
  return result;
}
function element(tag, text, props = {}) { const e = document.createElement(tag); e.textContent = text; Object.assign(e, props); return e; }
export async function initializeServer() {
  if (!isServer) return;
  for (;;) {
    try { window.__HOUSE_BOOT__ = await request('/api/bootstrap'); return; }
    catch (error) { await loginScreen(error.status === 401 ? '' : error.message); }
  }
}
function loginScreen(message) {
  return new Promise((resolve) => {
    const root = document.getElementById('app');
    const form = element('form', '', { className: 'server-login' });
    const token = element('input', '', { type: 'password', autocomplete: 'current-password', required: true });
    token.setAttribute('aria-label', 'Server access token');
    const label = element('label', 'Server access token'); label.append(token);
    const error = element('p', message, { role: 'alert' });
    const submit = element('button', 'Sign in', { type: 'submit' });
    form.append(element('h1', 'House Control'), element('p', `Connect to ${location.origin}`), label, submit, error);
    if (new URLSearchParams(location.search).get('platform') === 'android') form.append(element('a', 'Change server', { href: 'housecontrol://settings' }));
    root.replaceChildren(form);
    form.addEventListener('submit', async (event) => {
      event.preventDefault(); submit.disabled = true; error.textContent = '';
      try { await request('/api/login', { token: token.value }); token.value = ''; resolve(); }
      catch (e) { error.textContent = e.message; submit.disabled = false; }
    });
  });
}
export function serverCall(type, payload = {}) { return request('/api/call', { type, ...payload }); }
export function navigateMode(mode, section) {
  const url = new URL(location.href); url.searchParams.set('mode', mode);
  if (section) url.searchParams.set('section', section); else url.searchParams.delete('section');
  location.href = url.href;
}
export function startServerEvents(incoming) {
  if (!isServer) return;
  events?.close();
  const badge = element('button', 'Connecting…', { className: 'server-status', type: 'button' });
  badge.setAttribute('aria-label', 'Server connection settings');
  badge.onclick = () => showServerSettings(); document.body.append(badge);
  events = new EventSource('/api/events');
  events.onopen = async () => {
    badge.textContent = 'Server connected';
    // Refresh authoritative state after any gap in the event stream.
    try {
      const b = await request('/api/bootstrap'); incoming.applyRemote?.(b.deviceState || {});
      if (b.server.revision !== window.__HOUSE_BOOT__.server.revision) window.dispatchEvent(new CustomEvent('house:planChanged', { detail: { revision: b.server.revision, plan: b.plan } }));
    }
    catch (e) { badge.textContent = e.message; }
  };
  const markStale = () => incoming.applyRemote?.({ online: Object.fromEntries([...(window.__HOUSE_BOOT__.config.lights || []), ...(window.__HOUSE_BOOT__.config.acs || [])].filter(d => d.link || d.tuya).map(d => [d.id, false])) });
  events.onerror = () => { badge.textContent = 'Connection lost · reconnecting…'; markStale(); request('/api/bootstrap').catch(() => {}); };
  events.onmessage = (event) => {
    let message; try { message = JSON.parse(event.data); } catch { return; }
    if (message.type === 'planChanged') {
      const data = message.data;
      window.dispatchEvent(new CustomEvent('house:planChanged', { detail: data }));
    } else if (message.type === 'connection') {
      if (!message.data.connected) markStale();
      badge.textContent = message.data.connected ? 'Server connected' : `Home Assistant offline${message.data.error ? ': ' + message.data.error : ''}`;
    } else incoming[message.type]?.(message.data);
  };
  window.addEventListener('house:unauthorized', () => { events.close(); location.reload(); });
}
export function showServerSettings() {
  const dialog = element('dialog', '', { className: 'server-settings' });
  const close = element('button', 'Close', { type: 'button' }); close.onclick = () => { dialog.close(); dialog.remove(); };
  const logout = element('button', 'Sign out', { type: 'button' });
  logout.onclick = async () => { if (window.__houseHasUnsavedChanges?.() && !confirm('Discard unsaved changes and sign out?')) return; try { await request('/api/logout', {}); location.reload(); } catch (e) { error.textContent = e.message; } };
  const edit = element('button', 'Edit home', { type: 'button' }); edit.onclick = () => navigateMode('editor');
  const connections = element('button', 'Home Assistant', { type: 'button' }); connections.onclick = () => navigateMode('editor', 'service:homeassistant');
  const home = element('button', 'Back to home', { type: 'button' }); home.onclick = () => navigateMode('panel');
  const error = element('p', '', { role: 'alert' });
  dialog.append(element('h2', 'Server connection'), element('p', location.origin), element('p', 'The home plan and Home Assistant connection are shared by clients connected to this server.'), home, edit, connections);
  if (new URLSearchParams(location.search).get('platform') === 'android') dialog.append(element('a', 'Change server', { href: 'housecontrol://settings' }));
  for (const [plan, name] of [['home', 'Demo · Apartment'], ['studio', 'Demo · Studio'], ...(window.__HOUSE_BOOT__?.hasCustomPlan ? [['custom', 'My home']] : [])]) {
    const button = element('button', name, { type: 'button' });
    button.onclick = async () => {
      if (window.__houseHasUnsavedChanges?.() && !confirm('Discard unsaved changes and switch the shared plan?')) return;
      button.disabled = true;
      try { await serverCall('selectPlan', { plan, expectedRevision: window.__HOUSE_BOOT__.server.revision }); location.href = new URL('?mode=panel' + (new URLSearchParams(location.search).get('platform') === 'android' ? '&platform=android' : ''), location.href).href; }
      catch (e) { error.textContent = e.status === 409 ? 'The home changed. Reload before selecting a plan.' : e.message; button.disabled = false; }
    };
    dialog.append(button);
  }
  dialog.querySelector('a[href="housecontrol://settings"]')?.addEventListener('click', event => { if (window.__houseHasUnsavedChanges?.() && !confirm('Leave this server with unsaved changes?')) event.preventDefault(); });
  dialog.append(logout, close, error); document.body.append(dialog); dialog.showModal();
}
