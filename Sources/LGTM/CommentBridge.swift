import Foundation

/// The exact JSON shape the editor's web panes destructure for one inline
/// comment thread. Kept as a dedicated `Encodable` DTO (not the domain
/// `ReviewThread`) so the JS contract is explicit and independent of the GraphQL
/// decode shape: `side` is a plain "left"/"right" string and dates are ISO
/// strings, both of which JS can consume directly. Pinned by `CommentBridgeTests`.
struct ThreadBridge: Encodable {
    let id: String
    let path: String
    /// "left" (base/old column) or "right" (head/new column).
    let side: String
    let line: Int?
    let isResolved: Bool
    let isOutdated: Bool
    let comments: [CommentBridge]

    init(_ thread: ReviewThread) {
        id = thread.id
        path = thread.path
        side = thread.side == .left ? "left" : "right"
        line = thread.line
        isResolved = thread.isResolved
        isOutdated = thread.isOutdated
        comments = thread.comments.map(CommentBridge.init)
    }
}

/// One comment within a `ThreadBridge`, as the web panes destructure it.
struct CommentBridge: Encodable {
    let id: String
    let author: String
    let avatarUrl: String?
    let bodyHTML: String
    let createdAt: String?

    init(_ comment: ReviewComment) {
        id = comment.id
        author = comment.author
        avatarUrl = comment.authorAvatarURL
        bodyHTML = comment.bodyHTML
        createdAt = comment.createdAt.map { ISO8601DateFormatter().string(from: $0) }
    }
}

/// One submitted review's summary, as the conversation pane's timeline reads it.
/// `state` is a lowercase token ("approved" | "changes_requested" | "commented" |
/// "dismissed" | "pending") so the JS can pick a badge without re-deriving it.
struct ReviewBridge: Encodable {
    let author: String
    let avatarUrl: String?
    let state: String
    let bodyHTML: String
    let submittedAt: String?

    init(_ review: ReviewSummary) {
        author = review.author
        avatarUrl = review.authorAvatarURL
        state = Self.token(review.state)
        bodyHTML = review.bodyHTML
        submittedAt = review.submittedAt.map { ISO8601DateFormatter().string(from: $0) }
    }

    private static func token(_ state: ReviewSummaryState) -> String {
        switch state {
        case .approved: return "approved"
        case .changesRequested: return "changes_requested"
        case .commented: return "commented"
        case .dismissed: return "dismissed"
        case .pending: return "pending"
        }
    }
}

/// One general (issue-style) PR comment, as the conversation pane's timeline reads it.
struct IssueCommentBridge: Encodable {
    let author: String
    let avatarUrl: String?
    let bodyHTML: String
    let createdAt: String?

    init(_ comment: IssueComment) {
        author = comment.author
        avatarUrl = comment.authorAvatarURL
        bodyHTML = comment.bodyHTML
        createdAt = comment.createdAt.map { ISO8601DateFormatter().string(from: $0) }
    }
}

/// All review threads for one file, grouped for the conversation pane's
/// inline-comments-by-file roll-up (the never-disappear backstop — every thread
/// is reachable here regardless of whether it could be anchored inline).
struct FileThreadsBridge: Encodable {
    let path: String
    let threads: [ThreadBridge]
}

/// The whole payload the conversation pane (`renderConversation`) destructures:
/// the load state, the review/comment timeline, and the by-file thread roll-up.
/// `inlineThreadIDs` are the threads that passed the anchor gate and are placed
/// in the Diff tab, so the pane shows a "jump to line" affordance only for those.
struct ConversationPayload: Encodable {
    /// "loading" | "loaded" | "error".
    let state: String
    let error: String?
    /// True when the worktree HEAD matches the PR head (inline anchoring is live).
    let headMatches: Bool
    let reviews: [ReviewBridge]
    let comments: [IssueCommentBridge]
    let files: [FileThreadsBridge]
    let inlineThreadIDs: [String]

    static func loading() -> ConversationPayload {
        ConversationPayload(state: "loading", error: nil, headMatches: false,
                            reviews: [], comments: [], files: [], inlineThreadIDs: [])
    }

    static func error(_ message: String) -> ConversationPayload {
        ConversationPayload(state: "error", error: message, headMatches: false,
                            reviews: [], comments: [], files: [], inlineThreadIDs: [])
    }

    /// Build a loaded payload from the decoded conversation plus the anchor-gate
    /// result. Threads are grouped by file in path order; the timeline ordering is
    /// left to the pane (which has each item's timestamp).
    static func loaded(_ conversation: PRConversation,
                       inlineThreadIDs: Set<String>,
                       headMatches: Bool) -> ConversationPayload {
        let byFile = Dictionary(grouping: conversation.threads, by: \.path)
        let files = byFile.keys.sorted().map { path in
            FileThreadsBridge(path: path, threads: byFile[path]!.map(ThreadBridge.init))
        }
        return ConversationPayload(
            state: "loaded",
            error: nil,
            headMatches: headMatches,
            reviews: conversation.reviews.map(ReviewBridge.init),
            comments: conversation.conversation.map(IssueCommentBridge.init),
            files: files,
            inlineThreadIDs: Array(inlineThreadIDs))
    }
}
