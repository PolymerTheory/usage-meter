# Activity Probe

Small diagnostic app for testing UsageMeter's Codex and Claude activity signals.

It is intentionally separate from the main UsageMeter app. The probe reads status files from:

```text
~/Library/Application Support/UsageMeter/activity/
```

The status files contain only provider, state, event name, and timestamp. They
do not include prompts or transcript content.

## Run the two-dot window

```sh
./experiments/activity_probe/build_and_run_probe_app.sh
```

Green means the latest status file says `busy`; gray means `idle`. Claude uses
recent task/project writes only when no hook status file exists.

For Codex, the probe reads `~/.codex/sqlite/logs_2.sqlite` directly and derives
busy/idle from Codex desktop app-server turn events. The Codex status file is
only a fallback. Codex turns busy immediately, then waits 4 seconds after the
latest completion/failure event before showing idle to avoid brief flicker.

## Manual smoke test

```sh
./experiments/activity_probe/activity-hook.sh codex busy manual-test
./experiments/activity_probe/activity-hook.sh codex idle manual-test
./experiments/activity_probe/activity-hook.sh claude busy manual-test
./experiments/activity_probe/activity-hook.sh claude idle manual-test
```

## Claude hooks

The production UsageMeter app installs Claude lifecycle hooks through the
**Enable Claude activity** button. The hooks call the installed app executable
in a non-GUI mode:

```sh
UsageMeter --activity-hook claude busy UserPromptSubmit
UsageMeter --activity-hook claude idle Stop
```

`activity-hook.sh` remains only for manual status-file smoke tests. Codex does
not use hooks; it derives activity from target-scoped desktop sqlite events.
