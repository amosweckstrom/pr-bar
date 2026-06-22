import XCTest
@testable import LGTM

/// Pins skill-file parsing and listing. `parse` is pure; `list` reads a temp dir.
final class SkillStoreTests: XCTestCase {

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lgtm-skills-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testParsesFrontmatterAndBody() {
        let skill = SkillStore.parse(
            "---\nname: My Skill\ndescription: does things\n---\nDo the thing.", id: "my-skill")
        XCTAssertEqual(skill.id, "my-skill")
        XCTAssertEqual(skill.name, "My Skill")
        XCTAssertEqual(skill.description, "does things")
        XCTAssertEqual(skill.body, "Do the thing.")
    }

    func testNameFallsBackToIdWhenNoFrontmatter() {
        let skill = SkillStore.parse("No frontmatter here.", id: "bare")
        XCTAssertEqual(skill.name, "bare")
        XCTAssertNil(skill.description)
        XCTAssertEqual(skill.body, "No frontmatter here.")
    }

    func testMalformedFrontmatterTreatedAsBody() {
        let text = "---\nname: X\nstill going"   // opening fence, no closing fence
        let skill = SkillStore.parse(text, id: "m")
        XCTAssertEqual(skill.name, "m")
        XCTAssertEqual(skill.body, text)
    }

    func testStripsQuotedFrontmatterValues() {
        let skill = SkillStore.parse("---\nname: \"Quoted Name\"\n---\nbody", id: "q")
        XCTAssertEqual(skill.name, "Quoted Name")
    }

    func testListReadsOnlyMarkdownAndSortsByName() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "---\nname: Bravo\n---\nB".write(
            to: dir.appendingPathComponent("b.md"), atomically: true, encoding: .utf8)
        try "---\nname: Alpha\n---\nA".write(
            to: dir.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        try "ignore me".write(
            to: dir.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

        let skills = SkillStore.list(in: dir)
        XCTAssertEqual(skills.map(\.name), ["Alpha", "Bravo"])
        XCTAssertEqual(skills.map(\.id), ["a", "b"])
    }

    func testListOfMissingDirectoryIsEmpty() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("lgtm-skills-does-not-exist-\(UUID().uuidString)")
        XCTAssertEqual(SkillStore.list(in: missing), [])
    }
}
