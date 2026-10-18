# Linux server and Android

The Linux service hosts the existing Three.js renderer and floor-plan editor. A desktop browser or Android client loads the service directly; the server stores the selected plan and Home Assistant connection. Existing standalone Mac/iPhone integrations remain available in their Apple apps.

## Start the service

Follow [server/README.md](../server/README.md) for Docker Compose, token configuration, the persistent data volume, secure remote access, and backup/restore. Open the service origin in a browser and sign in using `HOUSE_SERVER_TOKEN`. The browser receives an HttpOnly session cookie; it does not save the server token in local storage.

For Android, follow [android/README.md](../android/README.md) to build the app. Enter the service URL and sign in. Android loads the same responsive home and editor; **Server connection settings → Change server** opens the Android URL settings. An Android APK is not published by this source change.

## Connect and build a shared home

1. Open **Server connection settings → Home Assistant**.
2. Enter the address and a Home Assistant long-lived access token. The credentials stay in the server's private data file, so protect its data volume and backups.
3. Open **Edit home**, pick a lamp or AC, then choose a catalog device under **Real device**. Temperature sensors can be linked separately to ACs.
4. Press **Save & apply** on desktop or **Save** on mobile. Other connected clients adopt the shared plan.

Home Assistant lights, switches, climate entities and temperature sensors are supported. Smart Life, Hue, Apple Home, Matter and other brands must be exposed through Home Assistant for this server. Only the Apple standalone apps offer their original direct providers.

Unlinked plan items remain simulated. Linked items always use the server's real-device command path. Rejected commands roll back the optimistic UI change and show an error. An interrupted stream marks linked devices offline until a fresh state arrives. The connection button reports reconnection or Home Assistant availability; offline tile labels identify last-known readings.

## Plans, imports, and conflicts

Use **Import…** and **Export…** in the desktop editor. On mobile open **Home → Shared home** for **Import plan…** and **Export plan…**. Import validates the JSON and creates a draft; it becomes shared only after saving. Exports download JSON in the browser or Android's download flow.

Each save includes the revision loaded by that editor. If another client saves first, the server refuses the stale save. The editor retains your draft and offers **Export my draft**, **Load latest home**, and **Keep editing**. Export before loading the latest plan if you need to preserve your changes. There is no automatic merge or force-overwrite operation. Leaving a dirty editor asks about unsaved changes where the browser supports that prompt.

The settings screen also selects bundled demo plans or the saved custom home. Plan selection is shared across clients. A disconnected client refreshes both the state and revision when its event stream reconnects.

## iPhone shared-plan sync

In the iPhone app open **Settings → Shared server**, enter the HTTPS or private-network HTTP origin and the server access token, then choose **Connect and sync**. The token is stored in Keychain. Server mode pauses the existing Mac sync; **Use Mac / local mode** resumes it.

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
