# Linux server

Node 24 serves the shared web UI, stores the selected plan, and controls devices through Home Assistant. Existing Apple applications retain their native providers. Linux supports lights, switches, climate entities and temperature sensors through Home Assistant; add Hue, Smart Life or Matter devices to Home Assistant first. Network discovery is manual: enter the Home Assistant address in Connections.

The panel uses Celsius. Climate discovery, readings and outgoing targets convert from Home Assistant's configured temperature unit (or an entity unit override). In `heat_cool`, moving the target shifts the currently reported low/high range while preserving its width; targets that would cross device limits, missing ranges or explicitly unsupported controls fail visibly. Home Assistant requires [low/high targets for heat/cool mode](https://www.home-assistant.io/actions/climate.set_temperature/).

Build the web UI with `cd web && npm ci && npm run build`, then run `HOUSE_SERVER_TOKEN=<random token of at least 24 characters> node server/src.js`. Generate a token with `openssl rand -hex 32`. Keep it out of source control. The default data directory is `server/data`; set `HOUSE_DATA_DIR` to a durable private directory for production. Run one server process per data directory. Back up `house.json` as a secret: it contains the Home Assistant access token as well as the shared plans. The directory and file are created with owner-only permissions. Unreadable or corrupt persisted state stops startup rather than overwriting it.

For Docker, export `HOUSE_SERVER_TOKEN`, then `docker compose up --build -d`. The service runs as the Node user, uses a persistent named volume, drops Linux capabilities and exposes a health check. The Node base image supports Linux amd64 and arm64. Compose binds localhost by default. Set `HOUSE_BIND_ADDRESS=0.0.0.0` for trusted LAN access, or put an HTTPS reverse proxy in front and set `HOUSE_SECURE_COOKIE=true`. Use HTTPS whenever credentials traverse an untrusted network. The server must be able to reach Home Assistant; `localhost` inside its container is the container itself. Connect using the Home Assistant host's LAN address.

## API

All `/api` endpoints except login require either `Authorization: Bearer <HOUSE_SERVER_TOKEN>` or a session cookie from `POST /api/login {"token":"..."}`. Login returns `csrfToken`; cookie-authenticated mutations require `X-CSRF-Token`. Cookies are HttpOnly, SameSite Strict and expire after 12 hours; logout revokes the cookie and its event streams. `HOUSE_SECURE_COOKIE=true` adds Secure for HTTPS deployments. Tokens are never returned in bootstrap, device events or provider information. The HTTP server does not log requests or payloads.

- `GET /api/bootstrap`: native-style boot data, raw `config`, selected `plan`, `services`, `server: {revision, csrfToken}`, `deviceState`.
- `GET /api/plan`: `{config, plan, revision}`.
- `PUT /api/plan`: `{config, expectedRevision}`; returns `{ok, revision}`. Missing or stale revisions return 409 `{error, code:"revision_conflict", revision}`. Clients must preserve their draft and explicitly reload or reconcile; never retry with the latest revision automatically.
- `POST /api/call`: native bridge calls. Supports `services.info`, `devices.all`, `homeassistant.connect`, `service.disconnect`, `services.discover` (manual), `command`, `savePlan`, `selectPlan`. Commands use the saved plan's binding, never a client-supplied HA entity. Unlinked items are explicitly simulated. Unsupported providers and control fields fail.
- `GET /api/events`: SSE messages `{type, data}` for `applyRemote`, `servicesChanged`, `planChanged`, `connection`. Each connection gets a current snapshot. The HA WebSocket reconnects and refreshes state after reconnect; clients also refresh bootstrap on their own reconnect.
- `POST /api/logout`: revokes the browser session.
- `GET /healthz`: public liveness only.

Errors use HTTP 400/401/403/409/502 and `{error, code, revision?, failed?}`. Plans are validated with the shared web normalizer and written atomically; serial mutation processing rejects concurrent stale saves. Settings credentials persist separately from the plan revision in the same private state file. The shared-plan revision is a monotonically increasing integer, including plan selection. Built-in home/studio selection preserves the last custom plan.

Run `cd server && npm ci && npm test` for mock Home Assistant integration tests. They never connect to real devices.

The Server GitHub workflow also builds the Docker image and probes authentication, built assets, conflicting saves and persistence across a real container restart. `HOUSE_SERVER_TOKEN=... node server/scripts/container-smoke.js` can run the same probe against a disposable local server; it changes that server's plan name, so use a test volume only.
