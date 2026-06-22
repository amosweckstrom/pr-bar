import Foundation

/// One user-authored prompt skill loaded from `~/.lgtm/skills/<id>.md`.
struct Skill: Equatable {
    /// Filename without `.md` — the stable identifier passed back from the web menu.
    let id: String
    /// Display name (frontmatter `name:`, falling back to `id`).
    let name: String
    let description: String?
    /// Markdown body below the frontmatter (or the whole file when there is none).
    let body: String
}

/// Lists and seeds the on-disk skill library under `~/.lgtm/skills` (mirroring
/// `~/.lgtm/hooks`/`worktrees`). `list(in:)`/`parse(_:id:)` are pure given a
/// directory/string (unit-tested with a temp dir); `ensureSeeded` writes the
/// default skill on first use.
enum SkillStore {
    /// `~/.lgtm/skills`.
    static let root: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".lgtm/skills")

    /// Every `*.md` skill in `dir`, parsed and sorted by display name.
    static func list(in dir: URL = root) -> [Skill] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return [] }
        var skills: [Skill] = []
        for url in entries where url.pathExtension.lowercased() == "md" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            skills.append(parse(text, id: url.deletingPathExtension().lastPathComponent))
        }
        return skills.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// Parse optional `--- … ---` frontmatter (only `name`/`description` are read)
    /// + body. Malformed (an opening `---` with no closing fence) → the whole text
    /// is the body and the name falls back to `id`.
    static func parse(_ text: String, id: String) -> Skill {
        var name: String?
        var description: String?
        var body = text

        if text.hasPrefix("---") {
            let lines = text.components(separatedBy: "\n")
            if let closeIdx = lines.dropFirst().firstIndex(of: "---") {
                for line in lines[1..<closeIdx] {
                    if let v = value(of: "name", in: line) { name = v }
                    else if let v = value(of: "description", in: line) { description = v }
                }
                body = lines[(closeIdx + 1)...].joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return Skill(id: id,
                     name: (name?.isEmpty == false) ? name! : id,
                     description: description,
                     body: body)
    }

    /// Extract `key: value` from a frontmatter line, stripping matched surrounding quotes.
    private static func value(of key: String, in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("\(key):") else { return nil }
        var v = String(trimmed.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces)
        if v.count >= 2,
           (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")) {
            v = String(v.dropFirst().dropLast())
        }
        return v
    }

    /// Create the directory and write the default skill when the library has no
    /// skills yet. Returns true if it seeded. Only seeds an empty library, so a
    /// user who deleted the default isn't fighting it back each launch.
    @discardableResult
    static func ensureSeeded(in dir: URL = root) -> Bool {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let existing = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        if existing.contains(where: { $0.pathExtension.lowercased() == "md" }) { return false }
        let url = dir.appendingPathComponent("fix-comment.md")
        do {
            try defaultFixCommentSkill.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            NSLog("lgtm: failed to seed default skill: \(error.localizedDescription)")
            return false
        }
    }

    /// `/git-comments` reduced to the single comment the app hands it (the app
    /// already picked the comment, so there's no round-scoping step).
    static let defaultFixCommentSkill = """
    ---
    name: Fix one comment
    description: Address a single PR review comment, git-comments style
    ---
    You are helping me address ONE review comment on PR #{{pr}}, in the git worktree that is \
    already checked out in this terminal. The most important rule: I stay in control — you make \
    a change only after I say so.

    The comment, by @{{author}} on `{{file}}:{{line}}`:

    > {{comment}}

    Do this, then STOP and wait for my decision:

    1. **What they're saying** — explain the comment in 1–2 plain-English sentences.
    2. **The actual problem (or not)** — look at the code at `{{file}}:{{line}}`. Say whether the \
    concern is valid, partly valid, or invalid, and why.
    3. **Options:**
       - **A — Fix it:** the concrete change you would make.
       - **B — Push back:** a draft reply explaining why no change is needed.
       Then ask: fix / reply / skip / show me the code first?

    Once I decide:
    - **fix:** make the edit, run any relevant tests/lint, show me the diff, then `git commit` with \
    a clear message like `fix: address review comment on {{file}}`. Do NOT push.
    - **reply:** give me the reply text to post — don't post it yourself unless I ask.
    - **skip:** note it and stop.

    If the code at `{{file}}:{{line}}` has already changed since this comment was written, flag that \
    before proposing anything. Never push to the remote.
    """
}
