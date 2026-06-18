import XCTest
@testable import LGTM

/// Pins the cross-repo "attention" digest: that `Attention`'s pure derivations
/// over `[RepoPRs]` flatten across repos, filter to the right PRs, and sort by
/// `displayReviewState` (with number-descending tie-breaks) exactly as the menu
/// expects. These guard the seam that `AppState` now delegates to.
final class AttentionTests: XCTestCase {

    /// Build a PR with only the fields that affect attention derivation.
    private func pr(
        number: Int,
        reviewState: ReviewState,
        hasPendingReviewRequest: Bool = false,
        authoredByMe: Bool = true,
        reviewRequestedFromMe: Bool = false
    ) -> PullRequest {
        PullRequest(
            id: "\(number)", number: number, title: "t", url: "u",
            author: "me", authorAvatarURL: nil,
            checkStatus: .none, reviewState: reviewState,
            reviewRequestedFromMe: reviewRequestedFromMe, authoredByMe: authoredByMe,
            reviewRequestedAt: nil, hasPendingReviewRequest: hasPendingReviewRequest
        )
    }

    private func repo(_ owner: String, _ name: String, _ prs: [PullRequest]) -> RepoPRs {
        RepoPRs(repo: TrackedRepo(owner: owner, name: name), pullRequests: prs, error: nil)
    }

    // respondedPRs: changes requested sorts before approved.
    func testRespondedPRsOrderChangesRequestedBeforeApproved() {
        let results = [
            repo("o", "r", [
                pr(number: 1, reviewState: .approved),
                pr(number: 2, reviewState: .changesRequested),
            ])
        ]
        let responded = Attention.respondedPRs(in: results)
        XCTAssertEqual(responded.map(\.pr.number), [2, 1])
    }

    // myPRs: by displayReviewState, then number DESC on ties.
    func testMyPRsOrderByStateThenNumberDescending() {
        let results = [
            repo("o", "r", [
                pr(number: 5, reviewState: .reviewRequired),          // awaitingReview
                pr(number: 10, reviewState: .approved),               // approved
                pr(number: 3, reviewState: .changesRequested),        // changesRequested
                pr(number: 7, reviewState: .changesRequested),        // changesRequested (tie)
                pr(number: 4, reviewState: .approved),                // approved (tie)
            ])
        ]
        let mine = Attention.myPRs(in: results)
        // changesRequested (7,3) < approved (10,4) < awaitingReview (5),
        // ties broken by number descending.
        XCTAssertEqual(mine.map(\.pr.number), [7, 3, 10, 4, 5])
    }

    // respondedPRs includes only awaitingMyResponse PRs.
    func testRespondedPRsFiltersToAwaitingMyResponse() {
        let results = [
            repo("o", "r", [
                pr(number: 1, reviewState: .changesRequested),                       // mine, my move
                pr(number: 2, reviewState: .approved),                               // mine, my move
                pr(number: 3, reviewState: .reviewRequired),                         // mine, not my move yet
                pr(number: 4, reviewState: .approved, authoredByMe: false),          // someone else's PR
                pr(number: 5, reviewState: .changesRequested,                        // re-requested: ball is theirs
                   hasPendingReviewRequest: true),
            ])
        ]
        let responded = Attention.respondedPRs(in: results)
        XCTAssertEqual(Set(responded.map(\.pr.number)), [1, 2])
    }

    // reviewRequestedTotal counts only reviewRequestedFromMe across multiple repos.
    func testReviewRequestedTotalAcrossMultipleRepos() {
        let results = [
            repo("o", "a", [
                pr(number: 1, reviewState: .reviewRequired, authoredByMe: false, reviewRequestedFromMe: true),
                pr(number: 2, reviewState: .reviewRequired, authoredByMe: false, reviewRequestedFromMe: false),
            ]),
            repo("o", "b", [
                pr(number: 3, reviewState: .reviewRequired, authoredByMe: false, reviewRequestedFromMe: true),
                pr(number: 4, reviewState: .reviewRequired, authoredByMe: false, reviewRequestedFromMe: true),
            ]),
        ]
        XCTAssertEqual(Attention.reviewRequestedTotal(in: results), 3)
    }

    // myPRs flattens across repos and pairs each PR with its correct repo.
    func testMyPRsFlattensAcrossReposWithCorrectRepoPairing() {
        let results = [
            repo("acme", "alpha", [pr(number: 1, reviewState: .changesRequested)]),
            repo("acme", "beta", [pr(number: 2, reviewState: .approved)]),
        ]
        let mine = Attention.myPRs(in: results)
        XCTAssertEqual(mine.count, 2)
        // PR #1 (changesRequested) sorts first and belongs to alpha; #2 to beta.
        XCTAssertEqual(mine[0].pr.number, 1)
        XCTAssertEqual(mine[0].repo.name, "alpha")
        XCTAssertEqual(mine[1].pr.number, 2)
        XCTAssertEqual(mine[1].repo.name, "beta")
    }

    // attentionTotal = reviewRequestedTotal + respondedPRs.count.
    func testAttentionTotalCombinesReviewsAndResponses() {
        let results = [
            repo("o", "a", [
                pr(number: 1, reviewState: .reviewRequired, authoredByMe: false, reviewRequestedFromMe: true),
                pr(number: 2, reviewState: .changesRequested),  // responded
            ]),
            repo("o", "b", [
                pr(number: 3, reviewState: .approved),          // responded
            ]),
        ]
        // 1 review requested + 2 responded
        XCTAssertEqual(Attention.attentionTotal(in: results), 3)
    }

    // menuBarBadgeCount = reviews owed + changes-requested responses, and EXCLUDES
    // approved-but-unmerged PRs (which still count toward attentionTotal/the pill).
    func testMenuBarBadgeCountExcludesApprovedResponses() {
        let results = [
            repo("o", "a", [
                pr(number: 1, reviewState: .reviewRequired, authoredByMe: false, reviewRequestedFromMe: true), // owed
                pr(number: 2, reviewState: .changesRequested),  // my move — counts toward the badge
                pr(number: 3, reviewState: .approved),          // approved — excluded from the badge
            ]),
        ]
        XCTAssertEqual(Attention.attentionTotal(in: results), 3)   // 1 owed + 2 responded
        XCTAssertEqual(Attention.menuBarBadgeCount(in: results), 2) // 1 owed + 1 changes-requested
    }

    // Empty results → empty lists and zero totals.
    func testEmptyResults() {
        let results: [RepoPRs] = []
        XCTAssertEqual(Attention.reviewRequestedTotal(in: results), 0)
        XCTAssertTrue(Attention.respondedPRs(in: results).isEmpty)
        XCTAssertTrue(Attention.myPRs(in: results).isEmpty)
        XCTAssertEqual(Attention.attentionTotal(in: results), 0)
        XCTAssertEqual(Attention.menuBarBadgeCount(in: results), 0)
    }
}
