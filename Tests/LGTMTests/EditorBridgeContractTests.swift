import XCTest
@testable import LGTM

/// Guards the Swift→JS data contract for the editor window. These shapes are
/// consumed by the vendored web bundles (web/src/{diff,tree}-entry.mjs); a field
/// rename here silently blanks a pane (as the `path` vs `name` mismatch once did).
final class EditorBridgeContractTests: XCTestCase {

    /// The diff pane's `renderDiff` destructures `{ path, oldText, newText, binary }`.
    func testFileDiffEncodesExpectedKeys() throws {
        let fd = WorktreeData.FileDiff(path: "a/b.swift", oldText: "old",
                                       newText: "new", binary: false, status: .modified)
        let data = try JSONEncoder().encode(fd)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["path"] as? String, "a/b.swift")
        XCTAssertEqual(obj["oldText"] as? String, "old")
        XCTAssertEqual(obj["newText"] as? String, "new")
        XCTAssertEqual(obj["binary"] as? Bool, false)
        XCTAssertEqual(obj["status"] as? String, "modified")
    }

    /// The tree pane's gitStatus only accepts these six values (@pierre/trees).
    func testStatusRawValuesAreValidTreeStatuses() {
        let valid: Set<String> = ["added", "deleted", "modified", "renamed", "untracked", "ignored"]
        let all: [WorktreeData.Status] = [.added, .deleted, .modified, .renamed, .untracked]
        for s in all {
            XCTAssertTrue(valid.contains(s.rawValue), "\(s.rawValue) is not a valid @pierre/trees status")
        }
    }
}
