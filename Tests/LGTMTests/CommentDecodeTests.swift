import XCTest
@testable import LGTM

/// Pins the pure GitHub GraphQL → `PRConversation` decode for the review
/// window's comments, with no network. Fixture-dictionary style mirrors
/// `GitHubDecodeTests` (the PR-list decode).
final class CommentDecodeTests: XCTestCase {

    // MARK: - Fixture builders

    /// One comment node shaped like GitHub's GraphQL response.
    private func commentNode(
        id: String = "C1",
        author: String = "octocat",
        avatarUrl: String? = "https://avatars/octocat",
        bodyHTML: String = "<p>hi</p>",
        createdAt: String = "2026-01-01T00:00:00Z"
    ) -> [String: Any] {
        var a: [String: Any] = ["login": author]
        if let avatarUrl { a["avatarUrl"] = avatarUrl }
        return ["id": id, "author": a, "bodyHTML": bodyHTML, "createdAt": createdAt]
    }

    /// One review-thread node shaped like GitHub's GraphQL response.
    private func threadNode(
        id: String = "T1",
        path: String = "a.swift",
        line: Int? = 1,
        originalLine: Int? = nil,
        startLine: Int? = nil,
        diffSide: String = "RIGHT",
        isResolved: Bool = false,
        isOutdated: Bool = false,
        subjectType: String = "LINE",
        comments: [[String: Any]] = []
    ) -> [String: Any] {
        var n: [String: Any] = [
            "id": id,
            "path": path,
            "diffSide": diffSide,
            "isResolved": isResolved,
            "isOutdated": isOutdated,
            "subjectType": subjectType,
        ]
        if let line { n["line"] = line }
        if let originalLine { n["originalLine"] = originalLine }
        if let startLine { n["startLine"] = startLine }
        n["comments"] = ["nodes": comments]
        return n
    }

    /// One review-summary node shaped like GitHub's GraphQL response.
    private func reviewNode(
        id: String = "R1",
        author: String = "alice",
        avatarUrl: String? = "https://avatars/alice",
        state: String = "APPROVED",
        bodyHTML: String = "<p>lgtm</p>",
        submittedAt: String = "2026-01-01T00:00:00Z"
    ) -> [String: Any] {
        var a: [String: Any] = ["login": author]
        if let avatarUrl { a["avatarUrl"] = avatarUrl }
        return ["id": id, "author": a, "state": state, "bodyHTML": bodyHTML, "submittedAt": submittedAt]
    }

    /// Wrap nodes in the top-level `data.repository.pullRequest` envelope.
    private func envelope(
        threads: [[String: Any]] = [],
        reviews: [[String: Any]] = [],
        comments: [[String: Any]] = [],
        headRefOid: String? = "HEADSHA"
    ) -> [String: Any] {
        var pr: [String: Any] = [
            "reviewThreads": ["nodes": threads],
            "reviews": ["nodes": reviews],
            "comments": ["nodes": comments],
        ]
        if let headRefOid { pr["headRefOid"] = headRefOid }
        return ["data": ["repository": ["pullRequest": pr]]]
    }

    // MARK: - Tracer: one thread + one comment

    func testDecodesOneThreadWithOneComment() throws {
        let json = envelope(threads: [
            threadNode(path: "src/Foo.swift", line: 42, comments: [
                commentNode(author: "carol", bodyHTML: "<p>off by one?</p>"),
            ]),
        ])
        let convo = try GitHubClient.decodeConversation(from: json)
        XCTAssertEqual(convo.threads.count, 1)
        let thread = try XCTUnwrap(convo.threads.first)
        XCTAssertEqual(thread.path, "src/Foo.swift")
        XCTAssertEqual(thread.line, 42)
        XCTAssertEqual(thread.comments.map(\.author), ["carol"])
        XCTAssertEqual(thread.comments.first?.bodyHTML, "<p>off by one?</p>")
    }

    // MARK: - diffSide mapping

    func testDiffSideMapping() throws {
        let cases: [(String, DiffSide)] = [
            ("LEFT", .left),
            ("RIGHT", .right),
            ("WHATEVER", .right),   // unknown defaults to the new (right) side
        ]
        for (raw, expected) in cases {
            let json = envelope(threads: [threadNode(diffSide: raw)])
            let convo = try GitHubClient.decodeConversation(from: json)
            XCTAssertEqual(convo.threads.first?.side, expected, "diffSide \(raw)")
        }
    }

    // MARK: - resolved / outdated flags

