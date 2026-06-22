import Foundation

/// A repository the user wants to track, identified by owner/name.
struct TrackedRepo: Codable, Identifiable, Hashable {
    var owner: String
    var name: String
    /// Absolute path to the user's local clone, used to open a git worktree for
    /// AI comment sessions. Nil until configured in Settings.
    var localPath: String?

    var id: String { "\(owner)/\(name)" }
    var slug: String { "\(owner)/\(name)" }

    // Identity is owner/name only — localPath must not affect equality/hashing,
    // or dedup (`contains`) and removal (`==`) would break when a path is set.
    static func == (lhs: TrackedRepo, rhs: TrackedRepo) -> Bool {
        lhs.owner == rhs.owner && lhs.name == rhs.name
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(owner)
        hasher.combine(name)
    }
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

/// The review state LGTM actually *displays*, with every domain rule already
/// folded in, so no downstream code re-derives it: (a) a pending re-review
/// request outranks a stale CHANGES_REQUESTED (the ball is back with the
/// reviewer), and (b) "review required" and "no decision" both read as
/// "awaiting review". Every row, counter, and sort goes through
/// `PullRequest.displayReviewState` — never the raw `reviewState` — so the same
/// PR can only ever render one way. The raw value doubles as sort order
/// (lower = wants my attention sooner).
enum DisplayReviewState: Int, Comparable {
    case changesRequested = 0
    case approved = 1
    case awaitingReview = 2

    static func < (lhs: DisplayReviewState, rhs: DisplayReviewState) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// A single pull request as surfaced in the menu.
struct PullRequest: Identifiable, Hashable, Codable {
    let id: String            // global node id, stable across refreshes
    let number: Int
    let title: String
    let url: String
    let author: String
    /// GitHub avatar URL for the author, if available.
    let authorAvatarURL: String?
    let checkStatus: CheckStatus
    let reviewState: ReviewState
    /// True when a review is requested from the signed-in user — directly OR via a
    /// team they belong to. Set by the User-login decode and, authoritatively,
    /// by the cross-repo `review-requested:@me` search merge (so team/CODEOWNERS
    /// requests count too); hence `var`, flipped on during that merge.
    var reviewRequestedFromMe: Bool
    /// True when the signed-in user opened this PR.
    let authoredByMe: Bool
    /// True for draft PRs. Drafts aren't review-ready, so they're shown with a
    /// "draft" label and excluded from the review-requested count.
    var isDraft: Bool = false
    /// When a review was most recently requested from the signed-in user, if known.
    let reviewRequestedAt: Date?
    /// True when at least one reviewer is currently requested (a fresh or
    /// re-requested review that hasn't been answered yet).
    let hasPendingReviewRequest: Bool

    /// Single source of truth for the review state shown anywhere in the UI,
    /// with all display rules folded in (see `DisplayReviewState`). GitHub leaves
    /// `reviewDecision` at CHANGES_REQUESTED even after you push fixes and
    /// re-request review, so a pending request outranks it and reads as
    /// "awaiting review"; "review required" and "no decision" do too.
    var displayReviewState: DisplayReviewState {
        if reviewState == .approved { return .approved }
        if hasPendingReviewRequest { return .awaitingReview }
        switch reviewState {
        case .changesRequested: return .changesRequested
        case .approved, .reviewRequired, .none: return .awaitingReview
        }
    }

    /// One of your PRs that a reviewer has acted on — approved it or asked for
    /// changes you haven't yet re-requested review on — and so wants your
    /// attention (merge it, or address feedback).
    var awaitingMyResponse: Bool {
        authoredByMe && (displayReviewState == .approved || displayReviewState == .changesRequested)
    }
}

/// A pull request paired with the repo it lives in, for cross-repo sections.
struct AttentionPR: Identifiable {
    let repo: TrackedRepo
    let pr: PullRequest
    var id: String { pr.id }
}

// MARK: - PR conversation (comments shown in the review window)

/// One comment within a review thread.
struct ReviewComment {
    let id: String
    let author: String
    let authorAvatarURL: String?
    let bodyHTML: String
    let createdAt: Date?
}

/// Which side of the diff a review thread is anchored to. GitHub's `diffSide` is
/// LEFT (the base/old side) or RIGHT (the head/new side); anything else (or
/// missing) defaults to the new side.
enum DiffSide: Equatable {
    case left, right

    init(_ raw: String?) {
        self = raw?.uppercased() == "LEFT" ? .left : .right
    }
}

/// What a review thread is anchored to: a specific line, or the file as a whole.
/// GitHub's `subjectType` is LINE or FILE; anything else defaults to a line.
enum ThreadSubject: Equatable {
    case line, file

    init(_ raw: String?) {
        self = raw?.uppercased() == "FILE" ? .file : .line
    }
}

/// One inline review thread, anchored to a line in the diff.
struct ReviewThread {
    /// GraphQL node id — the target for resolve/unresolve and reply mutations,
    /// and the reconcile key when merging a background refresh.
    let id: String
    let path: String
    /// Line in the file at the PR head, on `side`. Nil once the thread is
    /// outdated (the line no longer exists in the current diff).
    let line: Int?
    /// Line at the commit the thread was originally left on, on `side`. Survives
    /// even when `line` is nil, so an outdated thread can still describe itself.
    let originalLine: Int?
    /// Start line of a multi-line thread's range, if any (its end is `line`).
    let startLine: Int?
    let side: DiffSide
    let isResolved: Bool
    let isOutdated: Bool
    let subject: ThreadSubject
    let comments: [ReviewComment]
}

/// The verdict of a submitted review. GitHub's review `state` is APPROVED /
/// CHANGES_REQUESTED / COMMENTED / DISMISSED / PENDING; anything else (or a
/// missing value) reads as a plain comment.
enum ReviewSummaryState: Equatable {
    case approved, changesRequested, commented, dismissed, pending

    init(_ raw: String?) {
        switch raw?.uppercased() {
        case "APPROVED": self = .approved
        case "CHANGES_REQUESTED": self = .changesRequested
        case "DISMISSED": self = .dismissed
        case "PENDING": self = .pending
        default: self = .commented
        }
    }
}

/// The summary of one submitted review: its verdict plus any message body.
struct ReviewSummary {
    let author: String
    let authorAvatarURL: String?
    let state: ReviewSummaryState
    let bodyHTML: String
    let submittedAt: Date?
}

/// One general (issue-style) comment on the PR, not anchored to any line.
struct IssueComment {
    let author: String
    let authorAvatarURL: String?
    let bodyHTML: String
    let createdAt: Date?
}

/// The whole comment payload fetched for one PR's review window.
struct PRConversation {
    /// The PR's head commit SHA, against which inline comment line numbers are
    /// resolved — compared to the worktree's HEAD to gate inline anchoring.
    let headRefOid: String?
    let threads: [ReviewThread]
    let reviews: [ReviewSummary]
    let conversation: [IssueComment]
}

/// PRs for one repo, already sorted (review-requested first).
struct RepoPRs: Identifiable, Codable {
    var repo: TrackedRepo
    var pullRequests: [PullRequest]
    var error: String?

    var id: String { repo.id }

    var reviewRequestedCount: Int {
        pullRequests.filter { $0.reviewRequestedFromMe && !$0.isDraft }.count
    }
}
