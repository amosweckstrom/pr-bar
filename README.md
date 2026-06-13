# PR Bar

A macOS menu bar app for keeping an eye on GitHub pull requests across a few
repos you care about — and seeing at a glance when someone has requested your
review.

The menu bar shows a checklist icon with a badge counting the PRs awaiting your
review. Click it to see your tracked repos, each expanded to its open PRs, with
review-requested PRs pinned to the top. Each row shows the title, number,
author, a CI status dot, and the review decision. Click a PR to open it in your
browser.

## Features

- Tracks any number of `owner/repo` repositories (configurable in-app)
- Badge = number of PRs where you're a requested reviewer
- Per-PR: title, `#number`, author, CI rollup status, review decision
- Review-requested PRs sorted to the top of each repo
- Auto-refreshes every 3 minutes (and on open); manual refresh button
- GitHub token stored in the macOS Keychain
- Optional launch at login

## Requirements

- macOS 14+
- Full **Xcode** for building (not just Command Line Tools). The UI uses the
  [Luminare](https://github.com/MrKai77/Luminare) SwiftUI library, which relies
  on the `@Entry`/`#Preview` Swift macros whose compiler plugins ship only with
  the Xcode toolchain. After installing Xcode:
  `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`
- A GitHub Personal Access Token with read access to the repos you track
  (classic: `repo` scope; fine-grained: read-only Pull requests + Contents)

## Build

```sh
./scripts/build-app.sh           # builds build/PR Bar.app
./scripts/build-app.sh --install # also copies it to /Applications
```

Because the app is ad-hoc signed (not notarized), the first launch may need a
right-click → Open to get past Gatekeeper.

## First run

1. Launch **PR Bar** — a checklist icon appears in the menu bar.
2. Open **Settings** (gear icon) and paste your GitHub token.
3. Add the repos you want to track as `owner` / `repo`.
4. Optionally enable **Launch at login**.

## Project layout

```
Sources/PRBar/
  PRBarApp.swift     – app entry, MenuBarExtra + badge
  AppState.swift     – tracked repos, fetch loop, refresh timer
  GitHubClient.swift – GitHub GraphQL queries
  Keychain.swift     – PAT storage
  LoginItem.swift    – launch-at-login via SMAppService
  Models.swift       – PR / repo / status types
  Theme.swift        – design tokens (palette, gradients) layered on Luminare
  MenuView.swift     – dropdown UI (Luminare sections + rows)
  SettingsView.swift – token + repo management (Luminare sections)
bundle/
  Info.plist         – app bundle metadata (LSUIElement)
  PRBar.entitlements – network + non-sandboxed
scripts/build-app.sh – builds and signs the .app bundle
```
