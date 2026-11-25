# Awake: project brief

Awake (`local.suite.awake`, `LSUIElement`) keeps the Mac awake, an app of Love Suite: until stopped, for a
while (15 min, 30 min, 1 h, 2 h, 5 h by default) or until a time, optionally with the lid closed and
without an external display ("Lid Closed", French "Capot fermé") or with the screen off after a short idle
time while the Mac stays awake ("Screen Off, Mac On", "Écran éteint, Mac allumé"). Off by default:
installed, it changes nothing; opening Awake.app turns it on (`isEnabled`), and nothing keeps the Mac
awake until the user starts a session. Its settings live in its own defaults and are exposed as the
`AwakeSettings` library for a future Awake tab in Suite Settings.

## Architecture

```
AwakeSettings (library, no UI, the only product other repositories see)
    AwakeSettings: the settings in `local.suite.awake` and the status Awake reports (Status* keys);
    AwakeMessage: the distributed notifications (`local.suite.awake.toggle`, start, stop,
    settingsDidChange, setOpensAtLogin, stateDidChange)
AwakeCore     (library, no UI, unit-tested, used by Awake only)
    SessionLength (until stopped, minutes, until a time; the "Until" times), EndReason,
    PowerConditions, SafetyPolicy (battery, Low Power Mode, heat), ClosedLidPolicy, ScreenOffRule,
    AwakeEngine (sessions, the assertion level, lid sleep off and on, screen off) over the protocols
    PowerAssertions, LidSleepControl, DisplaySleeper, which tests fake
Awake         (Awake.app) IOKit assertions (`IOKitAssertions`), lid sleep (`ClamshellLid`, through
              `ClamshellSleepManager` from suite-guard's `ClamshellGuard`), `pmset displaysleepnow`,
              power, battery, heat, lid and idle readings (`MacReadings`, `PowerSourceObserver`), the menu
              bar icon (`StatusMenu`), the login item, `SuiteUpdater`
```

## What Awake does today

- A session holds one IOKit power assertion named "Awake" (`pmset -g assertions`, Activity Monitor ›
  Energy): `PreventUserIdleDisplaySleep`, or `PreventUserIdleSystemSleep` when "Screen Off, Mac On" is on
  or the lid is closed. A timed session also gives powerd a timeout (the remaining time plus a minute), so
  it ends even if Awake's timer doesn't fire. Assertions die with the process: nothing to restore.