    func testResolvedAndOutdatedFlags() throws {
        let json = envelope(threads: [
            threadNode(id: "A", isResolved: true, isOutdated: false),
            threadNode(id: "B", isResolved: false, isOutdated: true),
        ])
        let convo = try GitHubClient.decodeConversation(from: json)
        XCTAssertEqual(convo.threads.map(\.isResolved), [true, false])
        XCTAssertEqual(convo.threads.map(\.isOutdated), [false, true])
    }

    // MARK: - subjectType mapping

    func testSubjectTypeMapping() throws {
        let cases: [(String, ThreadSubject)] = [
            ("LINE", .line),
            ("FILE", .file),
            ("WHATEVER", .line),   // unknown defaults to a line-anchored thread
        ]
        for (raw, expected) in cases {
            let json = envelope(threads: [threadNode(subjectType: raw)])
            let convo = try GitHubClient.decodeConversation(from: json)
            XCTAssertEqual(convo.threads.first?.subject, expected, "subjectType \(raw)")
        }
    }

    // MARK: - multi-line range + null (outdated) line

    func testMultiLineAndNullLineFields() throws {
        let json = envelope(threads: [
            threadNode(id: "M", line: 50, originalLine: 48, startLine: 45),
            threadNode(id: "O", line: nil, originalLine: 30, startLine: nil, isOutdated: true),
        ])
        let convo = try GitHubClient.decodeConversation(from: json)

        let multi = convo.threads[0]
        XCTAssertEqual(multi.line, 50)
        XCTAssertEqual(multi.startLine, 45)
        XCTAssertEqual(multi.originalLine, 48)

        let outdated = convo.threads[1]
        XCTAssertNil(outdated.line)            // current line gone once outdated
        XCTAssertEqual(outdated.originalLine, 30)
        XCTAssertNil(outdated.startLine)
    }

    // MARK: - review summaries

    func testReviewSummariesDecode() throws {
        let iso = ISO8601DateFormatter()

        // A representative review: author, avatar, body, verdict, timestamp.
        let one = try GitHubClient.decodeConversation(from: envelope(reviews: [
            reviewNode(author: "alice", avatarUrl: "https://avatars/alice",
                       state: "APPROVED", bodyHTML: "<p>lgtm</p>",
                       submittedAt: "2026-03-01T00:00:00Z"),
        ]))
        XCTAssertEqual(one.reviews.map(\.author), ["alice"])
        XCTAssertEqual(one.reviews.first?.authorAvatarURL, "https://avatars/alice")
        XCTAssertEqual(one.reviews.first?.state, .approved)
        XCTAssertEqual(one.reviews.first?.bodyHTML, "<p>lgtm</p>")
        XCTAssertEqual(one.reviews.first?.submittedAt, iso.date(from: "2026-03-01T00:00:00Z"))

        // Verdict state mapping.
        let cases: [(String, ReviewSummaryState)] = [
            ("APPROVED", .approved),
            ("CHANGES_REQUESTED", .changesRequested),
            ("COMMENTED", .commented),
            ("DISMISSED", .dismissed),
            ("PENDING", .pending),
            ("WHATEVER", .commented),   // unknown reads as a plain comment
        ]
        for (raw, expected) in cases {
            let convo = try GitHubClient.decodeConversation(from: envelope(reviews: [reviewNode(state: raw)]))
            XCTAssertEqual(convo.reviews.first?.state, expected, "state \(raw)")
        }
    }

    // MARK: - general conversation comments

    func testGeneralConversationCommentsDecode() throws {
        let iso = ISO8601DateFormatter()
        let json = envelope(comments: [
            commentNode(author: "bob", avatarUrl: "https://avatars/bob",
                        bodyHTML: "<p>can we rename?</p>", createdAt: "2026-02-01T00:00:00Z"),
        ])
        let convo = try GitHubClient.decodeConversation(from: json)
        XCTAssertEqual(convo.conversation.map(\.author), ["bob"])
        XCTAssertEqual(convo.conversation.first?.authorAvatarURL, "https://avatars/bob")
        XCTAssertEqual(convo.conversation.first?.bodyHTML, "<p>can we rename?</p>")
        XCTAssertEqual(convo.conversation.first?.createdAt, iso.date(from: "2026-02-01T00:00:00Z"))
    }

    // MARK: - headRefOid (anchor gate input)

    func testHeadRefOidDecoded() throws {
        let present = try GitHubClient.decodeConversation(from: envelope(headRefOid: "abc123"))
        XCTAssertEqual(present.headRefOid, "abc123")

        let absent = try GitHubClient.decodeConversation(from: envelope(headRefOid: nil))
        XCTAssertNil(absent.headRefOid)
    }

    // MARK: - thread id (resolve/reply/reconcile key)

