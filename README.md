# Mac Dev Monitor

A menu-bar app and dashboard for watching and cleaning up the things that eat a dev Mac's RAM and disk:
bloated system daemons, swap, leftover build processes, stale git worktrees, Xcode DerivedData,
simulators and dev caches.

It exists because "Claude/Xcode keeps running out of memory" turned out to be `fseventsd` at 37 GB
after 106 days of uptime, plus a pile of build leftovers that only a manual terminal session found.

## Install

```bash
bash scripts/bundle.sh
```

This builds a release binary, wraps it in `Mac Dev Monitor.app` with an icon, signs it ad hoc and copies it to
`~/Applications`. Open it from there. Use `--no-install` to only build `dist/Mac Dev Monitor.app`.

## Dev Tools

Every common stack, in one page:

| Stack | Scanned |
|---|---|
| JavaScript & Node | npm, Yarn, pnpm store (`pnpm store prune`), Bun, Corepack, Deno, node-gyp, Electron, Playwright, Cypress, Puppeteer |
| Python | pip, uv, Poetry cache (never its virtualenvs), conda (`conda clean`), Hugging Face models |
| Java, Kotlin & Android | Gradle caches/distributions/daemon logs, Maven, Android tool cache, old Android Studio versions |
| Rust · Go · Ruby · Dart · .NET | Cargo registry, Go build/module cache (`go clean`), CocoaPods, Bundler, Pub, NuGet |
| Homebrew | `brew cleanup --prune=all` with its own dry-run estimate |
| Xcode extras | SwiftUI previews, simulator caches, Xcode caches, device logs |
| Editors | VS Code and Cursor caches, old JetBrains versions |
| Project build folders | `node_modules`, Rust `target`, virtualenvs, `Pods`, `.next`, `.dart_tool`, Gradle/Flutter `build`, `.gradle`, SwiftPM `.build` — each only when its project file sits next to it; idle = no change for 30 days |
| Docker | `docker system df`; prune dangling images, build cache, stopped containers, unused images, unused volumes |
| Git | repos with many loose objects → `git gc` |
| Running | Docker/VMs, Android emulators, database servers, Node/Bun/Deno, Gradle/Kotlin daemons |

Caches are deleted outright (a cache in the Trash frees nothing); tools with their own cleanup (brew, pnpm, conda, go) run it.

## Applications

Every app in `/Applications`, `~/Applications` and the system folders, with size, version, last opened (Spotlight),
source (Apple / App Store / Homebrew / downloaded) and running state. Each row opens a **Where it lives** dropdown:
the app plus every match in ~/Library and /Library (app data, caches, preferences, sandbox and shared containers, saved
state, logs, crash reports, web data, launch agents and daemons, privileged helpers, plug-ins), vendor folders
(`Application Support/Google/AndroidStudio…`), home dot-folders (`~/.vscode`), installer receipts and the Homebrew cask —
each with size, why it matched, and Reveal in Finder.

**Deep uninstall** quits the app, unloads its launch agents/daemons and moves everything ticked to the **Trash**
(recoverable); root-owned items go through one administrator prompt (`mv` into your Trash, `pkgutil --forget`).
Matches that could be shared (same developer, `~/.android`, `~/.docker`) start unticked. Credentials folders (`~/.ssh`,
`~/.aws`, …) are never offered. Apps in `/System/Applications` (and Safari) are protected by macOS and can't be removed by any app.

Deep Clean also finds data left by apps you already deleted — only sandbox containers and saved window states (which only
apps create), plus other entries with the same bundle ID, so command-line tool caches are never mistaken for leftovers.

## Deep Clean

One button (menu bar, Overview, or the Deep Clean page) that makes the Mac fresh again:

1. **Scan** — checks, with live progress: memory & swap, fseventsd & system daemons, leftover dev processes,
   git worktrees, Xcode build data, simulators, caches & temp folders, disk space. Scanning changes nothing.
2. **Review** — every cleanable thing as a checkbox with what it frees (disk or RAM), a safety label and the exact items.
   Pre-ticked (*Recommended*) are only leftovers: a bloated fseventsd, stuck dev processes, stale worktree entries,
   orphaned build folders, /tmp build copies idle a day, unusable simulators, device symbols unused for 30 days,
   and Claude temp folders idle a day whose session is closed.
   Work in progress stays unticked: running simulators, Gradle daemons, idle worktrees, build folders used today or inside
   repos, build data for current projects, Xcode's module cache, unused runtimes, restarting the Mac.
   A review older than 5 minutes must be rescanned before it can clean.
