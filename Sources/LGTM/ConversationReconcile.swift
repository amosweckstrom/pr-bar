import Foundation

/// Merges a fresh background-poll fetch over the threads already on screen
/// without yanking anything out from under the user. `fresh` is the
/// authoritative server state, but two kinds of local state must survive a
/// merge: a thread the user is mid-reply on (its previous version is kept so the
/// open compose box doesn't re-render), and in-flight optimistic writes (an
/// optimistic reply stays visible until the server echoes it; an optimistic
/// resolve holds until the server agrees). Pure, so the merge is tested in
/// isolation. The caller clears a `Pending` entry once the corresponding
/// mutation confirms, so optimistic state never lingers past its write.
enum ConversationReconcile {

    /// Local writes not yet confirmed by the server, keyed by thread id.
    struct Pending {
        /// Optimistic replies appended locally, by thread id.
        var replies: [String: [ReviewComment]]
        /// Desired resolved state not yet confirmed, by thread id.
        var resolved: [String: Bool]

        static let empty = Pending(replies: [:], resolved: [:])
    }

    static func merge(previous: [ReviewThread], fresh: [ReviewThread],
                      pending: Pending, dirtyThreadIDs: Set<String>) -> [ReviewThread] {
        let previousByID = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return fresh.map { thread in
            // A thread the user is mid-reply on keeps its on-screen version.
            if dirtyThreadIDs.contains(thread.id), let prior = previousByID[thread.id] {
                return prior
            }
            var result = thread
            if let optimistic = pending.replies[thread.id] {
                // Keep an optimistic reply visible until the server echoes it;
                // once echoed (same id present), don't double it.
                let present = Set(thread.comments.map(\.id))
                let missing = optimistic.filter { !present.contains($0.id) }
                if !missing.isEmpty {
                    result = result.with(comments: result.comments + missing)
                }
            }
            if let desired = pending.resolved[thread.id], desired != result.isResolved {
                result = result.with(isResolved: desired)
            }
            return result
        }
    }
}

private extension ReviewThread {
    /// A copy of this thread with a different comment list (the struct is
    /// otherwise immutable).
    func with(comments: [ReviewComment]) -> ReviewThread {
        ReviewThread(
            id: id, path: path, line: line, originalLine: originalLine, startLine: startLine,
            side: side, isResolved: isResolved, isOutdated: isOutdated,
            subject: subject, comments: comments)
    }

    /// A copy of this thread with a different resolved state.
    func with(isResolved: Bool) -> ReviewThread {
        ReviewThread(
            id: id, path: path, line: line, originalLine: originalLine, startLine: startLine,
            side: side, isResolved: isResolved, isOutdated: isOutdated,
            subject: subject, comments: comments)
    }
}
