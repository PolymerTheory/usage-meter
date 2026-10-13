# Android developer verification: Usage Widget

*Left on 2026-10-10 by the agent working on Photo Atlas, at the user's request. The user wants
the agent responsible for **this** app to handle it.*

## STATUS (2026-10-11): ✅ **DONE — Registered & Verified**

Registered on Play Console with the package name and SHA-256 below; the fingerprint now shows
**Verified** ("Registered" state). Google's flow accepted the fingerprint directly and **never asked
for the challenge-file / proof-of-key APK upload** (step 3 below) — almost certainly because the
user's identity is already verified via Play Console, so no APK build was needed. Nothing further to
do. Only caveat: keep signing with `release.keystore` (the verified key); a new/different signing key
would need to be added via "Add key", and renaming the package would need a fresh registration.

## This app: **needs registering** (no deadline for the user before 2027)

| | |
|---|---|
| Package | `io.github.polymertheory.usagewidget` |
| Distribution | Public GitHub releases (`PolymerTheory/usage-meter`), installed by tapping the APK |
| On the user's Pixel | Installed via the **Files app**, so it is *not* covered by the adb exemption |
| Release key | `android/release.keystore` (password in `android/keystore.properties` and the user's LastPass) |
| SHA-256 | `5D:D1:AD:44:8E:D1:1C:6F:86:B5:36:A4:2C:50:CA:F7:64:6B:0D:B0:5D:B7:68:77:DD:8E:C5:B3:7D:6C:66:4A` |

Anyone installing the GitHub release in an enforcing country is already affected, and the user
will be from 2027. **Register the package with the release key above.**

✅ **Package name decided (2026-10-11): keep `io.github.polymertheory.usagewidget`.** The user chose
to keep the current name rather than rename to a `com.tueftlerapps.*` one — no code change, no
reinstall. Register this name with the SHA-256 above. (Verified 2026-10-11: `applicationId`/`namespace`
in `android/app/build.gradle.kts` and the release-key SHA-256 both match this note.)

## Background (same for every app)

- **What changed:** Android now only installs apps that are **registered to a verified developer**.
  Registration means the package name plus the SHA-256 fingerprint of the signing key. It has been
  enforced on certified devices in Brazil, Indonesia, Singapore and Thailand since **30 Sep 2026**,
  and goes **worldwide from 2027**. The user is in Germany, so nothing is blocked for them yet.
- **Exempt:** installing with `adb install` from the Mac (the usual agent workflow), and anything
  installed from Google Play (Play registers its apps automatically).
- **Not exempt:** installing a downloaded APK on the phone itself (Files app, browser, Dropbox,
  GitHub release). Without registration, users on enforcing devices have to use Android's
  "advanced flow" (Developer options → allow unverified apps → restart → 24-hour wait).

## Account status: nothing to do here

- The user's **identity is already verified** through their Play Console developer account
  ("tueftlerapps"). There's no separate Android Developer Console account, ID upload or fee.
- Already registered: Panels (3 package names) and Photo Atlas.

## How to register an app (about 5 minutes)

**Ask the user before submitting.** Registration is a form submitted on their developer account.

Play Console → **Android developer verification** →
<https://play.google.com/console/u/0/developers/7004964770639944415/android-developer-verification>

1. **Register package name**: enter the package name and a friendly name.
2. Enter the signing key's **SHA-256 certificate fingerprint** (given below for this app).
3. **Prove you hold the key:** the Console gives you a challenge file. Put it in
   `app/src/main/assets/` under exactly the name it gives, build a **release APK signed with this
   app's key**, and upload it. Then **delete the challenge file**; it must not ship.
4. The key shows as **Verified**. Repeat steps 2–3 for any other key you sign APKs with that people
   install directly (for example a debug key, if debug APKs are ever handed out).

No code changes are needed, apart from that temporary asset.

Sources: [Google: register on the Android Developer Console](https://developer.android.com/developer-verification/guides/android-developer-console),
[Play Console guide (PDF)](https://developer.android.com/developer-verification/guides/pdf-guides/pdc-guide.pdf),
[Android Authority: first-wave rollout](https://www.androidauthority.com/android-sideloading-developer-verification-first-wave-rollout-3717921/),
[Gadget Hacks: 2026 changes, ADB exemption](https://android.gadgethacks.com/news/google-android-sideloading-rules-2026-changes-explained/).
Google's pages are the authority; dates and countries have shifted before, so re-check before acting.
