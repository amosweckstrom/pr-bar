import Foundation

/// A repository the user wants to track, identified by owner/name.
struct TrackedRepo: Codable, Identifiable, Hashable {
    var owner: String
    var name: String

    var id: String { "\(owner)/\(name)" }
    var slug: String { "\(owner)/\(name)" }
}

/// Aggregate CI/checks status for a PR's head commit.
enum CheckStatus: String, Codable {
    case success
    case failure
    case pending
    case none

    /// Maps a GitHub statusCheckRollup state string to our simplified status.
    init(rollup: String?) {
        switch rollup?.uppercased() {
        case "SUCCESS":
            self = .success
        case "FAILURE", "ERROR":
            self = .failure
        case "PENDING", "EXPECTED":
            self = .pending
        default:
            self = .none
        }
    }
}

/// The overall review decision on a PR.
enum ReviewState: String, Codable {
    case approved
    case changesRequested
    case reviewRequired
    case none

    init(decision: String?) {
        switch decision?.uppercased() {
        case "APPROVED":
            self = .approved
        case "CHANGES_REQUESTED":
            self = .changesRequested
        case "REVIEW_REQUIRED":
            self = .reviewRequired
        default:
            self = .none
        }
    }
}

/// A single pull request as surfaced in the menu.
struct PullRequest: Identifiable, Hashable {
    let id: String            // global node id, stable across refreshes
    let number: Int
    let title: String
    let url: String
    let author: String
    let checkStatus: CheckStatus
    let reviewState: ReviewState
    /// True when the signed-in user is an explicitly requested reviewer.
    let reviewRequestedFromMe: Bool
    /// True when the signed-in user opened this PR.
    let authoredByMe: Bool

    /// One of your PRs that a reviewer has acted on — approved it or asked for
    /// changes — and so wants your attention (merge it, or address feedback).
    var awaitingMyResponse: Bool {
        authoredByMe && (reviewState == .approved || reviewState == .changesRequested)
    }
}

/// A pull request paired with the repo it lives in, for cross-repo sections.
struct AttentionPR: Identifiable {
    let repo: TrackedRepo
    let pr: PullRequest
    var id: String { pr.id }
}

/// PRs for one repo, already sorted (review-requested first).
struct RepoPRs: Identifiable {
    let repo: TrackedRepo
    var pullRequests: [PullRequest]
    var error: String?

    var id: String { repo.id }

    var reviewRequestedCount: Int {
        pullRequests.filter { $0.reviewRequestedFromMe }.count
    }
}