- Sessions never resume: none is saved, and at launch lid sleep is put back if a previous Awake left it off.
- Ending for safety, checked on power-source, Low Power Mode, thermal and wake events and every 5 seconds
  during a session: on battery below `stopsBelowBattery` (20 %), Low Power Mode, thermal state serious or
  critical. The menu says why the last session stopped, and a notification tells it (`notifiesSafetyStops`, on;
  macOS asks permission at the first session): `AwakeEngine.onSafetyStop`, for the session or only its
  closed-lid part (heat, Low Power Mode, battery, the closed-lid time limit; never the user's own stop).
- "Screen Off, Mac On" (`screenOffMinutes`: 0 off, 1, 2, 5, 10): only the system assertion is held, and once
  the idle time (`CGEventSource.secondsSinceLastEventType`, no permission) reaches the delay, Awake runs
  `/usr/bin/pmset displaysleepnow` (documented in pmset(1); an action, not a setting, so no root), once
  until the next input.
- "Lid Closed" (`allowsClosedLid`, off, and off again at each launch of Awake, as the user asked):
  during a session closing the lid doesn't sleep the Mac. It uses
  `IOPMrootDomain`'s user client, selector `kPMSetClamshellSleepState` (12) from the public SDK header
  `IOKit/pwr_mgt/IOPMLibDefs.h`, whose behaviour is **undocumented** (xnu: no entitlement, no root; it
  outlives the process). Rules (`ClosedLidPolicy`): on power only by default (`closedLidRequiresPower`;
  else down to `closedLidBatteryFloor`, 30 %), never hot or in Low Power Mode (ends it), at most
  `closedLidMaxHours` (4) per session, counted from when it was first applied; unplugged, it waits and comes
  back when plugged in again. It is set again at every update (power changes re-arm it: powerd turns lid
  sleep back on, notably on Apple Silicon), and the screens are put to sleep when the lid closes
  (`closedLidSleepsDisplay`). The option shows only on a Mac with a lid (`AppleClamshellState`).
  Fail-safe: before turning lid sleep off, `ClamshellSleepManager` notes `ClamshellSleepDisabledByAwake`
  in Awake's defaults and Awake calls `GuardAgent.update()`; should Awake vanish, Suite Guard turns lid
  sleep back on after 15 seconds. Not checked on a real lid yet (see below); a root helper running
  `pmset -a disablesleep` (plan's "Power Protect" equivalent) is not built yet: wanted later by the user
  (2026-11-25), should powerd turn lid sleep back on faster than Awake turns it off.
- The menu bar icon (`cup.and.saucer`, filled `cup.and.heat.waves` during a session) is always there while
  Awake runs. A click starts a session of `defaultDuration` (0, until stopped); during a session a click
  opens the menu; a right-click, Control-click or Option-click always does. The menu: the time left (counting
  down while open), Stop or Keep Awake, Duration (Until Stopped, the `durations`, Until › the next half
  hours), Options (Lid Closed, Screen Off, Mac On, Open at Login), Quit Awake.
- `--if-enabled`: started by another app, Awake quits at once unless it is on. `settingsDidChange` with
  `isEnabled` off quits it.

## Work to do

- The root helper for "Lid Closed" (see above), through `SMAppService.daemon`, resetting itself at its own
  launch and when Awake disconnects. Check first that launchd accepts it with the suite's self-signed
  certificate (Suite Guard's agent had to leave SMAppService for that reason).
- An Awake tab in Suite Settings (`AwakeSettings`, `AwakeMessage`).
- Check "Lid Closed" on a real lid, on power and on battery, plugging in and out.

## Control Center

The wish was a Control Center button (macOS 26 WidgetKit control, `ControlWidgetToggle`, in a widget
extension inside Awake.app). A spike on 2026-11-25 (macOS 27.2.1, Swift 6.4.2, SDK 27.2) settled that it
can't work with the suite's signing:

- Building it without Xcode works: an executable target with an `@main` `WidgetBundle` (WidgetKit provides
  `main`), compiled with `-application-extension`, put in `Contents/PlugIns/<Name>.appex` with
  `CFBundlePackageType` `XPC!` and `NSExtension` › `NSExtensionPointIdentifier` `com.apple.widgetkit-extension`,
  signed with `com.apple.security.app-sandbox`. pkd registers it (`pluginkit -m`), chronod sees it.
- chronod then drops it: "Requested to add extension, but purging instead because we shouldn't cache it
  ... isApple? false", and never launches it, so it never appears in Control Center's Edit Controls. The
  same with ad-hoc signing, outside a temporary folder, in `~/Applications`, elected with `pluginkit -e use`,
  after launching the app once.
- Control: Stats.app's widget extension (Xcode-built, Developer ID, team id) is accepted by the same
  chronod; the same bundle re-signed with "Suite Local Signing" (no team id) is purged the same way. The
  signature is the cause: the suite's certificates are self-signed ("Suite Release Signing" too), so the
  bundles have no team id. The exact rule is chronod's (undocumented); the evidence points at a signature
  without an Apple-issued team id.

So Awake's menu bar icon stays present (the fallback) instead of appearing only during a session. With an
Apple-issued certificate (Developer ID, or an Apple Development certificate with a team id), the control
would be worth building: the extension's toggle would reach the app through a Darwin notification
(`notify_post`) and its state through `notify_get_state` (no app group, which needs a team id), both
unverified from a sandboxed extension; App Intents metadata (`appintentsmetadataprocessor`, Xcode's
toolchain) may also be needed for the toggle's intent to run.

## Building and running

- `swift build` and `swift test` for development. Tests never hold real assertions nor touch lid sleep or
  power settings: `AwakeEngine` takes fakes. Never turn on the lid-closed mode on the developer's Mac
  without being asked; a short run of `build/Awake.app` to see the assertion in `pmset -g assertions` is fine.
- Until suite-guard has a tag with `ClamshellGuard` (after v27.1-dev.1), build with
  `swift package edit suite-guard --path ../suite-guard` (never committed), `swift package unedit` after.
- `scripts/make-app.sh` builds `build/Awake.app` (release), signs it with the "Suite Local Signing"
  certificate from the login keychain, so macOS permissions survive rebuilds (ad-hoc signing, the
  fallback, re-asks every build), and installs it as `~/Applications/Awake.app`, the only copy Launch
  Services knows. It records the branch and commit in the Info.plist (`SuiteBuildBranch`,
  `SuiteBuildCommit`) and refuses to replace an installed copy built from another branch, or from an unknown
  one, unless `--force`: another session may be testing it. `INSTALL_DIR=` builds without installing. A
  running copy is relaunched from the new one.
- Never ask the user to open `build/Awake.app` from a worktree.
- UI can't be checked by unit tests and screenshots of the user's screen are not available: check UI by
  rendering views offscreen (`cacheDisplay`) from a scratch package that compiles the sources.
- Releases: change `VERSION` (only `Z` is this repository's own), commit, push, then `scripts/publish.sh`
  pushes the tag; `.github/workflows/release.yml` builds, signs the app with "Suite Release Signing",
  signs `update.json` with the update key (both from the repository's `release` environment secrets),
  publishes the release and updates the cask in `love-suite/homebrew-tap`. The feed is
  `https://github.com/love-suite/suite-awake/releases/latest/download/update.json`
  (the GitHub repository it is built from). A change of `AA.Y` comes from the suite repository through
  `.github/workflows/sync-version.yml`. Until `Support/release-certificate.cer` and
  `Support/update-public-key.txt` exist, nothing can be released.

## The suite

This repository is part of Love Suite, one repository per app under `github.com/love-suite`:
`suite-core` (the shared library), `suite-files` (the file layer of the apps handling files),
`suite-guard`, `suite-desktop` (the desktop), `suite-explorer`, `suite-bar` (the Dock), `suite-viewer`,
`suite-clipboard`, `suite-awake`, `suite-settings` (the settings), `suite-launcher`, `suite-bindings`,
`suite-ai-organizer`; `homebrew-tap` (the tap `love-suite/tap`, one cask per app) and `suite` (the
front page, the suite's version, the scripts that act on every repository). Locally they sit side by side
in `~/GitHub/paul-amour/suite/`.

## Conventions (the same in every repository of the suite)

- The user writes in French and expects answers in French; everything in the code stays in English: code,
  comments, tests, docs, commit messages. Do not add co-author trailers.
- No "…" in menu items, buttons or messages: the user wants none, anywhere.
- Behaviour follows Windows unless Apple's design is asked for.
- Swift Package Manager, `swift-tools-version:5.9`, macOS 13+. Tests use Swift Testing (`import Testing`).
- Toolchain: swiftly, Swift 6.4.2 (`.swift-version`, git-ignored). If `swift test` complains about a
  missing toolchain: `swiftly use 6.4.2`.
- AppKit for windows that need fine control; SwiftUI is allowed for small panels (settings, pickers).
- No private APIs and no system modifications (SIP stays on).
- Git: one worktree per feature under `.worktrees/` (git-ignored), one branch per change
  (`feat/<feature>`, `fix/<area>/<what>`), merged into `main` one by one; `main` stays stable.
- Versions are `AA.Y`, then `AA.Y.Z` for a fix (`VERSION`, tag `vVERSION`: 27.1, then 27.1.1; SwiftPM reads
  `v27.1` as 27.1.0): `AA` is the latest macOS in production (27), `AA.Y` is the same in every repository of
  the suite so the apps work together, `Z` is this repository's own. A change of `AA.Y` is made in `suite`
  and reaches every repository. While a version is being prepared, `VERSION` doesn't move (27.1 now):
  development builds are `VERSION-dev.N`, N the commits since `VERSION` was set, merges aside, from 1 (`make-app.sh`),
  and a change another repository needs gets a development tag, `vVERSION-dev.N`, which releases nothing.
  Dependencies on other repositories of the suite (`suite-core`, `suite-files`, `suite-guard`, settings
  libraries) use
  `.upToNextMinor(from: "27.1.0-dev.1")` (the latest development tag, then the release);
  `Package.resolved` is committed. Tags are never moved once pushed. The build number (`CFBundleVersion`,
  which the updater compares) stays the number of commits.
- Changing two repositories at once: `swift package edit <Package> --path ../<repository>` points at the
  neighbour's working copy until its tag exists, `swift package unedit` goes back. Never committed.
- What two apps need lives in `suite-core` (file code in `suite-files`); an app's own code never goes into another app's repository, and
  an app exposes only its settings, as `<App>Settings`, for Suite Settings.
- Do not run commands that delete user data. Trash instead of delete.
- No code converting saved settings at launch. Before the first release nothing needs converting (the
  developer's own settings don't count): rename freely. Between released versions, a change to saved
  settings is a `SettingsMigration` (suite-core) for the version that brought it, given to the app's
  `SuiteUpdater`, which runs it once after the update.
