# Linux server

Node 24 serves the shared web UI, stores the selected plan, and controls devices through Home Assistant. Existing Apple applications retain their native providers. Linux supports lights, switches, climate entities and temperature sensors through Home Assistant; add Hue, Smart Life or Matter devices to Home Assistant first. Network discovery is manual: enter the Home Assistant address in Connections.

The panel uses Celsius. Climate discovery, readings and outgoing targets convert from Home Assistant's configured temperature unit (or an entity unit override). In `heat_cool`, moving the target shifts the currently reported low/high range while preserving its width; targets that would cross device limits, missing ranges or explicitly unsupported controls fail visibly. Home Assistant requires [low/high targets for heat/cool mode](https://www.home-assistant.io/actions/climate.set_temperature/).

For a direct Node deployment, run `npm ci --prefix web` and `npm run build --prefix web` from the repository root, then start `node server/src.js` with `HOUSE_SERVER_TOKEN` set to a random token of at least 24 characters. Generate a token with `openssl rand -hex 32`. Keep it out of source control. The default data directory is `server/data`; set `HOUSE_DATA_DIR` to a durable private directory for production. Run one server process per data directory. Back up `house.json` as a secret: it contains the Home Assistant access token as well as the shared plans. The directory and file are created with owner-only permissions. Unreadable or corrupt persisted state stops startup rather than overwriting it.

## Docker setup

Follow the [Docker and Android walkthrough](../docs/linux-android.md) for a first installation. It includes the exact [Compose configuration](../compose.yaml), private `.env` creation, LAN binding, Home Assistant connection and phone setup. Run Compose from the repository root: `build: .` needs the source checkout, not just a copied YAML file.

With `HOUSE_SERVER_TOKEN` set in `.env`, run `docker compose config --quiet` and `docker compose up --build -d`. The Compose deployment runs as the Node user, uses a persistent named volume, drops Linux capabilities and exposes a health check. The Node base image supports Linux amd64 and arm64. Compose binds localhost by default. Set `HOUSE_BIND_ADDRESS` to the Docker host's LAN address for phone access, then run `docker compose up -d` after changing the environment. If using `0.0.0.0`, be aware that it binds every host interface.

For remote access, put a properly configured HTTPS reverse proxy in front, with a trusted certificate and support for the server's event stream, and set `HOUSE_SECURE_COOKIE=true`. Use HTTPS whenever credentials traverse an untrusted network; do not expose plain HTTP port 8080 to the internet. The server must be able to reach Home Assistant; `localhost` inside its container is the container itself. Connect using the Home Assistant host's LAN address.

The named volume contains `/data/house.json`, including the Home Assistant token. `docker compose stop` and `docker compose down` retain it; `docker compose down -v` removes it. Keep a private backup of the volume before updates or moving hosts. A floor-plan JSON export is useful but does not include the server's Home Assistant credentials. Run one server per data directory/volume and retain the same Compose project name when restarting an existing deployment.

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
