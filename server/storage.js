import { mkdir, readFile, writeFile, rename } from "node:fs/promises";
import path from "node:path";
import { normalize } from "../web/src/config.js";
function validateKeys(value) {
  if (!value || typeof value !== "object") return;
  for (const [key, child] of Object.entries(value)) {
    if (["__proto__", "constructor", "prototype"].includes(key))
      throw new Error("Unsafe plan key");
    if (
      key === "id" &&
      ["__proto__", "constructor", "prototype"].includes(child)
    )
      throw new Error("Unsafe plan identifier");
    validateKeys(child);
  }
}
export class Store {
  constructor(dir, plans) {
    this.dir = dir;
    this.plans = plans;
    this.queue = Promise.resolve();
  }
  async init() {
    await mkdir(this.dir, { recursive: true, mode: 0o700 });
    try {
      this.state = JSON.parse(
        await readFile(path.join(this.dir, "house.json"), "utf8"),
      );
      validateKeys(this.state);
      normalize(this.state.config);
      if (!Number.isSafeInteger(this.state.revision))
        throw new Error("Invalid persisted revision");
    } catch (e) {
      if (e.code !== "ENOENT") throw e;
      this.state = {
        revision: 1,
        plan: "home",
        config: JSON.parse(
          await readFile(path.join(this.plans, "home.json"), "utf8"),
        ),
      };
      await this.persist(this.state);
    }
    return this;
  }
  async persist(value) {
    const name = path.join(this.dir, "house.json"),
      temp = name + ".tmp";
    await writeFile(temp, JSON.stringify(value, null, 2), { mode: 0o600 });
    await rename(temp, name);
  }
  update(fn) {
    const task = this.queue.then(async () => {
      const value = await fn(structuredClone(this.state));
      await this.persist(value);
      this.state = value;
      return value;
    });
    this.queue = task.catch(() => {});
    return task;
  }
  save(config, expectedRevision, plan = "custom") {
    validateKeys(config);
    normalize(config);
    return this.update((s) => {
      if (expectedRevision !== s.revision)
        throw Object.assign(
          new Error("The shared plan changed. Reload before saving."),
          { status: 409, code: "revision_conflict", revision: s.revision },
        );
      return {
        ...s,
        config,
        plan,
        ...(plan === "custom" ? { customConfig: config } : {}),
        revision: s.revision + 1,
      };
    });
  }
  async select(plan, expected) {
    if (!["home", "studio", "custom"].includes(plan))
      throw new Error("Unknown plan");
    const config =
      plan === "custom"
        ? this.state.customConfig
        : this.state.plan === plan
          ? this.state.config
          : JSON.parse(
              await readFile(path.join(this.plans, plan + ".json"), "utf8"),
            );
    if (!config) throw new Error("No saved custom plan");
    return this.save(config, expected, plan);
  }
}
