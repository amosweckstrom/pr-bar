import XCTest
@testable import LGTM

/// Pins skill rendering: placeholder substitution vs. auto-appended context. Pure.
final class SkillPromptTests: XCTestCase {

    private func ctx(comment: String = "off by one", file: String = "a.swift",
                     line: String = "42", author: String = "carol",
                     pr: String = "7") -> CommentContext {
        CommentContext(comment: comment, file: file, line: line, author: author, pr: pr)
    }

    func testSubstitutesAllKnownPlaceholders() {
        let out = SkillPrompt.render(
            body: "Fix {{file}}:{{line}} by @{{author}} on #{{pr}}: {{comment}}",
            context: ctx())
        XCTAssertEqual(out, "Fix a.swift:42 by @carol on #7: off by one")
    }

    func testAppendsContextBlockWhenNoPlaceholders() {
        let out = SkillPrompt.render(body: "Just fix the comment.", context: ctx())
        XCTAssertTrue(out.hasPrefix("Just fix the comment."))
        XCTAssertTrue(out.contains("a.swift:42"))
        XCTAssertTrue(out.contains("@carol"))
        XCTAssertTrue(out.contains("#7"))
        XCTAssertTrue(out.contains("off by one"))
    }

    func testUnknownPlaceholderLeftIntact() {
        let out = SkillPrompt.render(body: "{{file}} {{unknown}}", context: ctx())
        XCTAssertEqual(out, "a.swift {{unknown}}")
    }

    func testEmptyLineOmitsLineSuffixInContextBlock() {
        let out = SkillPrompt.render(body: "no placeholders here", context: ctx(line: ""))
        XCTAssertTrue(out.contains("File: a.swift\n"))
        XCTAssertFalse(out.contains("a.swift:"), "no trailing colon when the line is unknown")
    }
}
