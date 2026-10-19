# Set up House Control with Docker and Android

This guide takes you from a source checkout to a shared floor plan on your Android phone, connected to Home Assistant. The Docker service hosts the existing 3D home and editor, stores your plan, and sends commands to Home Assistant. The Android app connects to that service. Existing standalone Mac/iPhone integrations remain available in their Apple apps.

```text
Android app / browser → House Control in Docker → Home Assistant → devices
                                  │
                          saved shared home
```

## 1. Choose a host and install Docker

The Docker service needs an always-on Linux computer, virtual machine, NAS with Docker support, or similar host reachable by your phones and Home Assistant. A [normal Linux Docker host](https://www.home-assistant.io/installation/linux/) can run House Control alongside Home Assistant Container with separate persistent volumes.

Home Assistant OS is an appliance managed by Supervisor; installing this project's Docker Compose service alongside it is not a supported normal hosting path. Use a separate Docker host, or a VM beside the Home Assistant OS VM. A packaged [Home Assistant app (formerly add-on)](https://developers.home-assistant.io/docs/apps) would be another option, but this project does not implement one.

A laptop running Docker can be used for a trial. The phone loses access when that laptop sleeps, stops Docker or leaves the network.

Install Docker Engine and the Compose plugin on Linux, or Docker Desktop on a supported desktop system, following [Docker's installation guide](https://docs.docker.com/compose/install/). You also need Git and OpenSSL for the commands below. Check that Docker is running:

```sh
docker version
docker compose version
```

The Docker build installs its own Node dependencies and builds the web interface. You do not need Node or an Android SDK on the server to run it.

## 2. Get the source

```sh
git clone https://github.com/0xProbabillity/house-control.git
cd house-control
```

While [PR #12](https://github.com/0xProbabillity/house-control/pull/12) is unmerged, also check out its code in this fresh clone:

```sh
git fetch origin pull/12/head
git switch --detach FETCH_HEAD
```

Run the following Docker commands from this directory, which contains `Dockerfile` and `compose.yaml`. This deployment builds from source; there is no published production container image to pull.

## 3. Create your server login and choose a LAN address

Create a private `.env` file beside `compose.yaml`. This command generates a random token and refuses to overwrite an existing file:

```sh
(
  umask 077
  set -C
  printf 'HOUSE_SERVER_TOKEN=%s\nHOUSE_BIND_ADDRESS=127.0.0.1\nHOUSE_SECURE_COOKIE=false\n' "$(openssl rand -hex 32)" > .env
)
```

Open `.env` in your editor. Keep the generated `HOUSE_SERVER_TOKEN`; this is the value you will paste into **Server access token** when signing in to House Control. The file is excluded from Git and the Docker build context.

For a phone on your home network, change `HOUSE_BIND_ADDRESS=127.0.0.1` to the Docker host's LAN IPv4 address. Find it in the host's network settings or your router's device list. For example, if the host is `192.168.1.20`, use `HOUSE_BIND_ADDRESS=192.168.1.20`. All addresses in this guide are examples—substitute your own. A router DHCP reservation can keep that address stable.

`127.0.0.1` allows access only from the host itself. Binding to the host's LAN address lets other devices on that network reach it. For this initial HTTP LAN setup, leave `HOUSE_SECURE_COOKIE=false`. HTTP carries the login/session unencrypted; use a trusted home network. For HTTPS access, see [server deployment](../server/README.md). Do not forward port 8080 directly to the internet.

## 4. Start Docker Compose

The repository already includes this working [compose.yaml](../compose.yaml). You do not need to create another one; this is the copyable example if you want to inspect or adapt it:

```yaml
services:
  house-control:
    build: .
    restart: unless-stopped
    ports:
      - "${HOUSE_BIND_ADDRESS:-127.0.0.1}:8080:8080"
    environment:
      HOUSE_SERVER_TOKEN: ${HOUSE_SERVER_TOKEN:?Set a random server token of at least 24 characters}
      HOUSE_SECURE_COOKIE: ${HOUSE_SECURE_COOKIE:-false}
    volumes:
      - house-data:/data
    read_only: true
    tmpfs:
      - /tmp
    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true
volumes:
  house-data:
```

`build: .` needs the full source checkout alongside the Compose file. The image runs as a non-root user and supplies a health check. The named volume stores the shared home and Home Assistant connection.

Compose reads the [.env values](https://docs.docker.com/compose/how-tos/environment-variables/variable-interpolation/) automatically. If you previously exported any `HOUSE_*` variables in this shell, unset those exports first: shell values take precedence over `.env`.

```sh
docker compose config --quiet
docker compose up --build -d
docker compose ps
```

The first build downloads dependencies. Wait for `house-control` to report healthy. `config --quiet` validates without displaying the resolved token.

Open `http://192.168.1.20:8080` in a browser, replacing the example IP with your server's LAN address. Sign in using the generated `HOUSE_SERVER_TOKEN`. You should see the demo floor plan. A read-only health check is also available at `http://192.168.1.20:8080/healthz`.

## 5. Connect Home Assistant and link one device

There are two different tokens:

| Token | Where it comes from | Where to use it |
| --- | --- | --- |
| House Control server token | `HOUSE_SERVER_TOKEN` in your server's `.env` | House Control's **Server access token** login, in each browser/app |
| Home Assistant long-lived access token | Your Home Assistant profile | House Control's **Home Assistant** connection form, once per server |

1. Sign in to Home Assistant and open **your profile → Security → Long-lived access tokens**. Create a token named something like `House Control`. See [Home Assistant's account security instructions](https://www.home-assistant.io/docs/authentication/#managing-account-access).
2. In House Control, open **Server connection settings → Home Assistant**.
3. Enter your Home Assistant URL, for example `http://192.168.1.30:8123`, and paste the Home Assistant token. Click **Connect**. The address must be reachable from inside the Docker container; `localhost` there refers to the container, not your Home Assistant host.
4. Open **Edit home**, pick one lamp or AC, and choose a discovered device under **Real device**. Temperature sensors can be linked separately to ACs.
5. Press **Save & apply** on desktop or **Save** on mobile. Return to the panel and try that linked device. This sends a real command to it. Other connected clients adopt the saved plan.

The Home Assistant credentials stay in the server's private data file; protect its volume and backups. Android uses this same server connection and does not need a separate Home Assistant token.

Home Assistant lights, switches, climate entities and temperature sensors are supported. Smart Life, Hue, Apple Home, Matter and other brands must be exposed through Home Assistant for this server. Only the Apple standalone apps offer their original direct providers.

Unlinked plan items remain simulated. Linked items always use the server's real-device command path. Rejected commands roll back the optimistic UI change and show an error. An interrupted stream marks linked devices offline until a fresh state arrives. The connection button reports reconnection or Home Assistant availability; offline tile labels identify last-known readings.

## 6. Install and connect Android

1. Get the development APK from a successful **Mobile** workflow run, or build it locally. The [Android installation guide](../android/README.md) covers both routes, transfer to your phone and Samsung's install permission. Android 8 or newer is required; this is not a Play Store release.
2. Install the APK and connect your phone to the same reachable home network as the server.
3. Open **House Control**. Enter `http://192.168.1.20:8080` with your server's actual LAN IP, then tap **Connect**. Use the server address only, with no page path or token in the URL.
4. Paste the value of `HOUSE_SERVER_TOKEN` into **Server access token**, then tap **Sign in**.
5. Confirm that the shared floor plan loads and try the device you linked in step 5. Changes saved in the desktop editor should appear on the phone too.

| Client | Server address to use |
| --- | --- |
| Physical Android phone | The Docker host's LAN address, e.g. `http://192.168.1.20:8080` |
| Browser on that host | The same LAN address; `http://127.0.0.1:8080` only if you kept a loopback binding |
| Android emulator on the host | `http://10.0.2.2:8080` when the host service is reachable on loopback; otherwise use the configured LAN address |

On a phone, `localhost` and `127.0.0.1` refer to the phone itself. `10.0.2.2` is an Android emulator address, not the address to type on a physical phone. **Server connection settings → Change server** opens the Android URL settings if you need to correct it.

## If something does not connect

| Symptom | What to check |
| --- | --- |
| Phone says connection refused or times out | Confirm Docker is running with `docker compose ps`; check the exact LAN IP and port; make sure `.env` is not still bound to `127.0.0.1`. After changing `.env`, run `docker compose up -d`. The phone must have a network route to that host; guest Wi-Fi isolation or a host firewall may prevent it. |
| Android blocks installation | Follow the [APK permission steps](../android/README.md#install-on-your-phone), including Auto Blocker if Samsung reports that it is blocking the install. |
| Login fails or immediately returns to sign-in | Use the House Control token from `.env`, not the Home Assistant token. Check for whitespace and keep `HOUSE_SECURE_COOKIE=false` when accessing plain HTTP. |
| Home Assistant does not answer | Check the Home Assistant LAN URL and port from the Docker host/container network. Do not use the container's `localhost`. If it reports an authentication failure, check the Home Assistant token. |
| The picture changes but the real light does not | Link that plan item to a **Real device**, save the plan, and confirm Home Assistant is connected. Unlinked items are simulated. |
| It stops when the laptop leaves | Move the Docker service and its data to an always-on home host; the APK does not contain a server. |

For server startup errors, inspect `docker compose logs --tail=100 house-control`. Keep credentials and private configuration out of shared logs/screenshots.

## Stop, restart and keep your saved home

Run these from the same checkout and Compose project:

```sh
docker compose stop
docker compose up -d
```

These retain the `house-data` volume. `docker compose down` also keeps a named volume by default, but **`docker compose down -v` deletes it**. Keep the project name/directory stable so a later start uses the same volume.

Export your floor plan from the editor for a portable copy. Back up the named volume as well to retain the Home Assistant connection; it contains a private token, so treat the backup as a secret. See [server storage details](../server/README.md). After fetching a newer source version, `docker compose up --build -d` rebuilds the service and keeps the volume; clients may need to sign in again.

## Plans, imports, and conflicts

Use **Import…** and **Export…** in the desktop editor. On mobile open **Home → Shared home** for **Import plan…** and **Export plan…**. Import validates the JSON and creates a draft; it becomes shared only after saving. Exports download JSON in the browser or Android's download flow.

Each save includes the revision loaded by that editor. If another client saves first, the server refuses the stale save. The editor retains your draft and offers **Export my draft**, **Load latest home**, and **Keep editing**. Export before loading the latest plan if you need to preserve your changes. There is no automatic merge or force-overwrite operation. Leaving a dirty editor asks about unsaved changes where the browser supports that prompt.

The settings screen also selects bundled demo plans or the saved custom home. Plan selection is shared across clients. A disconnected client refreshes both the state and revision when its event stream reconnects.

## iPhone shared-plan sync

Shared-server sync requires building/installing the iPhone app from this branch, or a future release containing these changes. An existing App Store/TestFlight installation does not gain this feature from deploying the server. In that new build, open **Settings → Shared server**, enter the HTTPS or private-network HTTP origin and the server access token, then choose **Connect and sync**. The token is stored in Keychain. Server mode pauses the existing Mac sync; **Use Mac / local mode** resumes it.

The iPhone syncs on foreground and polls every 15 seconds while active. Local edits/imports sync automatically. Offline errors stay visible and retry on foreground. If both sides changed, choose **Keep iPhone** or **Keep server**; the displaced plan is archived under **Saved alternatives** and can be exported with the share sheet.

This shares plans, not native device credentials. Configure the iPhone's own Home Assistant connection separately to control the Home Assistant entity IDs in its shared plan. The server's browser/Android clients use the server's Home Assistant connection.

## Verification

```sh
npm ci --prefix server
npm test --prefix server
npm ci --prefix web
npm run build --prefix web
cd web
npx playwright install chromium
npm test
```

The browser tests cover sign-in/out and CSRF transport, shared plan saves/reload/live updates, conflicting drafts, catalog linking, failed device rollback, Android settings and responsive layout. A separate browser test runs the real HTTP server and Home Assistant adapter against a local HTTP/WebSocket fake. It does not contact real devices. CI also builds the Docker image and checks persistence through a container restart. Successful local/browser checks do not constitute a real household or installed Android-device test.
