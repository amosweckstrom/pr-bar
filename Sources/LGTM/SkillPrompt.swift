import Foundation

/// The specific comment a skill is being run against. Strings are pre-formatted
/// for prompt interpolation; `line` is "" when the anchor line is unknown.
struct CommentContext {
    let comment: String
    let file: String
    let line: String
    let author: String
    let pr: String
}

/// Renders a skill body against a comment.
///
/// If the body uses any of the known `{{…}}` placeholders, they are substituted
/// in place (unknown placeholders are left intact); otherwise a structured
/// context block is appended, so a placeholder-free skill still receives the
/// comment. Pure → unit-tested.
enum SkillPrompt {
    private static let keys = ["comment", "file", "line", "author", "pr"]

    static func render(body: String, context: CommentContext) -> String {
        let values: [String: String] = [
            "comment": context.comment, "file": context.file, "line": context.line,
            "author": context.author, "pr": context.pr,
        ]
        if keys.contains(where: { body.contains("{{\($0)}}") }) {
            var out = body
            for key in keys {
                out = out.replacingOccurrences(of: "{{\(key)}}", with: values[key] ?? "")
            }
            return out
        }
        return body + "\n\n" + contextBlock(context)
    }

    private static func contextBlock(_ c: CommentContext) -> String {
        let loc = c.line.isEmpty ? c.file : "\(c.file):\(c.line)"
        return """
        ---
        Address this review comment:
        - File: \(loc)
        - Author: @\(c.author)
        - PR: #\(c.pr)

        Comment:
        \(c.comment)
        """
    }
}
