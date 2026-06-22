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
seeded with a prompt that walks the diff one change at a time. If you've set the
repo's local clone path, the agent runs in a dedicated git worktree for the PR
(real, checked-out code); if you haven't, it still launches and reviews the PR
through `gh` — so "Review with AI" works on any PR, clone or not. For your own
PRs, the agent addresses the review comments in a worktree you can push from. The
`</>` button opens that same worktree, so they share one checkout per PR.

Clicking `</>` opens a built-in **review window** for the PR: a resizable
three-pane mini editor — a file tree with git-status badges on the left, a
syntax-highlighted split diff in the middle, and a real terminal (your login
shell, in the worktree) on the right. The tree and diff panes are rendered by
[trees.software](https://trees.software) and [diffs.com](https://diffs.com)
(vendored into the app, fully offline); the terminal is native
[SwiftTerm](https://github.com/migueldeicaza/SwiftTerm).

## Features

- Tracks any number of `owner/repo` repositories (configurable in-app)
- Badge = PRs awaiting your review, counting requests routed via a team you're on
  (CODEOWNERS), not just direct ones — plus your own PRs with changes requested
- Per-PR: title, `#number`, author, CI rollup status, review decision; drafts are
  labelled and don't count toward the badge
- Review-requested PRs sorted to the top of each repo
- Auto-refreshes every 3 minutes (and on open); manual refresh button
- Hand a PR to a terminal coding agent for a guided, one-change-at-a-time review
- Address review comments on your own PRs via an auto-created git worktree
- Open any PR in a built-in 3-pane review window (tree + diff + terminal) via
  the `</>` button — resizable, follows light/dark, and fully offline
- Read and act on PR comments inside that window: inline review threads anchored
  on the diff, a Conversation tab with review summaries + discussion + an
  inline-comments-by-file roll-up, and in-place reply / resolve / unresolve
- Pluggable agent (Claude Code, Codex, Gemini CLI, Cursor Agent, or custom) and
  terminal (Terminal, iTerm, Ghostty, WezTerm, kitty, Alacritty)
- GitHub token stored in the macOS Keychain
- Optional launch at login

## Requirements

- macOS 14+
- Swift toolchain (Command Line Tools or Xcode) for building. The menu UI is pure
  SwiftUI, styled after GitHub's Primer design language and adapting to light/dark.
  The review window's terminal uses [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)
  and its tree/diff panes are vendored, fully-offline JS bundles — the only
  third-party code.
- A GitHub Personal Access Token with read access to the repos you track
  (classic: `repo` scope; fine-grained: read-only Pull requests + Contents).
  Replying to or resolving PR comments in the review window additionally needs
  write access (classic `repo` already grants it; fine-grained needs read-write
  Pull requests). Reads and AI review work with a read-only token.
- For AI review: a terminal emulator and the CLI of your chosen coding agent
  (e.g. `claude`) on your `PATH`. Plain "Review with AI" needs no local clone; to
  open the `</>` review window or address comments on your own PRs, set the repo's
  local clone path in Settings.

## Build

```sh
./scripts/build-app.sh           # builds build/LGTM.app
./scripts/build-app.sh --install # also copies it to /Applications
```

Because the app is ad-hoc signed (not notarized), the first launch may need a
right-click → Open to get past Gatekeeper.

## Install via Homebrew

Once a release is published (see below):

```sh
brew install --cask amosweckstrom/tap/lgtm
```

The cask strips the download quarantine on install, so no right-click → Open is
needed.

## Releasing

Releases are automated by `.github/workflows/release.yml`. Tag a commit and push:

```sh
git tag v0.2.0 && git push origin v0.2.0
```

CI then builds `LGTM.app` (stamping the version from the tag), zips it, and
publishes a GitHub Release with `LGTM.zip` attached.

To auto-update the Homebrew cask on each release, do this one-time setup:

1. Create a tap repo named `homebrew-tap` (e.g. `amosweckstrom/homebrew-tap`).
2. In this repo's **Settings → Secrets and variables → Actions**, add:
   - Variable `TAP_REPO` = `amosweckstrom/homebrew-tap`
   - Secret `TAP_GITHUB_TOKEN` = a PAT with `contents:write` on the tap repo
3. The release job fills `dist/lgtm.rb.template` with the version + SHA-256 and
   commits `Casks/lgtm.rb` to the tap.

If `TAP_REPO` is unset, the release still publishes; only the cask bump is
skipped (the SHA-256 is printed in the release notes so you can update the cask
by hand).

> **TODO: notarization + auto-update.** The current cask strips the download
> quarantine because the app is only ad-hoc signed — fine for a team, but not
> for zero-trust public distribution. To go fully frictionless: get an Apple
> Developer account ($99/yr), sign with a Developer ID certificate, notarize and
> staple in the release workflow (drop the `xattr` postflight from the cask
> once done), and add [Sparkle](https://sparkle-project.org) for in-app
> auto-updates fed by an appcast generated per release.

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
  AIReview.swift     – hands a PR to a coding agent; review + comments prompts;
                       opens the editor window (openInAppEditor)
  Agents.swift       – known coding agents and their CLI invocations
  Terminals.swift    – terminal detection + launching a shell command
  WorktreeData.swift – git snapshot of a worktree: file tree, status, per-file diff
  EditorWindowController.swift – the 3-pane review window + tree↔diff coordinator
  EditorWebPane.swift          – WKWebView host + app:// scheme handler + JS bridge
  EditorTerminalPane.swift     – SwiftTerm terminal pane (login shell in worktree)
  WebAssets/         – vendored, offline web panes (copied into the .app)
    tree.html / diff.html / style.css
    vendor/{trees,diffs}.bundle.js – esbuild output (committed; built from web/)
web/                 – npm + esbuild project that builds the WebAssets bundles
bundle/
  Info.plist         – app bundle metadata (LSUIElement)
  LGTM.entitlements  – network + non-sandboxed
Tests/LGTMTests/     – unit tests (review-state display, editor bridge contract)
scripts/build-app.sh – builds and signs the .app bundle (copies WebAssets)
```

### Rebuilding the web panes

The tree/diff panes are vendored as offline JS bundles under
`Sources/LGTM/WebAssets/vendor/` (committed). To rebuild them after changing
`web/src/*`:

```sh
cd web && npm install && npm run build
```
