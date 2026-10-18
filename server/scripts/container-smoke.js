// Explicit executable smoke probe: node --test does not discover this filename.
import assert from "node:assert/strict";
import { setTimeout } from "node:timers/promises";
const base = process.env.HOUSE_TEST_URL || "http://127.0.0.1:8080";
let healthy = false;
for (let i = 0; i < 60; i++) {
  try {
    healthy = (await fetch(base + "/healthz")).ok;
  } catch {}
  if (healthy) break;
  await setTimeout(500);
}
assert.ok(healthy, "container became healthy");
assert.equal((await fetch(base + "/api/plan")).status, 401);
const index = await (await fetch(base)).text();
assert.match(index, /__HOUSE_SERVER__/);
assert.match(index, /assets\//);
const headers = {
  Authorization: `Bearer ${process.env.HOUSE_SERVER_TOKEN}`,
  "Content-Type": "application/json",
};
const before = await (await fetch(base + "/api/plan", { headers })).json();
if (process.argv.includes("--verify")) {
  assert.equal(before.config.name, "Container persistence smoke");
  assert.equal(before.revision, 2);
} else {
  const response = await fetch(base + "/api/plan", {
    method: "PUT",
    headers,
    body: JSON.stringify({
      config: { ...before.config, name: "Container persistence smoke" },
      expectedRevision: before.revision,
    }),
  });
  assert.equal(response.status, 200);
  const conflict = await fetch(base + "/api/plan", {
    method: "PUT",
    headers,
    body: JSON.stringify({
      config: before.config,
      expectedRevision: before.revision,
    }),
  });
  assert.equal(conflict.status, 409);
}
console.log("Container auth, static assets and persisted plan checks passed");
