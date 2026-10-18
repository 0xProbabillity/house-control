import { EventEmitter } from "node:events";
export class HomeAssistant extends EventEmitter {
  constructor({ fetchImpl = fetch, Socket = WebSocket, retryMs = 2000 } = {}) {
    super();
    this.fetch = fetchImpl;
    this.Socket = Socket;
    this.retryMs = retryMs;
    this.states = new Map();
    this.live = false;
    this.generation = 0;
    this.refreshSequence = 0;
    this.pendingRefreshes = new Set();
  }
  info() {
    return this.config
      ? {
          connected: true,
          url: this.config.url,
          name: this.config.name || "Home Assistant",
          version: this.config.version || "",
          live: this.live,
        }
      : { connected: false, live: false };
  }
  async request(path, { method = "GET", body, config = this.config } = {}) {
    if (!config) throw new Error("Connect Home Assistant first");
    let res;
    try {
      res = await this.fetch(config.url + path, {
        method,
        headers: {
          Authorization: `Bearer ${config.token}`,
          "Content-Type": "application/json",
        },
        body: body === undefined ? undefined : JSON.stringify(body),
        signal: AbortSignal.timeout(10000),
      });
    } catch {
      throw new Error("Home Assistant did not answer");
    }
    if (!res.ok)
      throw new Error(`Home Assistant refused the request (${res.status})`);
    return res.status === 204 ? null : res.json();
  }
  async connect(raw, token) {
    const generation = this.generation;
    const url = new URL(raw.includes("://") ? raw : `http://${raw}`);
    if (
      !["http:", "https:"].includes(url.protocol) ||
      url.username ||
      url.password ||
      url.search ||
      url.hash ||
      url.pathname !== "/"
    )
      throw new Error("Enter a Home Assistant HTTP(S) origin");
    if (!token?.trim()) throw new Error("Enter a Home Assistant access token");
    const config = { url: url.origin, token: token.trim() };
    const about = await this.request("/api/config", { config });
    config.name = about.location_name;
    config.version = about.version;
    config.temperatureUnit = about.unit_system?.temperature || "°C";
    // Validate the candidate completely before replacing a working connection.
    const states = await this.request("/api/states", { config });
    if (!Array.isArray(states))
      throw new Error("Home Assistant returned an invalid state catalog");
    if (generation !== this.generation)
      throw new Error("Home Assistant connection changed while connecting");
    this.adopt(config, states);
    return config;
  }
  normalizeState(state, config = this.config) {
    if (!state.entity_id?.startsWith("climate.")) return state;
    return {
      ...state,
      attributes: {
        ...state.attributes,
        temperature_unit:
          state.attributes?.temperature_unit ||
          state.attributes?.unit_of_measurement ||
          config?.temperatureUnit ||
          "°C",
      },
    };
  }
  adopt(config, states = []) {
    this.stop();
    this.config = config;
    this.states = new Map(
      states.map((s) => [s.entity_id, this.normalizeState(s)]),
    );
    this.emit("states");
    if (config) this.listen();
  }
  async refresh() {
    const generation = this.generation,
      config = this.config,
      sequence = ++this.refreshSequence;
    // The HTTP snapshot may predate WebSocket events received while it is in flight.
    // Keep the latest event per entity, including tombstones for removed entities.
    const changes = new Map();
    this.pendingRefreshes.add(changes);
    try {
      const states = await this.request("/api/states", { config });
      if (generation !== this.generation || sequence !== this.refreshSequence)
        return [...this.states.values()];
      const snapshot = new Map(
        states.map((s) => [s.entity_id, this.normalizeState(s, config)]),
      );
      for (const [id, state] of changes) {
        if (state) snapshot.set(id, state);
        else snapshot.delete(id);
      }
      this.states = snapshot;
      this.emit("states");
      return [...snapshot.values()];
    } finally {
      this.pendingRefreshes.delete(changes);
    }
  }
  listen() {
    if (!this.config) return;
    const config = this.config;
    const socket = new this.Socket(
      config.url.replace(/^http/, "ws") + "/api/websocket",
    );
    this.socket = socket;
    let ready = false;
    const fail = () => {
      if (this.socket !== socket) return;
      clearTimeout(this.authTimer);
      clearInterval(this.ping);
      this.live = false;
      this.emit("connection");
      socket.close();
      this.socket = null;
      this.retry = setTimeout(() => this.listen(), this.retryMs);
      this.retry.unref?.();
    };
    this.authTimer = setTimeout(fail, 10000);
    this.authTimer.unref?.();
    socket.addEventListener("message", (event) => {
      if (this.socket !== socket) return;
      let msg;
      try {
        msg = JSON.parse(event.data);
      } catch {
        return fail();
      }
      if (msg.type === "auth_required")
        socket.send(
          JSON.stringify({ type: "auth", access_token: config.token }),
        );
      else if (msg.type === "auth_ok")
        socket.send(
          JSON.stringify({
            id: 1,
            type: "subscribe_events",
            event_type: "state_changed",
          }),
        );
      else if (
        msg.type === "auth_invalid" ||
        (msg.type === "result" && msg.id === 1 && !msg.success)
      )
        fail();
      else if (msg.type === "result" && msg.id === 1 && msg.success) {
        ready = true;
        clearTimeout(this.authTimer);
        this.live = true;
        this.emit("connection");
        this.refresh().catch(fail);
        this.ping = setInterval(() => {
          if (this.socket === socket)
            socket.send(JSON.stringify({ id: 2, type: "ping" }));
        }, 30000);
        this.ping.unref?.();
      } else if (
        ready &&
        msg.type === "event" &&
        msg.event?.event_type === "state_changed"
      ) {
        const { entity_id, new_state } = msg.event.data;
        const state = new_state ? this.normalizeState(new_state) : null;
        for (const changes of this.pendingRefreshes)
          changes.set(entity_id, state);
        if (state) this.states.set(entity_id, state);
        else this.states.delete(entity_id);
        this.emit("states");
      }
    });
    socket.addEventListener("close", fail);
    socket.addEventListener("error", fail);
  }
  stop() {
    this.generation++;
    this.pendingRefreshes.clear();
    clearTimeout(this.retry);
    clearTimeout(this.authTimer);
    clearInterval(this.ping);
    const socket = this.socket;
    this.socket = null;
    socket?.close();
    this.live = false;
  }
  disconnect() {
    this.stop();
    this.config = null;
    this.states.clear();
    this.emit("connection");
    this.emit("states");
  }
}
