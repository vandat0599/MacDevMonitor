# System Storage Explorer

## Why

System Settings › Storage shows a large "System Data" bar and nothing more. On this Mac most of it turned out to be
things nobody would guess: 106 GB of Claude Code build folders in `/private/tmp`, 27 GB of Claude desktop data, a 4 GB
Gemini Nano model inside Chrome, 23 GB of macOS-managed downloads (simulator runtimes, Xcode docs, Siri/speech). The
user wants one page that names everything, says what it is, tags how risky removing it is, and removes what can be
removed. Apple Intelligence models come first, since that's what the user suspects most.

## Goals

- Explain every large non-document location: what it is, who owns it, how big, where it lives.
- Tag each item: owner (macOS, App, Developer, Your files) and risk (Safe to delete, Rebuilds itself, Check first,
  Dangerous, Protected by macOS).
- Remove what can be removed, the right way for each: delete (regenerated data), Trash (user data), one admin prompt
  for system-owned files, `tmutil`/`log erase`/`mdutil` for snapshots, logs and Spotlight.
- Where macOS forbids removal (signed system volume, SIP-restricted folders such as AssetsV2 and /Library/Updates),
  say so and point to the supported switch (Apple Intelligence & Siri settings, Xcode › Settings › Components,
  Software Update) instead of a Delete button.
- A permission gate first: Full Disk Access granted and the user is an administrator. The page opens once both hold.

## Non-goals / anti-goals

- Never touch anything SIP-restricted or on the sealed system volume, and never try to work around SIP.
- Never delete a folder a process is working in, one modified in the last hour, or a Claude session's scratch folder
  used in the last day.
- Never delete unknown app data. Unknown folders are explained and revealed in Finder; removal goes through
  Applications (uninstall) instead.
- No privileged helper or stored password: macOS asks each time, through its own prompt.

## Decisions (my calls)

- Group order: on-device AI models first (Apple Intelligence, then Chrome's Gemini Nano, then local LLM stores like
  Ollama/LM Studio/Hugging Face), then groups by size, "macOS itself" last.
- Apple Intelligence size is measured from AssetsV2 folders whose names mark generative/foundation models; its on/off
  state comes from `com.apple.CloudSubscriptionFeatures.optIn`. Removal = open Apple Intelligence & Siri settings.
- Regenerated data (caches, temp, build data, logs) is deleted permanently, as the rest of the app does; user data
  (backups, downloads, AI models you pulled, Mail downloads) goes to the Trash.
- Items other pages already manage (DerivedData, simulators) appear with their size and a "Go to …" link, so there's
  one place that acts on them.
- Everything is re-validated at removal time against an allowlist policy, `lstat` (no symlinks, no SF_RESTRICTED),
  current working directories and recent modification.

## Built from

`MonitorCore/SystemStorage/` (models, catalog of knowledge, scanner, policy, actions) with tests; the page, gate and
model in the app target; snapshot harness renders the gate and the page.
