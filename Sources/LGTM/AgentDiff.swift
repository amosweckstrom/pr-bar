import Foundation

/// Which version pair the diff pane shows for a file.
enum DiffMode: String {
    /// The PR's own changes: merge-base → the worktree HEAD captured at open.
    /// Stable as the agent edits, so it always reflects the reviewed state.
    case pr
    /// The agent's edits this session: that captured HEAD → the live working tree.
    case agent
}

/// Pure selection of the `(old, new)` git refs to diff for a given mode, kept
/// apart from git I/O so it can be unit-tested. A `nil` `newRef` means "read the
/// live working-tree file"; a `nil` `oldRef` means "no old side" (treat as added).
///
/// In `.pr` mode a `nil` `headSHA` naturally yields a `nil` `newRef`, i.e. the
/// old base→working-tree behaviour — the right fallback when HEAD can't resolve.
enum AgentDiff {
    static func refs(mode: DiffMode, base: String?, headSHA: String?)
        -> (oldRef: String?, newRef: String?) {
        switch mode {
        case .pr:    return (base, headSHA)
        case .agent: return (headSHA, nil)
        }
    }
}
