import XCTest
@testable import LGTM

/// Pins the drift-gate: which review threads anchor inline on the live worktree
/// diff vs. fall back to the Conversation list. Pure — no git, no network.
final class CommentAnchoringTests: XCTestCase {

    /// Build a `ReviewThread` with only the fields the gate inspects.
    private func thread(
        id: String = "T",
        path: String = "a.swift",
        line: Int? = 10,
        side: DiffSide = .right,
        isOutdated: Bool = false,
        isResolved: Bool = false
    ) -> ReviewThread {
        ReviewThread(
            id: id, path: path, line: line, originalLine: nil, startLine: nil,
            side: side, isResolved: isResolved, isOutdated: isOutdated,
            subject: .line, comments: []
        )
    }

    // MARK: - Tracer: an anchorable thread

    func testAnchorableThreadProducesInlineAnchor() {
        let result = CommentAnchoring.resolve(
            threads: [thread(id: "T1", path: "src/Foo.swift", line: 42, side: .right)],
            prHeadOid: "SHA", worktreeHeadSHA: "SHA")

        XCTAssertEqual(result.inlineByPath["src/Foo.swift"],
                       [CommentAnchoring.Anchor(threadID: "T1", side: .right, line: 42)])
        XCTAssertTrue(result.listOnly.isEmpty)
    }

    // MARK: - drift gate

    func testHeadMismatchFallsBackToList() {
        let result = CommentAnchoring.resolve(
            threads: [thread(id: "T1", path: "a.swift", line: 5)],
            prHeadOid: "PRHEAD", worktreeHeadSHA: "LOCALDRIFT")

        XCTAssertTrue(result.inlineByPath.isEmpty, "a drifted worktree must not place anchors")
        XCTAssertEqual(result.listOnly, ["T1"])
    }

    func testOutdatedThreadFallsBackToList() {
        let result = CommentAnchoring.resolve(
            threads: [thread(id: "T1", line: 5, isOutdated: true)],
            prHeadOid: "SHA", worktreeHeadSHA: "SHA")

        XCTAssertTrue(result.inlineByPath.isEmpty, "an outdated thread's line no longer exists")
        XCTAssertEqual(result.listOnly, ["T1"])
    }

    func testNullLineFallsBackToList() {
        let result = CommentAnchoring.resolve(
            threads: [thread(id: "T1", line: nil)],
            prHeadOid: "SHA", worktreeHeadSHA: "SHA")

        XCTAssertTrue(result.inlineByPath.isEmpty)
        XCTAssertEqual(result.listOnly, ["T1"])
    }

    func testUnknownHeadShaEitherSideFallsBackToList() {
        let prNil = CommentAnchoring.resolve(
            threads: [thread(id: "T1", line: 5)], prHeadOid: nil, worktreeHeadSHA: "SHA")
        XCTAssertEqual(prNil.listOnly, ["T1"])
        XCTAssertTrue(prNil.inlineByPath.isEmpty)

        let worktreeNil = CommentAnchoring.resolve(
            threads: [thread(id: "T1", line: 5)], prHeadOid: "SHA", worktreeHeadSHA: nil)
        XCTAssertEqual(worktreeNil.listOnly, ["T1"])
        XCTAssertTrue(worktreeNil.inlineByPath.isEmpty)
    }

    // MARK: - resolved is display-only, not a gate

    func testResolvedThreadStillAnchorsInline() {
        let result = CommentAnchoring.resolve(
            threads: [thread(id: "T1", path: "a.swift", line: 7, isResolved: true)],
            prHeadOid: "SHA", worktreeHeadSHA: "SHA")

        XCTAssertEqual(result.inlineByPath["a.swift"]?.map(\.threadID), ["T1"])
        XCTAssertTrue(result.listOnly.isEmpty)
    }

    // MARK: - grouping by path (+ LEFT-side mapping, input order preserved)

    func testGroupsByPathAcrossThreads() {
        let result = CommentAnchoring.resolve(
            threads: [
                thread(id: "A", path: "foo.swift", line: 1, side: .right),
                thread(id: "B", path: "foo.swift", line: 9, side: .left),
                thread(id: "C", path: "bar.swift", line: 3, side: .right),
            ],
            prHeadOid: "SHA", worktreeHeadSHA: "SHA")

        XCTAssertEqual(result.inlineByPath["foo.swift"], [
            .init(threadID: "A", side: .right, line: 1),
            .init(threadID: "B", side: .left, line: 9),
        ])
        XCTAssertEqual(result.inlineByPath["bar.swift"], [
            .init(threadID: "C", side: .right, line: 3),
        ])
        XCTAssertTrue(result.listOnly.isEmpty)
    }
}
