import Foundation

/// Library-agnostic snapshot of a PR worktree for the editor window: the full
/// file tree, a per-file git status map, and the diff base, plus on-demand
/// old/new content for any one file. All of this is computed by shelling out to
/// `git` (and `gh`, for the PR base branch) in the worktree directory, off the
/// main thread. The WKWebView panes consume it; this layer knows nothing about
/// `@pierre/trees` or `@pierre/diffs`.
enum WorktreeData {

    // MARK: - Public model

    /// One changed file and its normalized status.
    enum Status: String, Codable {
        case added, modified, deleted, renamed, untracked
    }

    /// What the tree pane needs: every (non-ignored) path in the worktree plus a
    /// status badge map and the resolved diff base.
    struct Snapshot: Codable {
        /// Absolute worktree root.
        let root: String
        /// Diff base commit SHA (merge-base with the PR's base branch), if resolved.
        let base: String?
        /// All non-ignored file paths, repo-relative, sorted — includes deleted
        /// files (which aren't on disk) so they remain reviewable.
        let paths: [String]
        /// path -> status, only for files that differ from `base`/HEAD.
        let status: [String: Status]
    }

    /// What the diff pane needs for one file: the before/after text (nil when the
    /// side doesn't exist, e.g. added/deleted), plus a binary flag.
    struct FileDiff: Codable {
        let path: String
        let oldText: String?
        let newText: String?
        let binary: Bool
        let status: Status
    }

    // MARK: - Snapshot

    /// Build the tree + status snapshot for `root`. `prNumber` is used to resolve
    /// the PR's base branch via `gh`; resolution degrades gracefully to the
    /// remote's default branch and then to nil.
    static func snapshot(root: String, prNumber: Int) -> Snapshot {
        let base = resolveBase(root: root, prNumber: prNumber)
        var status = statusMap(root: root, base: base)

        // Tree = tracked ∪ untracked(non-ignored) ∪ deleted (so deletions show).
        var paths = Set<String>()
        for line in lines(of: git(["ls-files"], root)) { paths.insert(line) }
        for line in lines(of: git(["ls-files", "--others", "--exclude-standard"], root)) { paths.insert(line) }
        for (p, s) in status where s == .deleted { paths.insert(p) }

        // Drop any path no longer relevant if it slipped in empty.
        paths = paths.filter { !$0.isEmpty }

        // Untracked files that weren't already classified are `untracked`.
        for p in paths where status[p] == nil {
            if isUntracked(root: root, path: p) { status[p] = .untracked }
        }

        return Snapshot(root: root, base: base, paths: paths.sorted(), status: status)
    }

    // MARK: - Per-file diff

    /// Old/new content for one file, relative to `base`. Reads the new side from
    /// the working tree (so uncommitted edits show) and the old side from `base`.
    static func fileDiff(root: String, base: String?, path: String, status: Status) -> FileDiff {
        let newData: Data? = status == .deleted ? nil : try? Data(contentsOf: fileURL(root, path))
        let oldData: Data? = {
            guard status != .added, let base else { return nil }
            return gitData(["show", "\(base):\(path)"], root)
        }()

        let binary = isBinary(oldData) || isBinary(newData)
        return FileDiff(
            path: path,
            oldText: binary ? nil : oldData.flatMap { String(data: $0, encoding: .utf8) },
            newText: binary ? nil : newData.flatMap { String(data: $0, encoding: .utf8) },
            binary: binary,
            status: status
        )
    }

    // MARK: - Base / status resolution

    private static func resolveBase(root: String, prNumber: Int) -> String? {
        // Prefer the PR's actual base branch; fall back to the remote default.
        let branch = trimmed(gh(["pr", "view", "\(prNumber)", "--json", "baseRefName",
                                  "-q", ".baseRefName"], root))
            ?? defaultBranch(root: root)
        guard let branch, !branch.isEmpty else { return nil }
        // merge-base so we diff only the PR's own changes, not base-branch drift.
        if let mb = trimmed(git(["merge-base", "HEAD", "origin/\(branch)"], root)), !mb.isEmpty {
            return mb
        }
        return trimmed(git(["rev-parse", "origin/\(branch)"], root))
    }

