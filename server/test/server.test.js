import { test } from "node:test";
import assert from "node:assert/strict";
import http from "node:http";
import { mkdtemp, readFile, stat, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { WebSocketServer } from "ws";
import { createHouseServer } from "../src.js";
import { HomeAssistant } from "../ha.js";
import { calls, reading } from "../mapping.js";

test("climate capabilities, sensor conversion and unsafe controls", () => {
  const climate = {
    entity_id: "climate.bedroom",
    state: "cool",
    attributes: {
      hvac_modes: ["cool", "fan_only"],
      fan_modes: ["Quiet", "High"],
      swing_modes: ["off", "vertical"],
      preset_modes: ["none", "sleep"],
      min_temp: 16,
      max_temp: 30,
      current_temperature: 24,
      temperature: 22,
    },
  };
  const mapped = calls(climate, {
    mode: "fan",
    fan: "low",
    swing: "swing",
    sleep: true,
    target: 23,
  });
  assert.equal(mapped[0].data.hvac_mode, "fan_only");
  assert.equal(mapped[1].data.temperature, 23);
  assert.equal(mapped[2].data.fan_mode, "Quiet");
  assert.equal(mapped[3].data.swing_mode, "vertical");
  assert.throws(() => calls(climate, { mode: "heat" }), /Unsupported mode/);
  assert.throws(() => calls(climate, { target: 99 }), /range/);
  assert.throws(() => calls(climate, { eco: true }), /preset/);
  assert.equal(
    reading({
      entity_id: "sensor.room",
      state: "68",
      attributes: { unit_of_measurement: "°F" },
    }).temperature,
    20,
  );
});

test("malformed plans and prototype identifiers cannot replace persisted state", async (t) => {
  const f = await fixture(t),
    original = (await f.request("/api/plan")).data;
  const edits = [
    (c) => (c.lights[0].room = "missing"),
    (c) => (c.lights[0].id = c.rooms[0].id),
    (c) => (c.rooms[0].id = "__proto__"),
    (c) =>
      Object.defineProperty(c, "__proto__", {
        value: { polluted: true },
        enumerable: true,
      }),
    (c) => (c.rooms[0].rect = [0, 0, -1, 2]),
  ];
  for (const edit of edits) {
    const config = structuredClone(original.config);
    edit(config);
    const result = await f.request("/api/plan", {
      method: "PUT",
      data: { config, expectedRevision: original.revision },
    });
    assert.equal(result.status, 400);
    assert.deepEqual((await f.request("/api/plan")).data, original);
  }
  assert.equal({}.polluted, undefined);
  const result = await f.request("/api/login", {
    method: "POST",
    data: { token: "é".repeat(token.length) },
  });
  assert.equal(result.status, 401);
});
const token = "test-server-token-long-enough-for-security";
const pause = (ms) => new Promise((r) => setTimeout(r, ms));
async function until(fn) {
  for (let n = 0; n < 100; n++) {
    if (fn()) return;
    await pause(20);
  }
  assert.fail("Condition did not become true");
}
async function listen(s) {
  await new Promise((r) => s.listen(0, "127.0.0.1", r));
  return `http://127.0.0.1:${s.address().port}`;
}
async function fixture(t, { temperatureUnit = "°C" } = {}) {
  const dir = await mkdtemp(path.join(os.tmpdir(), "house-server-")),
    commands = [];
  let reject = false;
  const states = [
    {
      entity_id: "light.kitchen",
      state: "on",
      attributes: {
        friendly_name: "Kitchen",
        brightness: 128,
        supported_color_modes: ["brightness"],
      },
    },
    {
      entity_id: "climate.bedroom",
      state: "cool",
      attributes: {
        hvac_modes: ["off", "cool", "heat"],
        temperature: 23,
        current_temperature: 25,
        min_temp: 16,
        max_temp: 30,
        fan_modes: ["Auto", "Low", "High"],
      },
    },
    {
      entity_id: "sensor.outside",
      state: "68",
      attributes: { device_class: "temperature", unit_of_measurement: "°F" },
    },
  ];
  const mock = http.createServer(async (req, res) => {
    if (req.headers.authorization !== "Bearer mock-ha-secret") {
      res.writeHead(401);
      return res.end("{}");
    }
    let raw = "";
    for await (const c of req) raw += c;
    res.setHeader("Content-Type", "application/json");
    if (req.url === "/api/config")
      return res.end(
        JSON.stringify({
          location_name: "Mock Home",
          version: "test",
          unit_system: { temperature: temperatureUnit },
        }),
      );
    if (req.url === "/api/states") return res.end(JSON.stringify(states));
    commands.push({ url: req.url, body: JSON.parse(raw) });
    res.writeHead(reject ? 400 : 200);
    res.end("[]");
  });
  const sockets = new WebSocketServer({ server: mock, path: "/api/websocket" });
  let subscriptions = 0;
  sockets.on("connection", (ws) => {
    ws.send(JSON.stringify({ type: "auth_required" }));
    ws.on("message", (raw) => {
      const msg = JSON.parse(raw);
      if (msg.type === "auth") {
        assert.equal(msg.access_token, "mock-ha-secret");
        ws.send(JSON.stringify({ type: "auth_ok" }));
      }
      if (msg.type === "subscribe_events") {
        subscriptions++;
        ws.send(
          JSON.stringify({
            id: msg.id,
            type: "result",
            success: true,
            result: null,
          }),
        );
      }
    });
  });
  const haURL = await listen(mock);
  let app = await createHouseServer({
    token,
    dataDir: dir,
    ha: new HomeAssistant({ retryMs: 20 }),
  });
  let base = await listen(app.server);
  const request = async (
    route,
    { method = "GET", data, headers = {} } = {},
  ) => {
    const response = await fetch(base + route, {
      method,
      headers: {
        Authorization: `Bearer ${token}`,
        ...(data ? { "Content-Type": "application/json" } : {}),
        ...headers,
      },
      body: data ? JSON.stringify(data) : undefined,
    });
    return {
      status: response.status,
      data: await response.json(),
      headers: response.headers,
    };
  };
  t.after(async () => {
    app.ha.stop();
    app.server.closeAllConnections();
    await new Promise((r) => app.server.close(r));
    for (const ws of sockets.clients) ws.terminate();
    await new Promise((r) => sockets.close(r));
    await new Promise((r) => mock.close(r));
    await rm(dir, { recursive: true, force: true });
  });
  return {
    request,
    states,
    commands,
    sockets,
    haURL,
    dir,
    get app() {
      return app;
    },
    get base() {
      return base;
    },
    setReject: () => (reject = true),
    get subscriptions() {
      return subscriptions;
    },
    restart: async () => {
      app.server.closeAllConnections();
      await new Promise((r) => app.server.close(r));
      app = await createHouseServer({
        token,
        dataDir: dir,
        ha: new HomeAssistant({ retryMs: 20 }),
      });
      base = await listen(app.server);
    },
  };
}
test("authentication, CSRF and private endpoint protection", async (t) => {
  const f = await fixture(t);
  for (const route of ["/api/bootstrap", "/api/plan", "/api/events"]) {
    const r = await fetch(f.base + route);
    assert.equal(r.status, 401);
  }
  assert.equal((await fetch(f.base + "/healthz")).status, 200);
  const login = await f.request("/api/login", {
    method: "POST",
    data: { token },
  });
  assert.equal(login.status, 200);
  const cookie = login.headers.get("set-cookie");
  assert.match(cookie, /HttpOnly/);
  assert.match(cookie, /SameSite=Strict/);
  const headers = { Authorization: "", Cookie: cookie.split(";")[0] };
  assert.equal(
    (await f.request("/api/logout", { method: "POST", data: {}, headers }))
      .status,
    403,
  );
  assert.equal(
    (
      await f.request("/api/logout", {
        method: "POST",
        data: {},
        headers: {
          ...headers,
          "X-CSRF-Token": login.data.csrfToken,
          Origin: "http://evil.invalid",
        },
      })
    ).status,
    403,
  );
  assert.equal(
    (
      await f.request("/api/logout", {
        method: "POST",
        data: {},
        headers: { ...headers, "X-CSRF-Token": login.data.csrfToken },
      })
    ).status,
    200,
  );
  assert.equal((await f.request("/api/bootstrap", { headers })).status, 401);
});
test("atomic shared plans survive restart and reject stale and concurrent edits", async (t) => {
  const f = await fixture(t),
    initial = (await f.request("/api/plan")).data;
  const config = { ...initial.config, name: "Shared custom" };
  const saves = await Promise.all([
    f.request("/api/plan", {
      method: "PUT",
      data: { config, expectedRevision: initial.revision },
    }),
    f.request("/api/plan", {
      method: "PUT",
      data: {
        config: { ...config, name: "Other" },
        expectedRevision: initial.revision,
      },
    }),
  ]);
  assert.deepEqual(saves.map((x) => x.status).sort(), [200, 409]);
  assert.equal(
    saves.find((x) => x.status === 409).data.code,
    "revision_conflict",
  );
  const saved = (await f.request("/api/plan")).data;
  await f.restart();
  assert.deepEqual((await f.request("/api/plan")).data, saved);
  assert.equal(
    (
      await f.request("/api/plan", {
        method: "PUT",
        data: { config, expectedRevision: initial.revision },
      })
    ).status,
    409,
  );
  assert.equal(
    (
      await f.request("/api/plan", {
        method: "PUT",
        data: { config: { rooms: [] }, expectedRevision: saved.revision },
      })
    ).status,
    400,
  );
  assert.equal(
    (await stat(path.join(f.dir, "house.json"))).mode & 0o777,
    0o600,
  );
});
test("HA discovery, linked controls, rejected commands, live updates and reconnect", async (t) => {
  const f = await fixture(t),
    send = (data) => f.request("/api/call", { method: "POST", data });
  assert.equal(
    (
      await send({
        type: "homeassistant.connect",
        url: f.haURL,
        token: "wrong",
      })
    ).status,
    400,
  );
  const connected = await send({
    type: "homeassistant.connect",
    url: f.haURL,
    token: "mock-ha-secret",
  });
  assert.equal(connected.status, 200);
  assert.equal(
    JSON.stringify(connected.data).includes("mock-ha-secret"),
    false,
  );
  await until(() => f.subscriptions === 1 && f.app.ha.live);
  const catalog = (await send({ type: "devices.all" })).data.devices;
  assert.equal(catalog.length, 3);
  assert.equal(
    catalog.find((x) => x.id === "light.kitchen").capabilities[0],
    "brightness",
  );
  let plan = (await f.request("/api/plan")).data;
  plan.config.lights[0].link = {
    service: "homeassistant",
    id: "light.kitchen",
  };
  const id = plan.config.lights[0].id;
  await f.request("/api/plan", {
    method: "PUT",
    data: { config: plan.config, expectedRevision: plan.revision },
  });
  const command = {
    type: "command",
    kind: "light",
    id,
    patch: { brightness: 0.6 },
    state: { on: true },
  };
  assert.equal((await send(command)).status, 200);
  assert.deepEqual(f.commands[0], {
    url: "/api/services/light/turn_on",
    body: { entity_id: "light.kitchen", brightness_pct: 60 },
  });
  assert.equal(
    (await send({ ...command, patch: { target: 999 } })).status,
    400,
  );
  assert.equal((await send({ ...command, id: "light.kitchen" })).status, 400);
  f.setReject();
  const refused = await send(command);
  assert.equal(refused.status, 502);
  assert.equal(refused.data.code, "command_failed");
  assert.deepEqual(refused.data.failed, ["brightness"]);
  const abort = new AbortController(),
    events = await fetch(f.base + "/api/events", {
      headers: { Authorization: `Bearer ${token}` },
      signal: abort.signal,
    });
  const reader = events.body.getReader();
  let text = "";
  text += new TextDecoder().decode((await reader.read()).value);
  assert.match(text, /applyRemote/);
  const changed = { ...f.states[0], state: "off" };
  for (const ws of f.sockets.clients)
    ws.send(
      JSON.stringify({
        type: "event",
        event: {
          event_type: "state_changed",
          data: { entity_id: changed.entity_id, new_state: changed },
        },
      }),
    );
  await until(() => f.app.ha.states.get("light.kitchen").state === "off");
  text += new TextDecoder().decode((await reader.read()).value);
  assert.match(text, /"on":false/);
  abort.abort();
  for (const ws of f.sockets.clients) ws.close();
  await until(() => f.subscriptions >= 2 && f.app.ha.live);
  const boot = await f.request("/api/bootstrap");
  assert.equal(JSON.stringify(boot.data).includes("mock-ha-secret"), false);
  assert.equal(
    (await readFile(path.join(f.dir, "house.json"), "utf8")).includes(
      "mock-ha-secret",
    ),
    true,
  );
  await f.restart();
  await until(() => f.app.ha.live);
  assert.equal(f.app.ha.info().name, "Mock Home");
});

test("standard white-temperature UI patches control non-RGB lights through the API", async (t) => {
  const f = await fixture(t);
  f.states[0].attributes.supported_color_modes = ["color_temp"];
  const send = (data) => f.request("/api/call", { method: "POST", data });
  await send({
    type: "homeassistant.connect",
    url: f.haURL,
    token: "mock-ha-secret",
  });
  await until(() => f.app.ha.live);
  const plan = (await f.request("/api/plan")).data;
  const light = plan.config.lights[0];
  light.link = { service: "homeassistant", id: "light.kitchen" };
  await f.request("/api/plan", {
    method: "PUT",
    data: { config: plan.config, expectedRevision: plan.revision },
  });
  assert.equal(
    (
      await send({
        type: "command",
        kind: "light",
        id: light.id,
        patch: { temp: 3000, color: null },
        state: { on: true },
      })
    ).status,
    200,
  );
  assert.deepEqual(f.commands.at(-1).body, {
    entity_id: "light.kitchen",
    color_temp_kelvin: 3000,
  });
  assert.equal(
    (
      await send({
        type: "command",
        kind: "light",
        id: light.id,
        patch: { color: "#ff0000" },
        state: { on: true },
      })
    ).status,
    400,
  );
});

test("Fahrenheit climate catalog, readings and commands use Celsius panel values", async (t) => {
  const f = await fixture(t, { temperatureUnit: "°F" }),
    send = (data) => f.request("/api/call", { method: "POST", data });
  Object.assign(f.states[1].attributes, {
    min_temp: 50,
    max_temp: 90,
    temperature: 68,
    current_temperature: 77,
  });
  await send({
    type: "homeassistant.connect",
    url: f.haURL,
    token: "mock-ha-secret",
  });
  await until(() => f.app.ha.live);
  const catalog = (await send({ type: "devices.all" })).data.devices,
    climate = catalog.find((d) => d.kind === "ac");
  assert.equal(climate.min, 10);
  assert.equal(climate.max, 32);
  const plan = (await f.request("/api/plan")).data,
    ac = plan.config.acs[0];
  ac.link = { service: "homeassistant", id: "climate.bedroom" };
  await f.request("/api/plan", {
    method: "PUT",
    data: { config: plan.config, expectedRevision: plan.revision },
  });
  const boot = (await f.request("/api/bootstrap")).data;
  assert.equal(boot.deviceState.acs[ac.id].target, 20);
  assert.equal(boot.deviceState.acs[ac.id].roomTemp, 25);
  assert.equal(
    (
      await send({
        type: "command",
        kind: "ac",
        id: ac.id,
        patch: { target: 21 },
        state: { mode: "cool" },
      })
    ).status,
    200,
  );
  assert.equal(f.commands.at(-1).body.temperature, 69.8);
});

test("heat_cool commands preserve the reported deadband or reject unsafe ranges", () => {
  const state = {
    entity_id: "climate.range",
    state: "heat_cool",
    attributes: {
      temperature_unit: "°F",
      hvac_modes: ["heat_cool"],
      min_temp: 50,
      max_temp: 90,
      target_temp_low: 66,
      target_temp_high: 74,
    },
  };
  const result = calls(state, { target: 21 }, { mode: "auto" });
  assert.deepEqual(result[0].data, {
    entity_id: "climate.range",
    target_temp_low: 65.8,
    target_temp_high: 73.8,
  });
  assert.equal(reading(state).ac.target, ((70 - 32) * 5) / 9);
  assert.throws(() => calls(state, { target: 10 }, { mode: "auto" }), /range/);
  assert.throws(
    () =>
      calls(
        {
          ...state,
          attributes: { ...state.attributes, target_temp_low: null },
        },
        { target: 21 },
        { mode: "auto" },
      ),
    /separate low and high/,
  );
});

test("deferred HA refreshes cannot replace a new or disconnected catalog", async (t) => {
  class Socket extends EventTarget {
    close() {}
  }
  let release;
  const ha = new HomeAssistant({
    Socket,
    fetchImpl: () => new Promise((resolve) => (release = resolve)),
  });
  t.after(() => ha.stop());
  ha.adopt({ url: "http://a.test", token: "a" });
  const pending = ha.refresh();
  ha.adopt({ url: "http://b.test", token: "b" }, [
    { entity_id: "light.b", state: "on" },
  ]);
  release({
    ok: true,
    json: async () => [{ entity_id: "light.a", state: "on" }],
  });
  await pending;
  assert.deepEqual([...ha.states.keys()], ["light.b"]);
  const afterB = ha.refresh();
  ha.disconnect();
  release({
    ok: true,
    json: async () => [{ entity_id: "light.b", state: "on" }],
  });
  await afterB;
  assert.equal(ha.states.size, 0);
  assert.equal(ha.info().connected, false);
});

test("connection mutations serialize persistence and failed candidates retain the working connection", async (t) => {
  const f = await fixture(t),
    send = (data) => f.request("/api/call", { method: "POST", data });
  await send({
    type: "homeassistant.connect",
    url: f.haURL,
    token: "mock-ha-secret",
  });
  await until(() => f.app.ha.live);
  const original = f.app.ha.request.bind(f.app.ha),
    before = f.app.ha.config;
  f.app.ha.request = async (path, options) => {
    if (path === "/api/states" && options?.config?.token === "candidate")
      throw new Error("Candidate states unavailable");
    if (options?.config?.token === "candidate")
      return { location_name: "Candidate" };
    return original(path, options);
  };
  assert.equal(
    (
      await send({
        type: "homeassistant.connect",
        url: "http://candidate.test",
        token: "candidate",
      })
    ).status,
    400,
  );
  assert.deepEqual(f.app.ha.config, before);
  assert.deepEqual(
    JSON.parse(await readFile(path.join(f.dir, "house.json"), "utf8")).ha,
    before,
  );
  let release,
    entered = false;
  f.app.ha.request = async (path, options) => {
    if (path === "/api/config") {
      entered = true;
      await new Promise((resolve) => (release = resolve));
    }
    return original(path, options);
  };
  const connecting = send({
    type: "homeassistant.connect",
    url: f.haURL,
    token: "mock-ha-secret",
  });
  await until(() => entered);
  const disconnecting = send({
    type: "service.disconnect",
    service: "homeassistant",
  });
  release();
  assert.equal((await connecting).status, 200);
  assert.equal((await disconnecting).status, 200);
  assert.equal(f.app.ha.info().connected, false);
  assert.equal(
    JSON.parse(await readFile(path.join(f.dir, "house.json"), "utf8")).ha,
    undefined,
  );
});

test("a subscription snapshot preserves newer updates and entity deletions", async (t) => {
  const sockets = [];
  class Socket extends EventTarget {
    constructor() {
      super();
      sockets.push(this);
    }
    send() {}
    close() {}
  }
  let release;
  const ha = new HomeAssistant({
    Socket,
    fetchImpl: () => new Promise((resolve) => (release = resolve)),
  });
  t.after(() => ha.stop());
  ha.adopt({ url: "http://mock.test", token: "mock" });
  const message = (value) =>
    sockets[0].dispatchEvent(
      new MessageEvent("message", { data: JSON.stringify(value) }),
    );
  message({ type: "result", id: 1, success: true });
  const event = (entity_id, new_state) =>
    message({
      type: "event",
      event: { event_type: "state_changed", data: { entity_id, new_state } },
    });
  event("light.current", { entity_id: "light.current", state: "on" });
  event("light.removed", null);
  release({
    ok: true,
    json: async () => [
      { entity_id: "light.current", state: "off" },
      { entity_id: "light.removed", state: "on" },
    ],
  });
  await until(() => ha.pendingRefreshes.size === 0);
  assert.equal(ha.states.get("light.current").state, "on");
  assert.equal(ha.states.has("light.removed"), false);
});

test("API refresh and SSE retain events newer than a deferred HTTP snapshot", async (t) => {
  const f = await fixture(t),
    send = (data) => f.request("/api/call", { method: "POST", data });
  await send({
    type: "homeassistant.connect",
    url: f.haURL,
    token: "mock-ha-secret",
  });
  await until(() => f.app.ha.live && f.app.ha.pendingRefreshes.size === 0);
  const plan = (await f.request("/api/plan")).data,
    light = plan.config.lights[0];
  light.link = { service: "homeassistant", id: "light.kitchen" };
  await f.request("/api/plan", {
    method: "PUT",
    data: { config: plan.config, expectedRevision: plan.revision },
  });
  const abort = new AbortController();
  t.after(() => abort.abort());
  const events = await fetch(f.base + "/api/events", {
    headers: { Authorization: `Bearer ${token}` },
    signal: abort.signal,
  });
  const reader = events.body.getReader();
  await reader.read();
  const original = f.app.ha.request.bind(f.app.ha);
  let release;
  f.app.ha.request = async (path, options) =>
    path === "/api/states"
      ? new Promise((resolve) => (release = resolve))
      : original(path, options);
  const refresh = send({ type: "devices.all" });
  await until(() => release);
  const changed = { ...f.states[0], state: "off" };
  for (const ws of f.sockets.clients) {
    ws.send(
      JSON.stringify({
        type: "event",
        event: {
          event_type: "state_changed",
          data: { entity_id: "light.kitchen", new_state: changed },
        },
      }),
    );
    ws.send(
      JSON.stringify({
        type: "event",
        event: {
          event_type: "state_changed",
          data: { entity_id: "sensor.outside", new_state: null },
        },
      }),
    );
  }
  await until(
    () =>
      f.app.ha.states.get("light.kitchen").state === "off" &&
      !f.app.ha.states.has("sensor.outside"),
  );
  const streamed = new TextDecoder().decode((await reader.read()).value);
  assert.match(streamed, /"on":false/);
  release(structuredClone(f.states));
  assert.equal((await refresh).status, 200);
  const boot = (await f.request("/api/bootstrap")).data;
  assert.equal(boot.deviceState.lights[light.id].on, false);
  assert.equal(f.app.ha.states.has("sensor.outside"), false);
  const snapshotEvent = new TextDecoder().decode((await reader.read()).value);
  assert.match(snapshotEvent, /"on":false/);
  abort.abort();
});
