import XCTest
@testable import LGTM

/// Pins which `(old, new)` refs each diff mode picks. Pure — no git.
final class AgentDiffTests: XCTestCase {

    func testPRModeDiffsBaseToHead() {
        let r = AgentDiff.refs(mode: .pr, base: "BASE", headSHA: "HEAD")
        XCTAssertEqual(r.oldRef, "BASE")
        XCTAssertEqual(r.newRef, "HEAD")
    }

    func testAgentModeDiffsHeadToWorkingTree() {
        let r = AgentDiff.refs(mode: .agent, base: "BASE", headSHA: "HEAD")
        XCTAssertEqual(r.oldRef, "HEAD")
        XCTAssertNil(r.newRef, "nil new ref means the live working tree")
    }

    func testPRModeFallsBackToWorkingTreeWhenHeadUnknown() {
        let r = AgentDiff.refs(mode: .pr, base: "BASE", headSHA: nil)
        XCTAssertEqual(r.oldRef, "BASE")
        XCTAssertNil(r.newRef, "an unresolved HEAD falls back to base→working-tree")
    }
}
