import { test, expect } from '@playwright/test';

const home = () => ({ name: 'Shared home', rooms: [{ id: 'living', name: 'Living', rect: [0, 0, 4, 4] }],
  lights: [{ id: 'lamp', name: 'Desk lamp', room: 'living', type: 'table', pos: [1, 1], capabilities: ['brightness'], link: { service: 'homeassistant', id: 'light.desk' } }], acs: [], scenes: [] });
async function server(page, { authorized = true, rejectCommands = false } = {}) {
  const state = { authorized, revision: 1, config: home(), calls: [] };
  await page.addInitScript(() => {
    window.__HOUSE_SERVER__ = true;
    window.EventSource = class {
      constructor() { window.testEvents = this; setTimeout(() => this.onopen?.(), 10); }
      close() {}
    };
  });
  await page.route('**/api/**', async (route) => {
    const path = new URL(route.request().url()).pathname;
    const body = route.request().postDataJSON();
    const reply = (status, value) => route.fulfill({ status, contentType: 'application/json', body: JSON.stringify(value) });
    if (path === '/api/login') { if (body.token !== 'test-token') return reply(401, { error: 'Invalid token' }); state.authorized = true; return reply(200, { ok: true, csrfToken: 'csrf' }); }
    if (!state.authorized) return reply(401, { error: 'Sign in required' });
    if (path === '/api/bootstrap') return reply(200, { platform: 'web', config: state.config, plan: 'custom', hasCustomPlan: true, server: { revision: state.revision, csrfToken: 'csrf' }, services: { homeassistant: { connected: true, name: 'Test HA' } }, deviceState: { lights: { lamp: { on: false, brightness: 0.6 } } } });
    if (route.request().headers()['x-csrf-token'] !== 'csrf') return reply(403, { error: 'Missing CSRF token' });
    if (path === '/api/logout') { state.authorized = false; return reply(200, { ok: true }); }
    state.calls.push(body);
    if (body.type === 'savePlan') {
      if (body.expectedRevision !== state.revision) return reply(409, { error: 'Plan changed', revision: state.revision });
      state.config = body.config; state.revision++; return reply(200, { ok: true, revision: state.revision });
    }
    if (body.type === 'devices.all') return reply(200, { devices: [{ service: 'homeassistant', id: 'light.desk', name: 'Real desk lamp', kind: 'light', online: true, capabilities: ['brightness'] }], errors: {} });
    if (body.type === 'services.info') return reply(200, { homeassistant: { connected: true, name: 'Test HA' } });
    if (body.type === 'command' && rejectCommands) return reply(502, { error: 'Device unavailable' });
    return reply(200, { ok: true });
  });
  return state;
}

test('requires login, retries invalid token and signs out without storing secrets', async ({ page }) => {
  await server(page, { authorized: false });
  await page.goto('/');
  await page.getByLabel('Server access token').fill('wrong'); await page.getByRole('button', { name: 'Sign in', exact: true }).click();
  await expect(page.getByRole('alert')).toHaveText('Invalid token');
  await page.getByLabel('Server access token').fill('test-token'); await page.getByRole('button', { name: 'Sign in', exact: true }).click();
  await expect(page.getByRole('button', { name: 'Server connection settings' })).toBeVisible();
  expect(await page.evaluate(() => JSON.stringify(localStorage))).not.toContain('test-token');
  await page.getByRole('button', { name: 'Server connection settings' }).click(); await page.getByRole('button', { name: 'Sign out', exact: true }).click();
  await expect(page.getByLabel('Server access token')).toBeVisible();
});

test('editor saves revision, reloads saved plan and adopts shared changes', async ({ page }) => {
  const state = await server(page); await page.goto('/?mode=editor');
  await page.getByLabel('Home name').fill('Updated home'); await page.getByRole('button', { name: 'Save & apply' }).click();
  await expect.poll(() => state.config.name).toBe('Updated home'); expect(state.calls.find(c => c.type === 'savePlan').expectedRevision).toBe(1);
  await page.reload(); await expect(page.getByLabel('Home name')).toHaveValue('Updated home');
  state.config.name = 'Other device'; state.revision++;
  await page.evaluate((revision) => window.testEvents.onmessage({ data: JSON.stringify({ type: 'planChanged', data: { revision, plan: 'custom' } }) }), state.revision);
  await expect(page.getByLabel('Home name')).toHaveValue('Other device');
});

