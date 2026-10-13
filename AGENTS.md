# Agent notes for this project

## Publish every Android widget release to the user's F-Droid repo

*Requested by the user on 2026-10-13 and left here by the agent working on Steady Timer.*

The user installs and updates their personal Android apps through **Droid-ify**, reading a
self-hosted F-Droid repo at <https://polymertheory.github.io/apps/fdroid/repo>. It is
driven from the sibling project `../61-app_distribution`. **Whenever you ship a new
version of the Android widget (`android/`), also publish it there**, so the update reaches
the user's phone without adb or GitHub. The user has given standing permission for this; no
need to ask each time.

Publishing builds from the `android/` working tree as it stands, so commit the release first.
Then, from `../61-app_distribution`:

```bash
python appctl.py bump usage-widget
```

```bash
python appctl.py publish usage-widget
```

- `bump` raises `versionCode` / `versionName` in `android/app/build.gradle.kts` (patch by
  default; `--part minor` for a minor release). Skip it if you already bumped by hand, but
  the `versionCode` must be higher than the last published one, or Droid-ify won't offer it.
  Commit the bump here.
- `publish` builds the signed release APK, adds it to the repo, regenerates and signs the
  index, and pushes to the public `PolymerTheory/apps` repo. Afterwards the update shows up
  in Droid-ify under *Updates*.
- **Never publish a rebuild under an already-published `versionCode`.** The repo would then
  hold two different files claiming to be the same version.
- Keep signing with `android/release.keystore`. That key is the one registered for Android
  developer verification (see `ANDROID_DEVELOPER_VERIFICATION.md`), and the installed app can
  only be upgraded by APKs signed with it.
- The listing (name, summary, description, icon) comes from `../61-app_distribution/apps.yml`,
  not from this repo. Edit it there.

As of 2026-10-13 the repo serves **0.3.0 (versionCode 3)**.

## Listing icon

The store icon is rendered from the launcher icon itself (`android/app/src/main/res`):

```bash
python ../61-app_distribution/scripts/render_icon.py android/app/src/main/res ../61-app_distribution/icons/usage-widget.png
```

Re-run it after changing the launcher icon, then publish. One thing to know: the four bars
in `ic_launcher_foreground.xml` span x = 24–90 on the 108 dp canvas. That's wider than the
66 dp safe zone and off-centre by 3 dp, so the red bar touches the edge of what the launcher
shows, and circular masks clip it. That's how it looks on the home screen too, so the store
icon matches it faithfully. If you ever tidy the icon, narrowing the bars to about x = 30–78
would centre them inside the safe zone.
