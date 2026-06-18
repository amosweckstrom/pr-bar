import XCTest
@testable import LGTM

/// Pins the pure GitHub GraphQL → `[PullRequest]` decode/derivation/sort, with no
/// network. Guards the check-rollup mapping, the ghost/avatar fallbacks, the
/// case-insensitive viewer matching for review-requested-from-me and
/// authored-by-me, the pending-review-request flag, the most-recent
/// review-requested timestamp, the pin-on-top stable sort, and the two decode
/// failure paths.
final class GitHubDecodeTests: XCTestCase {

    // MARK: - Fixture builders

    /// Build a single PR node dictionary shaped like GitHub's GraphQL response.
    private func node(
        id: String = "PR_1",
        number: Int = 1,
        title: String = "Title",
        url: String = "https://example.com/pr/1",
        author: [String: Any]? = ["login": "octocat", "avatarUrl": "https://avatars/octocat"],
        reviewDecision: String? = nil,
        rollupState: String? = nil,
        includeRollup: Bool = true,
        isDraft: Bool = false,
        requestedLogins: [String] = [],
        requestedReviewers: [[String: Any]]? = nil,
        timeline: [(login: String, createdAt: String)] = []
    ) -> [String: Any] {
        var n: [String: Any] = [
            "id": id,
            "number": number,
            "title": title,
            "url": url,
            "isDraft": isDraft
        ]
        if let author { n["author"] = author }
        if let reviewDecision { n["reviewDecision"] = reviewDecision }

        // commits.last.commit.statusCheckRollup.state
        var rollup: [String: Any]? = nil
        if includeRollup {
            if let rollupState {
                rollup = ["state": rollupState]
            } else {
                rollup = nil
            }
        }
        let commitNode: [String: Any] = ["commit": ["statusCheckRollup": rollup as Any]]
        n["commits"] = ["nodes": [commitNode]]

        // reviewRequests.nodes[].requestedReviewer — explicit reviewers (to inject
        // teams/bots) take precedence; otherwise build User reviewers from logins.
        let requestNodes: [[String: Any]] = requestedReviewers.map { reviewers in
            reviewers.map { ["requestedReviewer": $0] }
        } ?? requestedLogins.map {
            ["requestedReviewer": ["__typename": "User", "login": $0]]
        }
        n["reviewRequests"] = ["nodes": requestNodes]

        // timelineItems.nodes[] (REVIEW_REQUESTED_EVENT)
        let timelineNodes: [[String: Any]] = timeline.map {
            [
                "__typename": "ReviewRequestedEvent",
                "createdAt": $0.createdAt,
                "requestedReviewer": ["__typename": "User", "login": $0.login]
            ]
        }
        n["timelineItems"] = ["nodes": timelineNodes]

        return n
    }

    /// Wrap PR nodes in the top-level GraphQL envelope.
    private func envelope(_ nodes: [[String: Any]]) -> [String: Any] {
        ["data": ["repository": ["pullRequests": ["nodes": nodes]]]]
    }

    /// A `review-requested:@me` search PR node: a normal node plus the
    /// `__typename`/`repository` the search decode needs to route it back.
    private func searchNode(id: String, number: Int, owner: String, name: String,
                            isDraft: Bool = false) -> [String: Any] {
        var n = node(id: id, number: number, isDraft: isDraft)
        n["__typename"] = "PullRequest"
        n["repository"] = ["name": name, "owner": ["login": owner]]
        return n
    }

    /// Wrap search PR nodes in the top-level `data.search` envelope.
    private func searchEnvelope(_ nodes: [[String: Any]], hasNextPage: Bool = false,
                                endCursor: String? = nil) -> [String: Any] {
        var pageInfo: [String: Any] = ["hasNextPage": hasNextPage]
        if let endCursor { pageInfo["endCursor"] = endCursor }
        return ["data": ["search": ["pageInfo": pageInfo, "nodes": nodes]]]
    }

    // MARK: - statusCheckRollup mapping

    func testRollupMapping() throws {
        let cases: [(String?, CheckStatus)] = [
            ("SUCCESS", .success),
            ("FAILURE", .failure),
            ("ERROR", .failure),
            ("PENDING", .pending),
            ("EXPECTED", .pending),
            ("WHATEVER", .none)
        ]
        for (state, expected) in cases {
            let json = envelope([node(rollupState: state)])
            let prs = try GitHubClient.decodePullRequests(from: json, viewerLogin: "me")
            XCTAssertEqual(prs.first?.checkStatus, expected, "rollup \(state ?? "nil")")
        }
    }

