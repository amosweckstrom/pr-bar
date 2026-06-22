import XCTest
@testable import LGTM

/// Guards the Swift→JS contract for an inline comment thread. The diff pane's
/// `renderAnnotation` and the conversation pane destructure these exact keys; a
/// rename here silently blanks the thread UI (same failure mode the diff-payload
/// contract guards against in `EditorBridgeContractTests`).
final class CommentBridgeTests: XCTestCase {

    func testThreadBridgeEncodesExpectedKeys() throws {
        let thread = ReviewThread(
            id: "T1", path: "src/Foo.swift", line: 42, originalLine: nil, startLine: nil,
            side: .left, isResolved: true, isOutdated: false, subject: .line,
            comments: [
                ReviewComment(id: "C1", author: "carol",
                              authorAvatarURL: "https://avatars/carol",
                              bodyHTML: "<p>off by one?</p>", createdAt: nil),
            ])

        let data = try JSONEncoder().encode(ThreadBridge(thread))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(obj["id"] as? String, "T1")
        XCTAssertEqual(obj["path"] as? String, "src/Foo.swift")
        XCTAssertEqual(obj["side"] as? String, "left")   // "left" | "right"
        XCTAssertEqual(obj["line"] as? Int, 42)
        XCTAssertEqual(obj["isResolved"] as? Bool, true)
        XCTAssertEqual(obj["isOutdated"] as? Bool, false)

        let comments = try XCTUnwrap(obj["comments"] as? [[String: Any]])
        XCTAssertEqual(comments.first?["id"] as? String, "C1")
        XCTAssertEqual(comments.first?["author"] as? String, "carol")
        XCTAssertEqual(comments.first?["avatarUrl"] as? String, "https://avatars/carol")
        XCTAssertEqual(comments.first?["bodyHTML"] as? String, "<p>off by one?</p>")
    }

    func testRightSideEncodesAsRight() throws {
        let thread = ReviewThread(
            id: "T2", path: "a.swift", line: 1, originalLine: nil, startLine: nil,
            side: .right, isResolved: false, isOutdated: false, subject: .line, comments: [])
        let data = try JSONEncoder().encode(ThreadBridge(thread))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["side"] as? String, "right")
    }
}
