import Foundation

/// Decides which review threads can be placed inline on the locally-rendered
/// diff, and which must fall back to the Conversation list. The diff pane shows
/// the *live worktree* diff (merge-base…worktree), but GitHub anchors comments
/// to line numbers computed against the PR head commit. So a thread is placed
/// inline only when we can trust those line numbers: the worktree's HEAD matches
/// the PR head, the thread isn't outdated, and it still has a current line. Any
/// thread that fails the gate is never mis-placed — it stays reachable in the
/// list. Pure (no git, no network) so the gate is tested in isolation.
enum CommentAnchoring {

    /// An inline placement for one thread: which diff side and line to render on.
    struct Anchor: Equatable {
        let threadID: String
        let side: DiffSide
        let line: Int
    }

    /// Anchors grouped by file path (only gate-passing threads), plus the ids of
    /// threads shown only in the Conversation list.
    struct Result: Equatable {
        let inlineByPath: [String: [Anchor]]
        let listOnly: Set<String>
    }

    static func resolve(threads: [ReviewThread], prHeadOid: String?, worktreeHeadSHA: String?) -> Result {
        let headMatch = prHeadOid != nil && prHeadOid == worktreeHeadSHA
        var inlineByPath: [String: [Anchor]] = [:]
        var listOnly: Set<String> = []
        for thread in threads {
            if headMatch, !thread.isOutdated, let line = thread.line {
                inlineByPath[thread.path, default: []].append(
                    Anchor(threadID: thread.id, side: thread.side, line: line))
            } else {
                listOnly.insert(thread.id)
            }
        }
        return Result(inlineByPath: inlineByPath, listOnly: listOnly)
    }
}