test('keeps dirty edits on shared plan conflict and offers export and reload', async ({ page }) => {
  const state = await server(page); await page.goto('/?mode=editor');
  await page.getByLabel('Home name').fill('My draft'); state.config.name = 'New server home'; state.revision++;
  await page.getByRole('button', { name: 'Save & apply' }).click();
  await expect(page.getByRole('dialog')).toBeVisible(); await expect(page.getByLabel('Home name')).toHaveValue('My draft');
  const download = page.waitForEvent('download'); await page.getByRole('button', { name: 'Export my draft' }).click(); expect((await download).suggestedFilename()).toBe('my-draft.json');
  await page.getByRole('button', { name: 'Load latest home' }).click(); await expect(page.getByLabel('Home name')).toHaveValue('New server home');
});

test('linked device uses authenticated command and rolls back failures', async ({ page }) => {
  const state = await server(page, { rejectCommands: true }); await page.goto('/');
  await page.waitForFunction(() => window.__house);
  await page.evaluate(() => window.__house.store.toggleLight('lamp'));
  await expect.poll(() => state.calls.some(c => c.type === 'command' && c.id === 'lamp' && c.patch.on === true)).toBe(true);
  await expect.poll(() => page.evaluate(() => window.__house.store.state.lights.lamp.on)).toBe(false);
  await expect(page.getByText('Desk lamp: Device unavailable')).toBeVisible();
});

test('Android has shared mobile editor and server settings with only HA', async ({ page }) => {
  await page.setViewportSize({ width: 393, height: 851 }); await server(page); await page.goto('/?platform=android&mode=editor');
  await expect(page.locator('.editor.phone')).toBeVisible();
  await page.getByRole('button', { name: 'Server connection settings' }).click();
  await expect(page.getByRole('link', { name: 'Change server' })).toHaveAttribute('href', 'housecontrol://settings');
  await page.getByRole('button', { name: 'Home Assistant', exact: true }).click();
  await expect(page.locator('.insp-head')).toContainText('Home Assistant');
  await expect(page.getByText('Test HA', { exact: true })).toBeVisible();
  await expect(page.locator('.svc-card')).toHaveCount(0);
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
});

test('editor links plan item from HA catalog and persists link', async ({ page }) => {
  const state = await server(page); delete state.config.lights[0].link;
  await page.goto('/?mode=editor'); await page.waitForFunction(() => window.__editor); await page.evaluate(() => window.__editor.select({ kind: 'light', index: 0 }));
  const picker = page.locator('label.field').filter({ has: page.getByText('Device', { exact: true }) }).locator('select');
  await expect(picker.locator('option[value="homeassistant|light.desk"]')).toHaveCount(1);
  await picker.selectOption('homeassistant|light.desk'); await page.getByRole('button', { name: 'Save & apply' }).click();
  await expect.poll(() => state.config.lights[0].link?.id).toBe('light.desk');
});


test('reconnect fetches a plan revision missed while disconnected', async ({ page }) => {
  const state = await server(page); await page.goto('/?mode=editor'); await page.waitForFunction(() => window.__editor);
  state.config.name = 'Changed while suspended'; state.revision++;
  await page.evaluate(() => window.testEvents.onopen());
  await expect(page.getByLabel('Home name')).toHaveValue('Changed while suspended');
});

test('dirty editor can cancel sign out and shared plan selection', async ({ page }) => {
  const state = await server(page); await page.goto('/?mode=editor'); await page.getByLabel('Home name').fill('Unsaved draft');
  await page.getByRole('button', { name: 'Server connection settings' }).click();
  const dialogs = []; page.on('dialog', async dialog => { dialogs.push(dialog.message()); await dialog.dismiss(); });
  await page.getByRole('button', { name: 'Sign out', exact: true }).click(); expect(state.authorized).toBe(true);
  await page.getByRole('button', { name: 'Demo · Studio', exact: true }).click(); expect(state.calls.some(c => c.type === 'selectPlan')).toBe(false);
  expect(dialogs).toHaveLength(2); await page.getByRole('button', { name: 'Close', exact: true }).click(); await expect(page.getByLabel('Home name')).toHaveValue('Unsaved draft');
});
