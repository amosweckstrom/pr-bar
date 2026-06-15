# LGTM

A macOS menu bar app for keeping an eye on GitHub pull requests across a few
repos you care about — and seeing at a glance when someone has requested your
review.

The menu bar shows a checklist icon with a badge counting the PRs awaiting your
review. Click it to see your tracked repos, each expanded to its open PRs, with
review-requested PRs pinned to the top. Each row shows the title, number,
author, a CI status dot, and the review decision. Click a PR to open it in your
browser.

You can also hand a PR straight to a terminal coding agent (Claude Code, Codex,
Gemini CLI, Cursor Agent, or a custom command): it opens your terminal of choice
seeded with a prompt that walks the diff one change at a time. For your own PRs,
the agent opens a git worktree off your local clone and addresses the review
comments in place.

## Features

- Tracks any number of `owner/repo` repositories (configurable in-app)
- Badge = number of PRs where you're a requested reviewer
- Per-PR: title, `#number`, author, CI rollup status, review decision
- Review-requested PRs sorted to the top of each repo
- Auto-refreshes every 3 minutes (and on open); manual refresh button
- Hand a PR to a terminal coding agent for a guided, one-change-at-a-time review
- Address review comments on your own PRs via an auto-created git worktree
- Pluggable agent (Claude Code, Codex, Gemini CLI, Cursor Agent, or custom) and
  terminal (Terminal, iTerm, Ghostty, WezTerm, kitty, Alacritty)
- GitHub token stored in the macOS Keychain
- Optional launch at login

## Requirements

- macOS 14+
- Swift toolchain (Command Line Tools or Xcode) for building. The UI is pure
  SwiftUI with no third-party dependencies, styled after GitHub's Primer design
  language and adapting to light/dark appearance.
- A GitHub Personal Access Token with read access to the repos you track
  (classic: `repo` scope; fine-grained: read-only Pull requests + Contents)
- For AI review: a terminal emulator and the CLI of your chosen coding agent
  (e.g. `claude`) on your `PATH`. To address comments on your own PRs, a local
  clone of the repo set in Settings.

## Build

```sh
./scripts/build-app.sh           # builds build/LGTM.app
./scripts/build-app.sh --install # also copies it to /Applications
```

Because the app is ad-hoc signed (not notarized), the first launch may need a
right-click → Open to get past Gatekeeper.

## First run

1. Launch **LGTM** — a checklist icon appears in the menu bar.
2. Open **Settings** (gear icon) and paste your GitHub token.
3. Add the repos you want to track as `owner` / `repo`.
4. Under **AI review**, pick your coding agent and terminal. To address comments
   on your own PRs, set each repo's local clone path.
5. Optionally enable **Launch at login**.

## Project layout

```
Sources/LGTM/
  LGTMApp.swift      – app entry, MenuBarExtra + badge
  AppState.swift     – tracked repos, fetch loop, refresh timer
  GitHubClient.swift – GitHub GraphQL queries
  Keychain.swift     – PAT storage
  LoginItem.swift    – launch-at-login via SMAppService
  Models.swift       – PR / repo / status types
  Theme.swift        – GitHub Primer palette (light/dark) + state colors
  MenuView.swift     – dropdown UI (Primer list-groups + label pills)
  SettingsView.swift – token + repo + AI review management (Primer sections)
  AIReview.swift     – hands a PR to a coding agent; review + comments prompts
  Agents.swift       – known coding agents and their CLI invocations
  Terminals.swift    – terminal detection + launching a shell command
bundle/
  Info.plist         – app bundle metadata (LSUIElement)
  LGTM.entitlements  – network + non-sandboxed
Tests/LGTMTests/     – unit tests (e.g. review-state display)
scripts/build-app.sh – builds and signs the .app bundle
```
