# UsageMeter Android widget

A home-screen **widget** for Android that shows your Claude & Codex quota at a
glance — the same four-bar glyph as the macOS menu-bar app, on your phone.

<!-- Placeholder: add a screenshot once you've placed it on a home screen. -->

## How it works

It's a thin, read-only companion to the macOS [UsageMeter](../) app. It does **not**
talk to Anthropic/OpenAI and has no credentials of its own. Instead it reads the
same small JSON blob your Mac publishes when you enable **Sync** (see
[`../docs/sync.md`](../docs/sync.md)) — usage percentages and reset times only,
never tokens. So:

- **Prerequisite:** turn on Sync in the Mac app first. The widget is a fourth
  consumer of that endpoint, alongside your other Macs and the phone web view.
- The widget is only as fresh as what a running Mac last published (same caveat
  as the phone view). Keep at least one Mac with sync enabled awake.
- The synced blob carries quota only — **not** the live "active" activity dots —
  so the widget shows the four quota bars but no processing dots.

## The four bars

Same as the Mac menu bar, left to right: **Codex 5h · Codex 7d · Claude 5h ·
Claude 7d**. Colours match the Mac / phone view: green `< 55%`, yellow `< 80%`,
red `≥ 80%`, grey when a window is unavailable.

**Two styles**, switched with the **Compact icon style** toggle in the app:

- **Detailed card** (default): full rounded card with a percentage above each
  bar, the window label below, and — when tall enough — an "updated Xm ago" line.
- **Compact icon**: an app-icon–sized dark squircle of live bars with an
  "AI Usage" label, transparent elsewhere, so it lines up with the icons on your
  home screen instead of filling the whole cell.

Other behaviour:

- The widget is resizable both directions; the detailed card also thins to
  bars-only at very small sizes.
- **Tap:** opens the app, which shows a detailed usage screen — one card per
  provider with a horizontal bar per window, percentage, reset countdown (e.g.
  "resets 9:05 (2h 15m)"), and a last-updated footer — laid out like the Mac
  app's usage panel. Refreshes on open, regardless of the widget's own style.
- Background refresh runs every 15 min (WorkManager's minimum) when a network is
  available, plus a ~30 min system-update backstop.

## Setup (on the phone)

1. Install the APK (see below) and open **Usage Widget**.
2. Tap **Scan QR from UsageMeter** and point the phone at the QR code in the Mac
   app's sync (📡) panel. That's the whole configuration — the URL and token are
   read from the QR's link fragment, exactly like the phone web view.
   - No QR handy? Paste the sync URL + token (or the whole `…#u=…&t=…` link)
     into the manual fields instead.
3. Tap **Test connection** → **✓ Connected**, then **Save**.
4. Long-press your home screen → **Widgets** → **Usage Widget** → drag "AI Usage"
   onto a home screen. Resize it by long-pressing and dragging the handles.

## Build

Requires JDK 17 and the Android SDK (platform `android-35`, build-tools
`35.0.0`). The Gradle wrapper is pinned (Gradle 8.11.1 / AGP 8.7.3).

```sh
cd android
# Point Gradle at your SDK if ANDROID_HOME isn't set:
echo "sdk.dir=$HOME/Library/Android/sdk" > local.properties

./gradlew assembleDebug         # -> app/build/outputs/apk/debug/app-debug.apk
./gradlew testDebugUnitTest      # data-path unit tests (parsing, QR link, colours)
```

The debug APK is signed with the standard Android debug key, which installs fine
for personal use and for anyone sideloading it.

### Release build (signed)

Release signing is optional and driven by a **gitignored** `keystore.properties`
in `android/`. Without it, `assembleRelease` still builds but stays unsigned — so
cloning and building the repo never requires a key.

To produce a signed release APK, create a keystore and point the properties file
at it:

```sh
cd android
keytool -genkeypair -v -keystore release.keystore -alias usagewidget \
  -keyalg RSA -keysize 2048 -validity 10000

cat > keystore.properties <<'EOF'
storeFile=release.keystore
storePassword=YOUR_STORE_PASSWORD
keyAlias=usagewidget
keyPassword=YOUR_KEY_PASSWORD
EOF

./gradlew assembleRelease        # -> app/build/outputs/apk/release/app-release.apk
```

`release.keystore`, `keystore.properties`, and all `*.apk` are gitignored — keep
the keystore and its password backed up somewhere safe; you need the **same** key
to ship updates users can install over an existing copy. A release-signed APK
cannot be installed over a debug-signed one (different signature) — uninstall the
debug build first.

## Install on your phone

**Via Dropbox (no cable):** the built APK is copied to
`UsageWidget-debug.apk` in this folder, which is inside your Dropbox — open the
Dropbox app on the phone, tap it, and allow "install unknown apps" for Dropbox
when prompted.

**Via USB:** `adb install -r app/build/outputs/apk/debug/app-debug.apk`.

## Layout

```
android/
  app/src/main/
    java/io/github/polymertheory/usagewidget/
      UsageWidgetProvider.kt   # AppWidgetProvider: sizing, RemoteViews, tap intent
      WidgetRenderer.kt        # Canvas → bitmap; the four-bar drawing (widget only)
      UsageDetailRenderer.kt   # Binds Usage into the in-app provider cards
      TimeFormat.kt            # Shared "updated Xm ago" / "resets …" formatting
      UsageRepository.kt       # GET the sync endpoint + disk cache
      model/UsageModels.kt     # SharedUsage blob parsing
      config/ConfigActivity.kt # setup screen (QR scan + manual) + detail view
      config/ConfigStore.kt    # prefs + QR pairing-link parsing
      work/RefreshWorker.kt     # WorkManager periodic + one-shot refresh
    res/layout/view_provider_card.xml     # one provider's card (header/rows/footer)
    res/layout/view_usage_window_row.xml  # one window's bar + percent + reset row
    res/xml/usage_widget_info.xml  # widget metadata (resizable, sizes)
  app/src/test/...              # off-device data-path tests
```
