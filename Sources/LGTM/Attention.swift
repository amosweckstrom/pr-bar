import Foundation

/// The cross-repo "attention" digest: pure derivations over the fetched
/// `[RepoPRs]` that decide what wants the user's attention and in what order.
/// Every ordering here sorts by `PullRequest.displayReviewState` — the single
/// source of truth for review state (see `DisplayReviewState`) — so rows,
/// counters, and sections can never disagree about whether a PR needs action.
///
/// These are plain functions of value types with no side effects, kept off
/// `AppState` so they can be reasoned about and tested in isolation.
enum Attention {
    /// Total number of PRs awaiting the user's review across all repos.
    static func reviewRequestedTotal(in results: [RepoPRs]) -> Int {
        results.reduce(0) { $0 + $1.reviewRequestedCount }
    }

    /// Your authored PRs that a reviewer has approved or requested changes on,
    /// across all repos. Changes-requested sort first (more to do), then approved.
    static func respondedPRs(in results: [RepoPRs]) -> [AttentionPR] {
        results
            .flatMap { result in
                result.pullRequests
                    .filter { $0.awaitingMyResponse }
                    .map { AttentionPR(repo: result.repo, pr: $0) }
            }
            .sorted { $0.pr.displayReviewState < $1.pr.displayReviewState }
    }

    /// All of your open PRs across tracked repos, ordered by what needs action
    /// first: changes requested, then approved, then still awaiting review.
    static func myPRs(in results: [RepoPRs]) -> [AttentionPR] {
        results
            .flatMap { result in
                result.pullRequests
                    .filter { $0.authoredByMe }
                    .map { AttentionPR(repo: result.repo, pr: $0) }
            }
            .sorted { lhs, rhs in
                if lhs.pr.displayReviewState != rhs.pr.displayReviewState {
                    return lhs.pr.displayReviewState < rhs.pr.displayReviewState
                }
                return lhs.pr.number > rhs.pr.number
            }
    }

    /// Everything that wants the user's attention: reviews owed + responses received.
    static func attentionTotal(in results: [RepoPRs]) -> Int {
        reviewRequestedTotal(in: results) + respondedPRs(in: results).count
    }

    /// What the menu-bar badge counts: work that needs an action from you *now* —
    /// reviews you owe plus your PRs with changes requested. Deliberately EXCLUDES
    /// approved-but-unmerged PRs: those stay visible in the dropdown's "responded"
    /// pill and "Your pull requests" section, but shouldn't keep the menu-bar icon
    /// lit indefinitely for PRs you're intentionally holding open.
    static func menuBarBadgeCount(in results: [RepoPRs]) -> Int {
        reviewRequestedTotal(in: results)
            + respondedPRs(in: results).filter { $0.pr.displayReviewState == .changesRequested }.count
    }
}