    func testMissingRollupMapsToNone() throws {
        // No statusCheckRollup object at all.
        let json = envelope([node(includeRollup: false)])
        let prs = try GitHubClient.decodePullRequests(from: json, viewerLogin: "me")
        XCTAssertEqual(prs.first?.checkStatus, CheckStatus.none)
    }

    // MARK: - author / avatar fallbacks

    func testMissingAuthorBecomesGhost() throws {
        let json = envelope([node(author: nil)])
        let prs = try GitHubClient.decodePullRequests(from: json, viewerLogin: "me")
        XCTAssertEqual(prs.first?.author, "ghost")
        XCTAssertNil(prs.first?.authorAvatarURL)
    }

    func testMissingAvatarURLIsNil() throws {
        let json = envelope([node(author: ["login": "octocat"])])
        let prs = try GitHubClient.decodePullRequests(from: json, viewerLogin: "me")
        XCTAssertEqual(prs.first?.author, "octocat")
        XCTAssertNil(prs.first?.authorAvatarURL)
    }

    // MARK: - reviewRequestedFromMe (case-insensitive)

    func testReviewRequestedFromMeIsCaseInsensitive() throws {
        let json = envelope([node(requestedLogins: ["ME"])])
        let prs = try GitHubClient.decodePullRequests(from: json, viewerLogin: "me")
        XCTAssertTrue(prs.first?.reviewRequestedFromMe ?? false)
    }

    func testReviewRequestedFromMeFalseWhenOnlyOthers() throws {
        let json = envelope([node(requestedLogins: ["someone", "another"])])
        let prs = try GitHubClient.decodePullRequests(from: json, viewerLogin: "me")
        XCTAssertFalse(prs.first?.reviewRequestedFromMe ?? true)
    }

    // MARK: - hasPendingReviewRequest

    func testHasPendingReviewRequestTracksRequestNodes() throws {
        let withRequests = try GitHubClient.decodePullRequests(
            from: envelope([node(requestedLogins: ["whoever"])]), viewerLogin: "me")
        XCTAssertTrue(withRequests.first?.hasPendingReviewRequest ?? false)

        let withoutRequests = try GitHubClient.decodePullRequests(
            from: envelope([node(requestedLogins: [])]), viewerLogin: "me")
        XCTAssertFalse(withoutRequests.first?.hasPendingReviewRequest ?? true)
    }

    // A pending *bot* reviewer (e.g. Copilot) must not read as "awaiting review",
    // or it would mask a real CHANGES_REQUESTED on every PR it sits on.
    func testBotOnlyPendingRequestIsNotPending() throws {
        let json = envelope([node(requestedReviewers: [["__typename": "Bot", "login": "copilot"]])])
        let prs = try GitHubClient.decodePullRequests(from: json, viewerLogin: "me")
        XCTAssertFalse(prs.first?.hasPendingReviewRequest ?? true)
        XCTAssertFalse(prs.first?.reviewRequestedFromMe ?? true)
    }

    // A pending team reviewer counts as a real pending request; membership (is the
    // team mine?) is resolved by the team-aware search, not this decode.
    func testTeamPendingRequestCountsAsPending() throws {
        let json = envelope([node(requestedReviewers: [["__typename": "Team", "slug": "platform"]])])
        let prs = try GitHubClient.decodePullRequests(from: json, viewerLogin: "me")
        XCTAssertTrue(prs.first?.hasPendingReviewRequest ?? false)
        XCTAssertFalse(prs.first?.reviewRequestedFromMe ?? true)
    }

    // MARK: - isDraft

    func testIsDraftDecoded() throws {
        let draft = try GitHubClient.decodePullRequests(from: envelope([node(isDraft: true)]), viewerLogin: "me")
        XCTAssertTrue(draft.first?.isDraft ?? false)
        let ready = try GitHubClient.decodePullRequests(from: envelope([node(isDraft: false)]), viewerLogin: "me")
        XCTAssertFalse(ready.first?.isDraft ?? true)
    }

    // Drafts don't count toward the review-requested badge even if flagged.
    func testDraftExcludedFromReviewRequestedCount() throws {
        let prs = try GitHubClient.decodePullRequests(
            from: envelope([
                node(id: "d", number: 1, isDraft: true, requestedLogins: ["me"]),
                node(id: "r", number: 2, isDraft: false, requestedLogins: ["me"]),
            ]), viewerLogin: "me")
        let repo = RepoPRs(repo: TrackedRepo(owner: "o", name: "r"), pullRequests: prs, error: nil)
        XCTAssertEqual(repo.reviewRequestedCount, 1)
    }

