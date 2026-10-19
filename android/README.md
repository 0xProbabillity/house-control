# House Control for Android

This is an installable native Android app (Android 8/API 26 or newer). It displays the Linux server’s shared web UI in a restricted WebView. The server provides floor plans, the editor, authentication and Home Assistant controls. The app does not bundle or run the server.

## Get the APK

You need an Android 8 or newer phone or tablet, a running House Control server, and an APK to install. This branch provides a development APK through source builds and CI; it does not provide a published Play Store release.

To use CI, open this repository's **Actions → Mobile**, choose a successful run for the branch/commit you want, and download **HouseControl-Android-debug** from its artifacts. Unzip the download to get `app-debug.apk`. Artifacts are retained for seven days, so an older run may no longer have a download. If no suitable artifact is available, build from source below. Only install an APK from a source and commit you trust.

### Build from source

Install JDK 17 and Android SDK platform 35 (Android Studio can install them), set `JAVA_HOME` and `ANDROID_HOME`, then:

```sh
cd android
./test.sh
./gradlew --no-daemon assembleDebug lintDebug
```

Run these commands from the repository's `android` directory as shown. The resulting APK is `android/app/build/outputs/apk/debug/app-debug.apk` relative to the repository root. Copy it to your phone and follow the installation steps below.

The Gradle 8.9 wrapper and distribution checksum are committed. Gradle downloads Android Gradle Plugin 8.7.3 and required dependencies. No globally installed Gradle is needed. `local.properties` can instead specify `sdk.dir=/path/to/android-sdk`. Build products, SDKs and task-local tooling are ignored.

The [Mobile workflow](../.github/workflows/mobile.yml) runs the same policy checks, APK build and lint using JDK 17. This debug build uses the SDK development signing key; public distribution needs your own release signing configuration and stable signing key. Builds made on different machines or CI runners can have different debug signing keys, so they may not install as updates over each other.

## Install on your phone

1. Download or copy `app-debug.apk` to your phone, then open it from your browser's downloads or the phone's file manager.
2. If Android asks, allow that specific browser or file manager to install apps, return to the APK and tap **Install**.
3. After installation, turn that installation permission off again and open **House Control**.

On Samsung Galaxy, open **Settings**, search for **Install unknown apps**, and allow the app opening the APK, such as your browser or **My Files**. Menu names vary by model and One UI version; [Samsung's instructions](https://www.samsung.com/us/support/troubleshoot/TSG10001913/) explain the per-app permission. If **Auto Blocker** specifically prevents the installation, temporarily turn it off at **Settings → Security and privacy → Auto Blocker**, install the trusted APK, then re-enable it. See [Samsung's Auto Blocker guide](https://www.samsung.com/uk/support/mobile-devices/protect-your-galaxy-device-with-the-new-auto-blocker-feature/).

For developers, an alternative is to enable USB debugging, connect and authorize your phone, then run this from `android` with Android SDK Platform Tools available:

```sh
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

## Connect

1. Start the [Linux/Docker server](../docs/linux-android.md) and connect your phone to a network that can reach it. For a LAN setup, expose the server to the LAN as described in the server guide; Compose's default localhost binding cannot be reached by a physical phone.
2. In your phone's browser, open the server address, for example `http://192.168.1.20:8080`, to check it is reachable.
3. Open House Control and enter the same origin. Use only the scheme, hostname/IP and port, with no page path.
4. Sign in with the **House Control server token** (`HOUSE_SERVER_TOKEN`) that you configured when starting the server.
5. If Home Assistant is not already configured on this server, open **Server connection settings → Home Assistant** to enter its address and its separate **long-lived access token**. Otherwise the existing connection and saved home are already shared with the phone.

These are two different tokens: `HOUSE_SERVER_TOKEN` opens House Control; the Home Assistant token lets the server talk to Home Assistant. Do not put either token in the server address.

On a physical phone, `localhost` means the phone itself: use the server computer's LAN address. In the Android Emulator, `http://10.0.2.2:8080` reaches the development computer's loopback interface ([Android emulator networking](https://developer.android.com/studio/run/emulator-networking-address)); this needs a server port published on loopback. If you bound Compose only to the host's LAN address, use that address instead. For a server on another computer, also use its reachable LAN address. If the browser cannot reach it either, check the server, published Docker port, firewall and Wi-Fi isolation before retrying the app.

Only HTTPS origins or HTTP on private IPs, localhost and `.local` names are accepted. Enter no paths, passwords or token query parameters. HTTP sends your login and session unencrypted on that network. Self-signed/untrusted HTTPS certificates are rejected.

The server address persists. The authenticated session uses the WebView cookie store. Changing server clears cookies, cache and web storage before opening the new origin. Use the native **Change server** button, or the matching server Settings link.

Only the selected origin can load inside the WebView. Other HTTP/HTTPS navigation opens the browser following a user gesture; file/content access, third-party cookies, pop-ups, geolocation, mixed content and arbitrary native JavaScript interfaces are disabled. The app keeps normal Android Back navigation and exposes retry after navigation errors.

## Plans and files

The editor works on the same server plan used by desktop and iPhone server sync. Saving a stale draft shows a conflict; export the draft or reload the server version before retrying. Import uses Android’s document picker for JSON files. Export (including conflict draft recovery) uses Android’s create-document picker. Exports are JSON only and limited to 4 MiB; the app has no broad storage permission.

The app requires the server to render/control devices; it has no offline floor-plan editor. A failed request keeps the editor draft in the current page. Do not reload/change server before exporting work you need to retain.

`./test.sh` checks URL and navigation security policy. `assembleDebug lintDebug` validates the native APK. Real-device permission, connectivity and Android OEM WebView differences require device testing; an unsigned iOS simulator build does not validate signing or real iPhone hardware.
