# House Control for Android

This is an installable native Android app (Android 8/API 26 or newer). It displays the Linux server’s shared web UI in a restricted WebView. The server provides floor plans, the editor, authentication and Home Assistant controls. The app does not bundle or run the server.

## Build and install

Install JDK 17 and Android SDK platform 35 (Android Studio can install them), set `JAVA_HOME` and `ANDROID_HOME`, then:

```sh
cd android
./test.sh
./gradlew --no-daemon assembleDebug lintDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

The Gradle 8.9 wrapper and distribution checksum are committed. Gradle downloads Android Gradle Plugin 8.7.3 and required dependencies. No globally installed Gradle is needed. `local.properties` can instead specify `sdk.dir=/path/to/android-sdk`. Build products, SDKs and task-local tooling are ignored.

The Mobile GitHub Actions workflow builds this APK and an unsigned iPhone simulator app. Download `HouseControl-Android-debug` from the workflow artifacts to install a development APK. This debug build uses the SDK development signing key; public distribution needs your own release signing configuration and stable signing key.

## Connect

1. Start the [Linux server](../docs/linux-android.md).
2. Open House Control and enter its origin, for example `https://house.example.com` or `http://192.168.1.20:8080`.
3. Sign in with the server access token in the server’s login screen.
4. Open Settings to connect Home Assistant and edit the shared home.

Only HTTPS origins or HTTP on private IPs, localhost and `.local` names are accepted. Enter no paths, passwords or token query parameters. HTTP sends your login and session unencrypted on that network. The emulator reaches a host server at `http://10.0.2.2:8080`; a physical phone needs your server’s LAN address. Self-signed/untrusted HTTPS certificates are rejected.

The server address persists. The authenticated session uses the WebView cookie store. Changing server clears cookies, cache and web storage before opening the new origin. Use the native **Change server** button, or the matching server Settings link.

Only the selected origin can load inside the WebView. Other HTTP/HTTPS navigation opens the browser following a user gesture; file/content access, third-party cookies, pop-ups, geolocation, mixed content and arbitrary native JavaScript interfaces are disabled. The app keeps normal Android Back navigation and exposes retry after navigation errors.

## Plans and files

The editor works on the same server plan used by desktop and iPhone server sync. Saving a stale draft shows a conflict; export the draft or reload the server version before retrying. Import uses Android’s document picker for JSON files. Export (including conflict draft recovery) uses Android’s create-document picker. Exports are JSON only and limited to 4 MiB; the app has no broad storage permission.

The app requires the server to render/control devices; it has no offline floor-plan editor. A failed request keeps the editor draft in the current page. Do not reload/change server before exporting work you need to retain.

`./test.sh` checks URL and navigation security policy. `assembleDebug lintDebug` validates the native APK. Real-device permission, connectivity and Android OEM WebView differences require device testing; an unsigned iOS simulator build does not validate signing or real iPhone hardware.