3. **Clean** — runs the ticked items in a safe order (stop processes → delete → restart fseventsd → restart last),
   each re-checking the Mac first, then shows before vs. now for memory, swap, disk and fseventsd and the space freed.

## Permissions

The top of Deep Clean (and Settings → Permissions) lists everything the app relies on, whether it's granted,
why it's needed, and a button to grant it — or to open the right System Settings pane when macOS doesn't allow asking:

| Permission | Why | |
|---|---|---|
| Documents/Desktop/Downloads folder (whichever holds your repo folders) | Find worktrees and build folders inside repos | Required |
| Notifications | Warnings with the dashboard closed | Optional |
| Automation → loginwindow | Open the system restart dialog | Optional |
| Full Disk Access | Accurate sizes for protected caches (System Settings only) | Optional |
| Open at login | Monitor from login | Optional |
| Administrator password | Restart fseventsd — asked by macOS each time, never stored | — |

Statuses refresh whenever the app comes back to the front, e.g. after you change them in System Settings.

## What it watches

| Page | Shows | Can do (always after a confirmation) |
|---|---|---|
| Overview | Health cards, every issue with its fix, recent activity | Fix one issue, or "Fix All Safe Issues" (leftovers only) |
| Memory | Free %, pressure, swap, compressed, 3-hour charts, biggest processes by real footprint | Quit a process, restart fseventsd (admin prompt) |
| Processes | Dev leftovers older than a day (Crashlytics uploads, `tail -f`, simctl, xcodebuild, lldb), running dev tools, zombies | Stop them, restart the Mac |
| Worktrees | Every worktree under your repo folders: stale, locked by a dead session, in use by a process, uncommitted, unpushed | Prune / unlock stale entries, `git worktree remove` clean unused ones |
| Build Data | DerivedData in Xcode's folder, `/tmp` and inside repos: in use, orphaned, shared caches | Delete one, several, or all orphans |
| Simulators | Devices with data size, unusable ones, runtimes | Delete devices, unusable ones, unused runtimes; shut down all |
| Storage | Disk, iOS DeviceSupport, Claude temp folders, other caches, Time Machine local snapshot count | Delete DeviceSupport / idle Claude temp folders |
| Activity | Everything the app changed, with space freed | — |

The menu bar shows free memory and the worst issue; its panel has the key numbers and quick fixes.
Warnings and critical issues also arrive as notifications (at most once per issue every 6 hours).

## Safety rules

- Nothing changes without a confirmation that says exactly what will happen.
- Deletion is limited by `DeletionPolicy` to build data and caches tools recreate: direct children of
  DerivedData and iOS DeviceSupport, folders named `DerivedData` in your home folder, and `/private/tmp/claude-<uid>/…`.
  Deletes are refused while an `xcodebuild` is running.
- Worktrees are removed only through `git worktree remove` (never forced), and only when clean, fully pushed,
  unlocked, and no process is working inside them.
- A DerivedData folder without project info is only called an orphan after a day untouched; it may be mid-build.
- One-click fixes for build folders outside Xcode's default location only cover ones idle for a day.
- Archives, `~/Library/Caches`, Gradle, Android emulators and npm are shown but never deleted.
- Every action re-checks the machine right before it acts: a stopped process must still run the same command
  (so a reused PID is never hit), and system processes (kernel_task, launchd, loginwindow, WindowServer, …) are never signalled.
  Folders a process is working in are skipped, as are Claude session scratch folders used in the last day.
- Manual `git worktree lock`s (no PID in the reason) are never undone; git status runs with `--no-optional-locks`.
- Restarting fseventsd uses the standard macOS administrator prompt; restarting the Mac uses the system dialog.

## Develop

```bash
swift test                                   # parsers, rules, health evaluation, deletion policy, live readers
swift build && .build/debug/MacDevMonitor --snapshot /tmp/snaps   # PNG of every page from live data
```

`MonitorCore` holds parsing, readers, rules and actions (no UI); `MacDevMonitor` is the SwiftUI app.
Thresholds, refresh intervals, repo folders, notifications, Trash-vs-delete and open-at-login are in Settings.
