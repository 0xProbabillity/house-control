import http from "node:http";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { readFile, stat } from "node:fs/promises";
import { randomBytes, timingSafeEqual } from "node:crypto";
import { Store } from "./storage.js";
import { HomeAssistant } from "./ha.js";
import { device, reading, calls } from "./mapping.js";
const here = path.dirname(fileURLToPath(import.meta.url));
const equal = (a, b) =>
  typeof a === "string" &&
  typeof b === "string" &&
  Buffer.byteLength(a) === Buffer.byteLength(b) &&
  timingSafeEqual(Buffer.from(a), Buffer.from(b));
const fail = (message, status = 400, code = "invalid_request", extra = {}) => {
  throw Object.assign(new Error(message), { status, code, ...extra });
};
async function body(req) {
  let raw = "";
  for await (const chunk of req) {
    raw += chunk;
    if (Buffer.byteLength(raw) > 1024 * 1024) fail("Request too large", 413);
  }
  try {
    return JSON.parse(raw);
  } catch {
    fail("Expected JSON");
  }
}
export async function createHouseServer({
  token = process.env.HOUSE_SERVER_TOKEN,
  dataDir = process.env.HOUSE_DATA_DIR || path.join(here, "data"),
  staticDir = path.resolve(here, "../web/dist"),
  plansDir = path.resolve(here, "../web/public/plans"),
  ha = new HomeAssistant(),
  secureCookie = process.env.HOUSE_SECURE_COOKIE === "true",
} = {}) {
  if (typeof token !== "string" || token.length < 24)
    throw new Error("HOUSE_SERVER_TOKEN must contain at least 24 characters");
  const attempts = new Map();
  const store = await new Store(dataDir, plansDir).init(),
    sessions = new Map(),
    streams = new Map();
  const services = () => ({ homeassistant: ha.info() });
  function state() {
    const out = { lights: {}, acs: {}, features: {}, online: {} };
    for (const [group, kind] of [
      ["lights", "light"],
      ["acs", "ac"],
    ])
      for (const item of store.state.config[group] || []) {
        const link = item.link;
        if (link?.service === "homeassistant") {
          const source = ha.states.get(link.id),
            r = source ? reading(source) : { online: false };
          out.online[item.id] = Boolean(ha.live && r.online);
          if (r[kind]) out[group][item.id] = r[kind];
          if (r.features) out.features[item.id] = r.features;
        }
        const sensor = item.sensor;
        if (kind === "ac" && sensor?.service === "homeassistant") {
          const s = ha.states.get(sensor.id),
            temp = s && reading(s).temperature;
          if (temp !== undefined)
            out.acs[item.id] = { ...out.acs[item.id], roomTemp: temp };
        }
      }
    return out;
  }
  function emit(type, data) {
    for (const [res, auth] of streams) {
      if (auth.expires < Date.now()) {
        res.end();
        streams.delete(res);
      } else res.write(`data: ${JSON.stringify({ type, data })}\n\n`);
    }
  }
  ha.on("states", () => emit("applyRemote", state()));
  ha.on("connection", () => {
    emit("servicesChanged", services());
    emit("connection", { connected: ha.live });
    emit("applyRemote", state());
  });
  if (store.state.ha) ha.adopt(store.state.ha);
  const revisionResult = (s) => {
    emit("planChanged", { revision: s.revision, plan: s.plan });
    emit("applyRemote", state());
    return { ok: true, revision: s.revision };
  };
  let haOperations = Promise.resolve();
  function call(data) {
    if (
      !["homeassistant.connect", "service.disconnect", "command"].includes(
        data.type,
      )
    )
      return callImpl(data);
    const operation = haOperations.then(() => callImpl(data));
    haOperations = operation.catch(() => {});
    return operation;
  }
  async function callImpl(data) {
    switch (data.type) {
      case "services.info":
        return services();
      case "services.discover":
        return { found: [], manual: true };
      case "devices.all":
        try {
          await ha.refresh();
          return {
            devices: [...ha.states.values()].map(device).filter(Boolean),
            errors: {},
          };
        } catch (e) {
          return { devices: [], errors: { homeassistant: e.message } };
        }
      case "homeassistant.connect": {
        const previous = ha.config,
          previousStates = [...ha.states.values()];
        const config = await ha.connect(data.url || "", data.token || "");
        try {
          await store.update((s) => ({ ...s, ha: config }));
        } catch (error) {
          ha.adopt(previous, previousStates);
          throw error;
        }
        emit("servicesChanged", services());
        return services();
      }
      case "service.disconnect":
        if (data.service !== "homeassistant")
          fail("This server supports Home Assistant connections");
        await store.update((s) => {
          delete s.ha;
          return s;
        });
        ha.disconnect();
        emit("servicesChanged", services());
        return services();
      case "savePlan":
        return revisionResult(
          await store.save(data.config, data.expectedRevision),
        );
      case "selectPlan":
        return revisionResult(
          await store.select(data.plan, data.expectedRevision),
        );
      case "command": {
        if (!["light", "ac"].includes(data.kind)) fail("Unknown device kind");
        const item = (
          store.state.config[data.kind === "light" ? "lights" : "acs"] || []
        ).find((x) => x.id === data.id);
        if (!item) fail("Device is not in the shared plan");
        if (!item.link && !item.tuya) return { ok: true, simulated: true };
        if (item.link?.service !== "homeassistant")
          fail(
            "Link this device through Home Assistant to control it on the server",
          );
        if (!ha.live)
          fail(
            "Home Assistant live connection is unavailable",
            502,
            "device_unavailable",
          );
        if (
          !data.patch ||
          typeof data.patch !== "object" ||
          Array.isArray(data.patch)
        )
          fail("Expected a control patch");
        const source = ha.states.get(item.link.id);
        if (!source)
          fail("Device state is unavailable", 502, "device_unavailable");
        if (device(source)?.kind !== data.kind)
          fail("Device link kind does not match");
        const list = calls(source, data.patch, data.state);
        for (const c of list)
          try {
            await ha.request(`/api/services/${c.domain}/${c.service}`, {
              method: "POST",
              body: c.data,
            });
          } catch (e) {
            fail(e.message, 502, "command_failed", {
              failed: Object.keys(data.patch),
            });
          }
        await ha.refresh().catch(() => {});
        return { ok: true };
      }
      case "ready":
      case "summary":
      case "state":
      case "widgets":
      case "haptic":
        return { ok: true };
      default:
        fail(
          "This action is unavailable on the server",
          400,
          "unsupported_action",
        );
    }
  }
  const json = (res, status, value) => {
    res.writeHead(status, {
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
    });
    res.end(JSON.stringify(value));
  };
  const server = http.createServer(async (req, res) => {
    res.setHeader("X-Content-Type-Options", "nosniff");
    res.setHeader("Referrer-Policy", "no-referrer");
    res.setHeader("X-Frame-Options", "DENY");
    try {
      const pathname = new URL(req.url, "http://localhost").pathname;
      if (pathname === "/healthz") return json(res, 200, { ok: true });
      if (pathname.startsWith("/api/")) {
        if (pathname === "/api/login" && req.method === "POST") {
          if (
            req.headers.origin &&
            new URL(req.headers.origin).host !== req.headers.host
          )
            fail("Origin refused", 403, "csrf");
          const address = req.socket.remoteAddress,
            now = Date.now(),
            prior = attempts.get(address);
          if (prior && prior.until > now && prior.count >= 10)
            fail(
              "Too many login attempts. Try again shortly.",
              429,
              "rate_limited",
            );
          const data = await body(req);
          if (!equal(data.token, token)) {
            attempts.set(address, {
              count: prior?.until > now ? prior.count + 1 : 1,
              until: prior?.until > now ? prior.until : now + 60000,
            });
            fail("Invalid server token", 401, "unauthorized");
          }
          attempts.delete(address);
          const id = randomBytes(32).toString("hex"),
            session = {
              csrf: randomBytes(24).toString("hex"),
              expires: Date.now() + 12 * 3600000,
            };
          sessions.set(id, session);
          res.setHeader(
            "Set-Cookie",
            `house_session=${id}; Path=/; HttpOnly; SameSite=Strict; Max-Age=43200${secureCookie ? "; Secure" : ""}`,
          );
          return json(res, 200, { ok: true, csrfToken: session.csrf });
        }
        const bearer =
          req.headers.authorization?.startsWith("Bearer ") &&
          equal(req.headers.authorization.slice(7), token);
        const sid = (req.headers.cookie || "")
            .split(";")
            .map((s) => s.trim())
            .find((s) => s.startsWith("house_session="))
            ?.slice(14),
          session = sessions.get(sid);
        if (!bearer && (!session || session.expires < Date.now()))
          fail("Sign in to House Control", 401, "unauthorized");
        if (
          !bearer &&
          !["GET", "HEAD"].includes(req.method) &&
          (!equal(req.headers["x-csrf-token"], session.csrf) ||
            (req.headers.origin &&
              new URL(req.headers.origin).host !== req.headers.host))
        )
          fail("Request verification failed", 403, "csrf");
        if (pathname === "/api/logout" && req.method === "POST") {
          sessions.delete(sid);
          for (const [stream, auth] of streams)
            if (auth === session) {
              stream.end();
              streams.delete(stream);
            }
          res.setHeader(
            "Set-Cookie",
            "house_session=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0",
          );
          return json(res, 200, { ok: true });
        }
        if (pathname === "/api/bootstrap" && req.method === "GET")
          return json(res, 200, {
            platform: "web",
            config: store.state.config,
            plan: store.state.plan,
            hasCustomPlan: !!store.state.customConfig,
            services: services(),
            server: {
              revision: store.state.revision,
              csrfToken: session?.csrf || null,
            },
            deviceState: state(),
          });
        if (pathname === "/api/plan" && req.method === "GET")
          return json(res, 200, {
            config: store.state.config,
            plan: store.state.plan,
            revision: store.state.revision,
          });
        if (pathname === "/api/plan" && req.method === "PUT") {
          const data = await body(req);
          return json(
            res,
            200,
            revisionResult(
              await store.save(data.config, data.expectedRevision),
            ),
          );
        }
        if (pathname === "/api/call" && req.method === "POST")
          return json(res, 200, await call(await body(req)));
        if (pathname === "/api/events" && req.method === "GET") {
          res.writeHead(200, {
            "Content-Type": "text/event-stream",
            "Cache-Control": "no-cache",
            Connection: "keep-alive",
            "X-Accel-Buffering": "no",
          });
          streams.set(res, session || { expires: Infinity });
          res.write(
            `data: ${JSON.stringify({ type: "applyRemote", data: state() })}\n\ndata: ${JSON.stringify({ type: "servicesChanged", data: services() })}\n\n`,
          );
          req.on("close", () => streams.delete(res));
          return;
        }
        fail("Unknown API endpoint", 404, "not_found");
      }
      if (!["GET", "HEAD"].includes(req.method))
        fail("Method not allowed", 405);
      const decoded = decodeURIComponent(pathname),
        file = path.resolve(staticDir, "." + decoded);
      if (file !== staticDir && !file.startsWith(staticDir + path.sep))
        fail("Not found", 404);
      let target = file;
      try {
        if ((await stat(target)).isDirectory())
          target = path.join(target, "index.html");
      } catch {
        target = path.join(staticDir, "index.html");
      }
      const ext = path.extname(target),
        mime = {
          ".html": "text/html",
          ".js": "text/javascript",
          ".css": "text/css",
          ".json": "application/json",
          ".svg": "image/svg+xml",
          ".png": "image/png",
          ".woff2": "font/woff2",
        };
      let content = await readFile(target);
      if (ext === ".html")
        content = Buffer.from(
          content
            .toString()
            .replace(
              "<head>",
              "<head><script>window.__HOUSE_SERVER__=true;</script>",
            ),
        );
      res.writeHead(200, {
        "Content-Type": mime[ext] || "application/octet-stream",
        "Cache-Control": ext === ".html" ? "no-store" : "public, max-age=3600",
      });
      res.end(req.method === "HEAD" ? undefined : content);
    } catch (e) {
      if (!res.headersSent)
        json(res, e.status || 400, {
          error: e.message,
          code: e.code || "invalid_request",
          ...(e.revision !== undefined ? { revision: e.revision } : {}),
          ...(e.failed ? { failed: e.failed } : {}),
        });
      else res.end();
    }
  });
  const heartbeat = setInterval(() => {
    for (const [res, auth] of streams) {
      if (auth.expires < Date.now()) res.end();
      else res.write(": heartbeat\n\n");
    }
    for (const [id, s] of sessions)
      if (s.expires < Date.now()) sessions.delete(id);
    for (const [address, a] of attempts)
      if (a.until < Date.now()) attempts.delete(address);
  }, 20000);
  heartbeat.unref();
  server.on("close", () => {
    clearInterval(heartbeat);
    ha.stop();
    for (const res of streams.keys()) res.end();
  });
  return { server, store, ha };
}
if (
  process.argv[1] &&
  path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)
) {
  const { server } = await createHouseServer();
  server.listen(Number(process.env.PORT) || 8080, "0.0.0.0", () =>
    console.log("House Control server listening"),
  );
  for (const signal of ["SIGINT", "SIGTERM"])
    process.on(signal, () => {
      server.close();
      server.closeAllConnections();
    });
}