    // MARK: - review-requested:@me search decode

    func testDecodeReviewRequestedTagsReposAndFlags() throws {
        let json = searchEnvelope([
            searchNode(id: "P1", number: 11, owner: "Acme", name: "Web"),
            searchNode(id: "P2", number: 12, owner: "acme", name: "api"),
        ])
        let (prs, next) = try GitHubClient.decodeReviewRequested(from: json, viewerLogin: "me")
        XCTAssertNil(next)
        XCTAssertEqual(prs.map(\.pr.id), ["P1", "P2"])
        XCTAssertEqual(prs.map(\.owner), ["Acme", "acme"])
        XCTAssertTrue(prs.allSatisfy { $0.pr.reviewRequestedFromMe })
        XCTAssertTrue(prs.allSatisfy { $0.pr.hasPendingReviewRequest })
    }

    func testDecodeReviewRequestedReturnsCursorOnlyWhenMorePages() throws {
        let more = try GitHubClient.decodeReviewRequested(
            from: searchEnvelope([], hasNextPage: true, endCursor: "CUR"), viewerLogin: "me")
        XCTAssertEqual(more.nextCursor, "CUR")
        let done = try GitHubClient.decodeReviewRequested(
            from: searchEnvelope([], hasNextPage: false, endCursor: "CUR"), viewerLogin: "me")
        XCTAssertNil(done.nextCursor)
    }

    func testDecodeReviewRequestedMissingSearchThrows() {
        XCTAssertThrowsError(try GitHubClient.decodeReviewRequested(from: ["data": [:]], viewerLogin: "me"))
    }

    // MARK: - merge(_:reviewRequested:)

    func testMergeFlipsFlagOnExistingPR() throws {
        let list = try GitHubClient.decodePullRequests(
            from: envelope([node(id: "X", number: 1, requestedLogins: [])]), viewerLogin: "me")
        XCTAssertFalse(list.first?.reviewRequestedFromMe ?? true)   // not flagged by the list query
        let results = [RepoPRs(repo: TrackedRepo(owner: "o", name: "r"), pullRequests: list, error: nil)]

        let req = try GitHubClient.decodeReviewRequested(
            from: searchEnvelope([searchNode(id: "X", number: 1, owner: "o", name: "r")]),
            viewerLogin: "me").prs
        let merged = GitHubClient.merge(results, reviewRequested: req)
        XCTAssertEqual(merged.first?.pullRequests.count, 1)
        XCTAssertTrue(merged.first?.pullRequests.first?.reviewRequestedFromMe ?? false)
    }

    func testMergeAppendsMissingReviewRequestedPRAndPinsIt() throws {
        // The list missed PR "B" (beyond the 50-cap, or requested only via a team).
        let list = try GitHubClient.decodePullRequests(
            from: envelope([node(id: "A", number: 1, requestedLogins: [])]), viewerLogin: "me")
        let results = [RepoPRs(repo: TrackedRepo(owner: "o", name: "r"), pullRequests: list, error: nil)]

        let req = try GitHubClient.decodeReviewRequested(
            from: searchEnvelope([searchNode(id: "B", number: 2, owner: "o", name: "r")]),
            viewerLogin: "me").prs
        let prs = try XCTUnwrap(GitHubClient.merge(results, reviewRequested: req).first?.pullRequests)
        XCTAssertEqual(prs.count, 2)
        XCTAssertEqual(prs.first?.id, "B", "an appended review-requested PR pins to the top")
        XCTAssertTrue(prs.first?.reviewRequestedFromMe ?? false)
    }

    func testMergeLeavesUnmatchedReposUntouched() throws {
        let list = try GitHubClient.decodePullRequests(
            from: envelope([node(id: "A", number: 1)]), viewerLogin: "me")
        let results = [RepoPRs(repo: TrackedRepo(owner: "o", name: "other"), pullRequests: list, error: nil)]
        let req = try GitHubClient.decodeReviewRequested(
            from: searchEnvelope([searchNode(id: "Z", number: 9, owner: "o", name: "r")]),
            viewerLogin: "me").prs
        let merged = GitHubClient.merge(results, reviewRequested: req)
        XCTAssertEqual(merged.first?.pullRequests.map(\.id), ["A"])
    }

