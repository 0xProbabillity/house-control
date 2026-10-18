// Real HTTP server and Home Assistant adapter against a local fake HA instance.
// This fixture never discovers or contacts any real device.
import { test, expect } from '@playwright/test';
import http from 'node:http';
import { WebSocketServer } from 'ws';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { createHouseServer } from '../../server/src.js';
const token = 'browser-test-token-at-least-24-characters';
let app, mock, sockets, origin, haOrigin, dataDir;
let on = false, failControl = false;
const commands = [];
const entity = () => ({ entity_id: 'light.browser_fixture', state: on ? 'on' : 'off', attributes: { friendly_name: 'Fixture light', supported_color_modes: ['brightness'], brightness: 128 } });
async function listen(server) { await new Promise(r => server.listen(0, '127.0.0.1', r)); return `http://127.0.0.1:${server.address().port}`; }
// Pause only the app renderer for evidence capture. Keep browser RAF available to
// Playwright's screenshot synchronisation; subsequent navigation recreates the renderer.
async function evidence(page, name) {
  await page.waitForFunction(() => window.__editor?.world || window.__house?.world);
  await page.evaluate(() => { (window.__editor?.world || window.__house?.world)?.setRunning(false); });
  await page.screenshot({ path: `../build/evidence/${name}.png`, animations: 'disabled' });
}
async function stop(server) { await new Promise(r => { server.close(r); server.closeAllConnections(); }); }
test.beforeAll(async () => {
  dataDir = await mkdtemp(path.join(tmpdir(), 'house-browser-'));
  mock = http.createServer(async (req, res) => {
    res.setHeader('Content-Type', 'application/json');
    if (req.headers.authorization !== 'Bearer fake-ha-token') { res.writeHead(401); return res.end('{}'); }
    if (req.url === '/api/config') return res.end(JSON.stringify({ location_name: 'Browser fixture HA', version: 'test' }));
    if (req.url === '/api/states') return res.end(JSON.stringify([entity()]));
    if (req.url.startsWith('/api/services/light/')) {
      let raw = ''; for await (const chunk of req) raw += chunk; commands.push(JSON.parse(raw));
      if (failControl) { res.writeHead(503); return res.end(JSON.stringify({ message: 'Fixture offline' })); }
      on = req.url.endsWith('turn_on'); return res.end(JSON.stringify([entity()]));
    }
    res.writeHead(404); res.end('{}');
  });
  sockets = new WebSocketServer({ server: mock, path: '/api/websocket' });
  sockets.on('connection', (ws) => {
    ws.send(JSON.stringify({ type: 'auth_required' }));
    ws.on('message', raw => {
      const message = JSON.parse(raw);
      if (message.type === 'auth') ws.send(JSON.stringify({ type: message.access_token === 'fake-ha-token' ? 'auth_ok' : 'auth_invalid' }));
      if (message.type === 'subscribe_events') ws.send(JSON.stringify({ id: message.id, type: 'result', success: true }));
    });
  });
  haOrigin = await listen(mock);
  app = await createHouseServer({ token, dataDir }); origin = await listen(app.server);
});
test.afterAll(async () => { app.ha.stop(); for (const ws of sockets.clients) ws.terminate(); await stop(app.server); await new Promise(r => sockets.close(r)); await stop(mock); await rm(dataDir, { recursive: true, force: true }); });
test('real login, HA connection, linking, shared save, SSE state and rollback', async ({ page, browser }) => {
  test.setTimeout(60000);
  await page.goto(origin + '/?mode=editor');
  await page.getByLabel('Server access token').fill(token); await page.getByRole('button', { name: 'Sign in', exact: true }).click();
  await expect(page.getByLabel('Home name')).toBeVisible();
  // Open HA through user-visible server settings.
  await page.getByRole('button', { name: 'Server connection settings' }).click(); await page.getByRole('button', { name: 'Home Assistant', exact: true }).click();
  await page.getByPlaceholder('http://homeassistant.local:8123').fill(haOrigin);
  await page.getByPlaceholder('Long-lived access token').fill('fake-ha-token'); await page.getByRole('button', { name: 'Connect', exact: true }).click();
  await expect(page.getByText('Fixture light', { exact: true })).toBeVisible();
  // Select an existing plan lamp, link via the actual catalog response, and save.
  await page.waitForFunction(() => window.__editor);
  await page.evaluate(() => window.__editor.select({ kind: 'light', index: 0 }));
  const picker = page.locator('label.field').filter({ has: page.getByText('Device', { exact: true }) }).locator('select');
  await picker.selectOption('homeassistant|light.browser_fixture');
  await page.getByLabel('Home name').fill('Real shared fixture'); await page.getByRole('button', { name: 'Save & apply' }).click();
  await expect(page.getByText('Saved — every connected device now shares this home')).toBeVisible();
  await page.reload(); await expect(page.getByLabel('Home name')).toHaveValue('Real shared fixture');
  await evidence(page, 'server-editor-desktop');
  await page.getByRole('button', { name: 'Back to home', exact: true }).click(); await page.waitForFunction(() => window.__house);
  const id = await page.evaluate(() => window.__house.config.lights[0].id);
  await page.evaluate(id => window.__house.store.toggleLight(id), id);
  await expect.poll(() => commands.length).toBe(1); expect(on).toBe(true);
  failControl = true;
  await page.waitForTimeout(350); await page.evaluate(id => window.__house.store.toggleLight(id), id);
  await expect.poll(() => commands.length).toBe(2);
  await expect.poll(() => page.evaluate(id => window.__house.store.state.lights[id].on, id)).toBe(true);
  // A separate browser client observes the persisted shared plan, not local storage.
  const second = await browser.newContext({ viewport: { width: 393, height: 851 }, isMobile: true, hasTouch: true });
  const phone = await second.newPage(); await phone.goto(origin + '/?platform=android');
  await phone.getByLabel('Server access token').fill(token); await phone.getByRole('button', { name: 'Sign in', exact: true }).click();
  await phone.waitForFunction(() => window.__house); expect(await phone.evaluate(() => window.__house.config.name)).toBe('Real shared fixture');
  await evidence(phone, 'server-home-android');
  await phone.getByRole('button', { name: 'Server connection settings' }).click(); await expect(phone.getByRole('link', { name: 'Change server' })).toBeVisible();
  await second.close();
});
