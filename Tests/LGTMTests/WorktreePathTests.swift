import XCTest
@testable import LGTM

/// Pins the single source of truth for the worktree-path convention
/// (`~/.lgtm/worktrees/<owner>-<name>-pr-<number>`). The Swift fast-path, the
/// bash that creates the directory, and the cleanup glob all derive from these
/// `Worktrees` members, so any drift in the format would break that agreement.
final class WorktreePathTests: XCTestCase {

    private let repo = TrackedRepo(owner: "octocat", name: "hello-world", localPath: nil)

    /// Build a PR with only the field the path convention depends on (`number`).
    private func pr(number: Int) -> PullRequest {
        PullRequest(
            id: "1", number: number, title: "t", url: "u",
            author: "me", authorAvatarURL: nil,
            checkStatus: .none, reviewState: .none,
            reviewRequestedFromMe: false, authoredByMe: true,
            reviewRequestedAt: nil, hasPendingReviewRequest: false
        )
    }

    func testDirNameFormat() {
        XCTAssertEqual(
            Worktrees.dirName(for: pr(number: 42), in: repo),
            "octocat-hello-world-pr-42")
    }

    func testPathLeafMatchesDirName() {
        let pull = pr(number: 42)
        XCTAssertEqual(
            Worktrees.path(for: pull, in: repo).lastPathComponent,
            Worktrees.dirName(for: pull, in: repo))
        // Concrete tail: openInAppEditor's fast-path existence check must hit
        // exactly the directory the bash slow-path creates.
        XCTAssertTrue(
            Worktrees.path(for: pull, in: repo).path
                .hasSuffix("/.lgtm/worktrees/octocat-hello-world-pr-42"))
    }

    func testShellPathIsConcreteLiteral() {
        // Pin the concrete literal rather than restating the composition rule, so a
        // change that drops `$HOME` from `rootShell` — which would silently break
        // both the worktree-creating bash and the cleanup glob — fails here.
        XCTAssertEqual(Worktrees.rootShell, "$HOME/.lgtm/worktrees")
        XCTAssertEqual(
            Worktrees.shellPath(for: pr(number: 7), in: repo),
            "$HOME/.lgtm/worktrees/octocat-hello-world-pr-7")
    }

    func testPathIsUnderRoot() {
        let path = Worktrees.path(for: pr(number: 99), in: repo).path
        XCTAssertTrue(
            path.contains(".lgtm/worktrees/"),
            "expected \(path) to live under the .lgtm/worktrees root")
    }
}
