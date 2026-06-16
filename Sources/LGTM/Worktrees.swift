import Foundation

/// Housekeeping for the PR worktrees LGTM creates under `~/.lgtm/worktrees`.
enum Worktrees {
    /// Remove worktrees whose PR is merged or closed. Runs in the background.
    ///
    /// Safe by design:
    ///  - only ever touches directories under `~/.lgtm/worktrees` — the main
    ///    clone (derived from each worktree's common git dir) is never removed;
    ///  - confirms each PR is actually MERGED/CLOSED via `gh` before removing, so
    ///    a failed or partial refresh can't trigger deletion;
    ///  - uses plain `git worktree remove` (no `--force`): a worktree with
    ///    uncommitted changes is kept, not destroyed. Committed work survives on
    ///    its branch regardless — `git worktree remove` leaves the branch ref.
    static func cleanupClosed() {
        DispatchQueue.global(qos: .utility).async {
            let proc = Process()
            // Login shell so the user's PATH (git, gh — often in Homebrew) resolves
            // even though the app is launched by the GUI with a minimal environment.
            proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
            proc.arguments = ["-lc", script]
            do {
                try proc.run()
            } catch {
                NSLog("lgtm: worktree cleanup failed to launch: \(error.localizedDescription)")
            }
        }
    }

    private static let script = #"""
    set -u
    ROOT="$HOME/.lgtm/worktrees"
    [ -d "$ROOT" ] || exit 0
    for D in "$ROOT"/*-pr-*; do
      [ -d "$D" ] || continue
      N="${D##*-pr-}"
      case "$N" in (*[!0-9]*) continue ;; esac          # trailing token not a PR number
      git -C "$D" rev-parse --is-inside-work-tree >/dev/null 2>&1 || continue
      STATE="$(cd "$D" && gh pr view "$N" --json state -q .state 2>/dev/null)"
      [ -n "$STATE" ] || continue                        # state unknown (offline?) — leave it
      case "$STATE" in
        MERGED|CLOSED)
          COMMON="$(git -C "$D" rev-parse --git-common-dir 2>/dev/null)" || continue
          case "$COMMON" in /*) ;; *) COMMON="$D/$COMMON" ;; esac
          MAIN="$(cd "$(dirname "$COMMON")" && pwd)" || continue
          if git -C "$MAIN" worktree remove "$D" 2>/dev/null; then
            echo "[lgtm] removed worktree for $STATE PR #$N: $D"
          else
            echo "[lgtm] kept worktree for PR #$N (uncommitted changes) — remove manually: $D"
          fi
          ;;
      esac
    done
    """#
}
