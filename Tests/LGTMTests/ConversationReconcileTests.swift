import XCTest
@testable import LGTM

/// Pins the non-destructive poll merge: a background refresh must not disrupt a
/// thread the user is replying on, nor drop an in-flight optimistic write. Pure.
final class ConversationReconcileTests: XCTestCase {

    private func thread(id: String, isResolved: Bool = false,
                        comments: [ReviewComment] = []) -> ReviewThread {
        ReviewThread(
            id: id, path: "a.swift", line: 1, originalLine: nil, startLine: nil,
            side: .right, isResolved: isResolved, isOutdated: false,
            subject: .line, comments: comments)
    }

    private func comment(id: String, body: String = "x") -> ReviewComment {
        ReviewComment(id: id, author: "me", authorAvatarURL: nil, bodyHTML: body, createdAt: nil)
    }

    // MARK: - Tracer: fresh wins when nothing is in flight

    func testMergeWithoutPendingOrDirtyReturnsFresh() {
        let merged = ConversationReconcile.merge(
            previous: [thread(id: "A")],
            fresh: [thread(id: "A"), thread(id: "B")],   // B newly appeared
            pending: .empty, dirtyThreadIDs: [])
        XCTAssertEqual(merged.map(\.id), ["A", "B"])
    }

    // MARK: - dirty thread preserved

    func testDirtyThreadKeepsPreviousVersion() {
        let previous = [thread(id: "A", comments: [comment(id: "c1")])]
        let fresh = [thread(id: "A", comments: [comment(id: "c1"), comment(id: "c2", body: "from someone else")])]

        let merged = ConversationReconcile.merge(
            previous: previous, fresh: fresh, pending: .empty, dirtyThreadIDs: ["A"])

        XCTAssertEqual(merged.first?.comments.map(\.id), ["c1"],
                       "an open reply box must not be disrupted by a poll")
    }

    // MARK: - optimistic reply survives until the server echoes it

    func testPendingReplyAppendedWhenAbsentFromFresh() {
        let fresh = [thread(id: "A", comments: [comment(id: "c1")])]
        let pending = ConversationReconcile.Pending(
            replies: ["A": [comment(id: "tmp1", body: "optimistic")]], resolved: [:])

        let merged = ConversationReconcile.merge(
            previous: [], fresh: fresh, pending: pending, dirtyThreadIDs: [])

        XCTAssertEqual(merged.first?.comments.map(\.id), ["c1", "tmp1"])
    }

    func testPendingReplyNotDuplicatedWhenFreshHasIt() {
        let fresh = [thread(id: "A", comments: [comment(id: "c1"), comment(id: "tmp1")])]
        let pending = ConversationReconcile.Pending(
            replies: ["A": [comment(id: "tmp1")]], resolved: [:])

        let merged = ConversationReconcile.merge(
            previous: [], fresh: fresh, pending: pending, dirtyThreadIDs: [])

        XCTAssertEqual(merged.first?.comments.map(\.id), ["c1", "tmp1"], "no duplicate once echoed")
    }

    // MARK: - optimistic resolve holds until the server agrees

    func testPendingResolveOverridesStaleFreshState() {
        let resolvedOpt = ConversationReconcile.merge(
            previous: [], fresh: [thread(id: "A", isResolved: false)],
            pending: .init(replies: [:], resolved: ["A": true]), dirtyThreadIDs: [])
        XCTAssertEqual(resolvedOpt.first?.isResolved, true, "optimistic resolve must not flip back")

        let unresolvedOpt = ConversationReconcile.merge(
            previous: [], fresh: [thread(id: "A", isResolved: true)],
            pending: .init(replies: [:], resolved: ["A": false]), dirtyThreadIDs: [])
        XCTAssertEqual(unresolvedOpt.first?.isResolved, false, "optimistic unresolve must hold too")
    }
}
