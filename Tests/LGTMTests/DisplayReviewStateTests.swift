import XCTest
@testable import LGTM

/// Pins the single source of truth for review-state display. These guard the two
/// domain rules and the canonical label/order so a future edit can't silently
/// re-introduce the kind of "awaiting review here, changes requested there"
/// divergence the audit found.
final class DisplayReviewStateTests: XCTestCase {

    /// Build a PR with only the fields that affect review-state derivation.
    private func pr(
        reviewState: ReviewState,
        hasPendingReviewRequest: Bool = false,
        authoredByMe: Bool = true
    ) -> PullRequest {
        PullRequest(
            id: "1", number: 1, title: "t", url: "u",
            author: "me", authorAvatarURL: nil,
            checkStatus: .none, reviewState: reviewState,
            reviewRequestedFromMe: false, authoredByMe: authoredByMe,
            reviewRequestedAt: nil, hasPendingReviewRequest: hasPendingReviewRequest
        )
    }

    // Rule (a): a pending re-review request outranks a stale CHANGES_REQUESTED.
    func testPendingRerequestOutranksStaleChangesRequested() {
        XCTAssertEqual(
            pr(reviewState: .changesRequested, hasPendingReviewRequest: true).displayReviewState,
            .awaitingReview)
    }

    func testChangesRequestedWithNoPendingStaysChangesRequested() {
        XCTAssertEqual(
            pr(reviewState: .changesRequested, hasPendingReviewRequest: false).displayReviewState,
            .changesRequested)
    }

    // Rule (b): "review required" and "no decision" both collapse to "awaiting review".
    func testReviewRequiredAndNoneCollapseToAwaitingReview() {
        XCTAssertEqual(pr(reviewState: .reviewRequired).displayReviewState, .awaitingReview)
        XCTAssertEqual(pr(reviewState: .none).displayReviewState, .awaitingReview)
    }

    func testApprovedWinsEvenWithPendingRequest() {
        XCTAssertEqual(
            pr(reviewState: .approved, hasPendingReviewRequest: true).displayReviewState,
            .approved)
    }

    // Canonical presentation — labels and pill glyph are fixed.
    func testLabels() {
        XCTAssertEqual(DisplayReviewState.changesRequested.label, "changes requested")
        XCTAssertEqual(DisplayReviewState.awaitingReview.label, "awaiting review")
        XCTAssertEqual(DisplayReviewState.approved.label, "approved")
    }

    func testOnlyApprovedCarriesAPillCheckmark() {
        XCTAssertEqual(DisplayReviewState.approved.leadingSymbol, "checkmark")
        XCTAssertNil(DisplayReviewState.changesRequested.leadingSymbol)
        XCTAssertNil(DisplayReviewState.awaitingReview.leadingSymbol)
    }

    // Sort order: changes requested first, then approved, then awaiting review.
    func testAttentionOrdering() {
        XCTAssertLessThan(DisplayReviewState.changesRequested, .approved)
        XCTAssertLessThan(DisplayReviewState.approved, .awaitingReview)
    }

    // awaitingMyResponse (header "responded" count + badge) tracks the display state.
    func testAwaitingMyResponse() {
        XCTAssertTrue(pr(reviewState: .changesRequested).awaitingMyResponse)
        XCTAssertTrue(pr(reviewState: .approved).awaitingMyResponse)
        // Re-requested after changes: no longer my move.
        XCTAssertFalse(pr(reviewState: .changesRequested, hasPendingReviewRequest: true).awaitingMyResponse)
        XCTAssertFalse(pr(reviewState: .reviewRequired).awaitingMyResponse)
        // Someone else's PR is never "my response".
        XCTAssertFalse(pr(reviewState: .approved, authoredByMe: false).awaitingMyResponse)
    }
}