    // MARK: - authoredByMe (case-insensitive)

    func testAuthoredByMeIsCaseInsensitive() throws {
        let mine = try GitHubClient.decodePullRequests(
            from: envelope([node(author: ["login": "ME"])]), viewerLogin: "me")
        XCTAssertTrue(mine.first?.authoredByMe ?? false)

        let theirs = try GitHubClient.decodePullRequests(
            from: envelope([node(author: ["login": "someone"])]), viewerLogin: "me")
        XCTAssertFalse(theirs.first?.authoredByMe ?? true)
    }

    // MARK: - reviewRequestedAt (most recent matching event)

    func testReviewRequestedAtPicksMostRecentMatchingEvent() throws {
        let json = envelope([node(timeline: [
            (login: "me", createdAt: "2026-01-01T00:00:00Z"),
            (login: "other", createdAt: "2026-06-01T00:00:00Z"),   // newer but not me — ignored
            (login: "ME", createdAt: "2026-03-01T00:00:00Z")        // most recent matching
        ])])
        let prs = try GitHubClient.decodePullRequests(from: json, viewerLogin: "me")
        let iso = ISO8601DateFormatter()
        XCTAssertEqual(prs.first?.reviewRequestedAt, iso.date(from: "2026-03-01T00:00:00Z"))
    }

    func testReviewRequestedAtNilWhenNoMatchingEvent() throws {
        let json = envelope([node(timeline: [
            (login: "other", createdAt: "2026-06-01T00:00:00Z")
        ])])
        let prs = try GitHubClient.decodePullRequests(from: json, viewerLogin: "me")
        XCTAssertNil(prs.first?.reviewRequestedAt)
    }

    // MARK: - sort: requested-from-me pinned, stable otherwise

    func testRequestedFromMePinnedAboveStablePreservingOrder() throws {
        // API order: A(other) B(me) C(other) D(me) E(other) F(me).
        // Expected: the requested-from-me group (B,D,F) pinned first IN ORIGINAL
        // order, then the rest (A,C,E) in original order. Interleaved with two
        // elements per group on each side of a flip, so a reversed-direction or
        // dropped offset tie-break visibly scrambles within-group order and fails.
        let json = envelope([
            node(id: "A", requestedLogins: ["other"]),
            node(id: "B", requestedLogins: ["me"]),
            node(id: "C", requestedLogins: ["other"]),
            node(id: "D", requestedLogins: ["me"]),
            node(id: "E", requestedLogins: ["other"]),
            node(id: "F", requestedLogins: ["me"])
        ])
        let prs = try GitHubClient.decodePullRequests(from: json, viewerLogin: "me")
        XCTAssertEqual(prs.map(\.id), ["B", "D", "F", "A", "C", "E"])
    }

    func testStableOrderAmongTiedFlags() throws {
        // None are requested-from-me — the offset tie-break must preserve original
        // API order. A reversed tie-break would yield Z,Y,X,W; an unordered
        // collection (e.g. a Set/Dictionary regression) would scramble it.
        let json = envelope([
            node(id: "W", requestedLogins: []),
            node(id: "X", requestedLogins: ["other"]),
            node(id: "Y", requestedLogins: []),
            node(id: "Z", requestedLogins: ["other"])
        ])
        let prs = try GitHubClient.decodePullRequests(from: json, viewerLogin: "me")
        XCTAssertEqual(prs.map(\.id), ["W", "X", "Y", "Z"])
    }

    // MARK: - decode failures

    func testMissingDataThrowsDecoding() {
        XCTAssertThrowsError(
            try GitHubClient.decodePullRequests(from: [:], viewerLogin: "me")
        ) { error in
            guard case GitHubError.decoding(let message) = error else {
                return XCTFail("expected GitHubError.decoding, got \(error)")
            }
            XCTAssertEqual(message, "missing data")
        }
    }

    func testMissingRepositoryPullRequestsThrowsDecoding() {
        // data present, but no repository.pullRequests.nodes.
        let json: [String: Any] = ["data": ["repository": [:]]]
        XCTAssertThrowsError(
            try GitHubClient.decodePullRequests(from: json, viewerLogin: "me")
        ) { error in
            guard case GitHubError.decoding(let message) = error else {
                return XCTFail("expected GitHubError.decoding, got \(error)")
            }
            XCTAssertEqual(message, "missing repository.pullRequests")
        }
    }
}