    private static func defaultBranch(root: String) -> String? {
        // "origin/main" -> "main"
        guard let ref = trimmed(git(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], root))
        else { return nil }
        return ref.split(separator: "/").last.map(String.init)
    }

    private static func statusMap(root: String, base: String?) -> [String: Status] {
        var map: [String: Status] = [:]
        // Committed PR changes (base...HEAD): newline records, "<code>\t<path>".
        if let base {
            for line in lines(of: git(["diff", "--name-status", "\(base)...HEAD"], root)) {
                ingestNameStatus(line, into: &map)
            }
        }
        // Uncommitted working-tree changes (override; they're what's on disk now):
        // porcelain v1 records "XY PATH" (renames as "XY OLD -> NEW").
        for line in lines(of: git(["status", "--porcelain=v1"], root)) {
            guard line.count >= 3 else { continue }
            let code = String(line.prefix(2))
            var path = String(line.dropFirst(3))
            if let arrow = path.range(of: " -> ") { path = String(path[arrow.upperBound...]) }
            // Untracked dirs collapse to "dir/" in porcelain; the tree is built
            // from file paths (ls-files lists the files inside), so skip them.
            if path.hasSuffix("/") { continue }
            map[path] = porcelainStatus(code) ?? map[path]
        }
        return map
    }

    private static func ingestNameStatus(_ line: String, into map: inout [String: Status]) {
        // "<code>\t<path>" — renames are "R<score>\t<old>\t<new>"; take the new path.
        let parts = line.split(separator: "\t")
        guard let code = parts.first?.first, let path = parts.last.map(String.init) else { return }
        switch code {
        case "A": map[path] = .added
        case "D": map[path] = .deleted
        case "R": map[path] = .renamed
        default:  map[path] = .modified
        }
    }

    private static func porcelainStatus(_ code: String) -> Status? {
        if code.contains("?") { return .untracked }
        if code.contains("A") { return .added }
        if code.contains("D") { return .deleted }
        if code.contains("R") { return .renamed }
        if code.contains("M") { return .modified }
        return nil
    }

    private static func isUntracked(root: String, path: String) -> Bool {
        // ls-files --error-unmatch exits non-zero for untracked paths.
        run(gitPath, ["-C", root, "ls-files", "--error-unmatch", path], capturingErr: false).status != 0
    }

    // MARK: - Binary detection

    private static func isBinary(_ data: Data?) -> Bool {
        guard let data else { return false }
        if data.prefix(8000).contains(0) { return true }            // NUL byte ⇒ binary
        return String(data: data, encoding: .utf8) == nil           // not valid UTF-8 ⇒ binary
    }

    // MARK: - git / gh invocation

    /// Resolved once via a login shell so the user's PATH (Homebrew git/gh)
    /// applies under the minimal GUI launch environment.
    private static let gitPath: String = which("git") ?? "/usr/bin/git"
    private static let ghPath: String? = which("gh")

    private static func git(_ args: [String], _ cwd: String) -> Data {
        run(gitPath, ["-C", cwd] + args, capturingErr: false).out
    }

    private static func gitData(_ args: [String], _ cwd: String) -> Data? {
        let r = run(gitPath, ["-C", cwd] + args, capturingErr: false)
        return r.status == 0 ? r.out : nil
    }

    private static func gh(_ args: [String], _ cwd: String) -> Data {
        guard let ghPath else { return Data() }
        return run(ghPath, args, cwd: cwd, capturingErr: false).out
    }

    /// Resolve an executable's absolute path through a login shell.
    private static func which(_ name: String) -> String? {
        let r = run("/bin/zsh", ["-lc", "command -v \(name)"], capturingErr: false)
        return trimmed(r.out)
    }

    private static func run(_ exe: String, _ args: [String], cwd: String? = nil,
                            capturingErr: Bool) -> (status: Int32, out: Data, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let outPipe = Pipe()
        p.standardOutput = outPipe
        // Avoid a stderr pipe deadlock: discard it unless explicitly requested.
        p.standardError = capturingErr ? Pipe() : FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            return (-1, Data(), error.localizedDescription)
        }
        let out = outPipe.fileHandleForReading.readDataToEndOfFile()
        let err = (p.standardError as? Pipe).map {
            String(data: $0.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        } ?? ""
        p.waitUntilExit()
        return (p.terminationStatus, out, err)
    }

    // MARK: - Small helpers

    private static func fileURL(_ root: String, _ path: String) -> URL {
        URL(fileURLWithPath: root).appendingPathComponent(path)
    }

    private static func trimmed(_ data: Data) -> String? {
        let s = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (s?.isEmpty ?? true) ? nil : s
    }

    /// Split command output into newline-separated records.
    private static func lines(of data: Data) -> [String] {
        guard let s = String(data: data, encoding: .utf8) else { return [] }
        return s.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }
}