    func testThreadIdDecoded() throws {
        let json = envelope(threads: [threadNode(id: "PRRT_kwabc")])
        let convo = try GitHubClient.decodeConversation(from: json)
        XCTAssertEqual(convo.threads.first?.id, "PRRT_kwabc")
    }

    // MARK: - thread comment full fields

    func testThreadCommentFullFields() throws {
        let iso = ISO8601DateFormatter()
        let json = envelope(threads: [
            threadNode(comments: [
                commentNode(id: "C9", author: "carol", avatarUrl: "https://avatars/carol",
                            bodyHTML: "<p>hi</p>", createdAt: "2026-04-01T00:00:00Z"),
            ]),
        ])
        let comment = try XCTUnwrap(
            try GitHubClient.decodeConversation(from: json).threads.first?.comments.first)
        XCTAssertEqual(comment.id, "C9")
        XCTAssertEqual(comment.author, "carol")
        XCTAssertEqual(comment.authorAvatarURL, "https://avatars/carol")
        XCTAssertEqual(comment.bodyHTML, "<p>hi</p>")
        XCTAssertEqual(comment.createdAt, iso.date(from: "2026-04-01T00:00:00Z"))
    }

    // MARK: - author / avatar fallbacks (deleted user, missing avatar)

    func testCommentAuthorAndAvatarFallbacks() throws {
        let json = envelope(
            threads: [threadNode(comments: [["id": "C", "bodyHTML": "<p>x</p>"]])],
            comments: [["id": "I", "bodyHTML": "<p>y</p>"]]
        )
        let convo = try GitHubClient.decodeConversation(from: json)

        let threadComment = try XCTUnwrap(convo.threads.first?.comments.first)
        XCTAssertEqual(threadComment.author, "ghost")   // missing author node
        XCTAssertNil(threadComment.authorAvatarURL)

        let issueComment = try XCTUnwrap(convo.conversation.first)
        XCTAssertEqual(issueComment.author, "ghost")
        XCTAssertNil(issueComment.authorAvatarURL)
    }

    // MARK: - empty + failure paths

    func testEmptyConversationDecodesToEmpties() throws {
        let convo = try GitHubClient.decodeConversation(from: envelope())
        XCTAssertTrue(convo.threads.isEmpty)
        XCTAssertTrue(convo.reviews.isEmpty)
        XCTAssertTrue(convo.conversation.isEmpty)
    }

    func testMissingPullRequestThrowsDecoding() {
        XCTAssertThrowsError(
            try GitHubClient.decodeConversation(from: ["data": ["repository": [:]]])
        ) { error in
            guard case GitHubError.decoding(let message) = error else {
                return XCTFail("expected GitHubError.decoding, got \(error)")
            }
            XCTAssertEqual(message, "missing data.repository.pullRequest")
        }
    }

    // MARK: - mutation decode: reply

    func testDecodeReplyCommentExtractsCreatedComment() throws {
        let json: [String: Any] = ["data": ["addPullRequestReviewThreadReply": ["comment": [
            "id": "C_new",
            "author": ["login": "me", "avatarUrl": "https://avatars/me"],
            "bodyHTML": "<p>done</p>",
            "createdAt": "2026-05-01T00:00:00Z",
        ]]]]
        let comment = try GitHubClient.decodeReplyComment(from: json)
        XCTAssertEqual(comment.id, "C_new")
        XCTAssertEqual(comment.author, "me")
        XCTAssertEqual(comment.authorAvatarURL, "https://avatars/me")
        XCTAssertEqual(comment.bodyHTML, "<p>done</p>")
    }

    func testDecodeReplyCommentMissingThrows() {
        XCTAssertThrowsError(try GitHubClient.decodeReplyComment(from: ["data": [:]]))
    }

    // MARK: - mutation decode: resolve / unresolve

    func testDecodeResolvedStateReadsThreadResolved() throws {
        let resolved: [String: Any] = ["data": ["resolveReviewThread": ["thread": ["id": "T", "isResolved": true]]]]
        XCTAssertTrue(try GitHubClient.decodeResolvedState(from: resolved, mutation: "resolveReviewThread"))

        let unresolved: [String: Any] = ["data": ["unresolveReviewThread": ["thread": ["id": "T", "isResolved": false]]]]
        XCTAssertFalse(try GitHubClient.decodeResolvedState(from: unresolved, mutation: "unresolveReviewThread"))
    }

    func testDecodeResolvedStateMissingThrows() {
        XCTAssertThrowsError(
            try GitHubClient.decodeResolvedState(from: ["data": [:]], mutation: "resolveReviewThread"))
    }
}
