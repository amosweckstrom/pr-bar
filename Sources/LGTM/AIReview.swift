import AppKit
import Foundation

/// Hands a pull request off to Claude Code for a guided, one-file-at-a-time
/// review. We write a prompt to a temp file, then open Terminal and start an
/// interactive `claude` session seeded with it — the user stays in the loop and
/// drives the pace; Claude explains each change and waits before moving on.
enum AIReview {
    /// Hands a PR off to the agent for a guided, one-file-at-a-time review. When a
    /// local clone is configured it runs in the PR's git worktree (real
    /// checked-out code, same worktree the `</>` action uses); otherwise it still
    /// launches in a scratch dir — the review prompt drives `gh pr view/diff <url>`
    /// with full URLs, which needs no clone. So "Review with AI" works on any PR.
    /// - Parameters:
    ///   - agentInvocation: command prefix (e.g. `claude`, `gemini -i`); the
    ///     prompt is appended to it as the final quoted argument.
    /// - Returns: false only if the prompt file could not be written.
    @discardableResult
    static func start(pr: PullRequest, repo: TrackedRepo,
                      terminalBundleID: String, agentInvocation: String) -> Bool {
        guard let promptURL = writePrompt(makePrompt(url: pr.url), kind: "review", number: pr.number) else {
            return false
        }
        // Worktree (richer) when a clone is set; scratch dir otherwise.
        let prefix = usableLocalPath(for: repo)
            .map { worktreeShellRead(pr: pr, repo: repo, local: $0) }
            ?? scratchShell()
        let shellCmd = prefix + " && \(agentInvocation) \"$(cat '\(promptURL.path)')\""
        Terminals.launch(bundleID: terminalBundleID, shellCommand: shellCmd)
        return true
    }

    /// Hands one of the user's OWN pull requests — one a reviewer has responded
    /// to — off to the agent to address the review comments one at a time. Opens
    /// a git worktree off the user's existing local clone (`repo.localPath`) for
    /// the PR branch, so the agent gets a real working tree to edit and commit in
    /// without disturbing the main checkout. The prompt is self-contained (baked
    /// into the app), so this works with any agent and needs no external skill.
    /// - Returns: false if no local path is configured for the repo (nothing launched).
    @discardableResult
    static func startComments(pr: PullRequest, repo: TrackedRepo,
                              terminalBundleID: String, agentInvocation: String) -> Bool {
        guard let local = usableLocalPath(for: repo) else { return false }
        guard let promptURL = writePrompt(commentsPrompt(number: pr.number),
                                          kind: "comments", number: pr.number) else {
            return false
        }
        // Branch-mode worktree: the agent commits and the user pushes to update the PR.
        let shellCmd = worktreeShellWrite(pr: pr, repo: repo, local: local)
            + " && \(agentInvocation) \"$(cat '\(promptURL.path)')\""
        Terminals.launch(bundleID: terminalBundleID, shellCommand: shellCmd)
        return true
    }

    /// Single launchability predicate for the worktree-backed actions: the
    /// repo's configured local clone path, trimmed, or nil when none is set.
    /// `startComments` and `openInAppEditor` return false exactly when this is nil
    /// (nothing launched), so the UI can prompt the user to set a path.
    private static func usableLocalPath(for repo: TrackedRepo) -> String? {
        guard let trimmed = repo.localPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// Conventional path of the dedicated worktree LGTM creates for a PR:
    /// `~/.lgtm/worktrees/<owner>-<name>-pr-<number>`. The branch may instead be
    /// checked out in the main clone or a prior worktree — `ensureWorktreeShell`
    /// resolves that at launch; this is only the default creation location.
    static func worktreeURL(pr: PullRequest, repo: TrackedRepo) -> URL {
        Worktrees.path(for: pr, in: repo)
    }

    /// Opens the PR's worktree in LGTM's own 3-pane editor window (tree + diff +
    /// terminal). Ensures the worktree exists first — fast path if the
    /// conventional dir is already there, otherwise resolves/creates it headlessly
    /// (no terminal) and opens the window on the resolved `$TARGET`. Failures
    /// surface as an alert.
    /// - Returns: false if no local clone path is configured for the repo.
    @MainActor
    @discardableResult
    static func openInAppEditor(pr: PullRequest, repo: TrackedRepo) -> Bool {
        guard let local = usableLocalPath(for: repo) else { return false }

        let existing = worktreeURL(pr: pr, repo: repo)
        if FileManager.default.fileExists(atPath: existing.path) {
            EditorWindowController.show(worktree: existing, repo: repo, pr: pr)
            return true
        }

        // Resolve/create the worktree headlessly; the shell prints the resolved
        // path on a marker line so we can open the window on exactly that dir.
        let shellCmd = worktreeShellRead(pr: pr, repo: repo, local: local)
            + " && printf '\\n__LGTM_TARGET__%s\\n' \"$TARGET\""
        runHeadlessResolvingTarget(shellCmd,
                                   failureContext: "open the worktree for PR #\(pr.number)") { target in
            guard let target else { return }   // failure already alerted
            EditorWindowController.show(worktree: URL(fileURLWithPath: target), repo: repo, pr: pr)
        }
        return true
    }

    /// Like `runHeadless`, but parses the trailing `__LGTM_TARGET__<path>` marker
    /// from stdout and hands the resolved worktree path back on the main actor
    /// (nil on failure, after alerting).
    private static func runHeadlessResolvingTarget(
        _ shellCommand: String, failureContext: String,
        completion: @escaping @MainActor (String?) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
            proc.arguments = ["-lc", shellCommand]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe
            do {
                try proc.run()
            } catch {
                presentFailure(context: failureContext, detail: error.localizedDescription)
                Task { @MainActor in completion(nil) }
                return
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            let output = String(data: data, encoding: .utf8) ?? ""
            if proc.terminationStatus != 0 {
                presentFailure(context: failureContext, detail: output)
                Task { @MainActor in completion(nil) }
                return
            }
            let marker = "__LGTM_TARGET__"
            let target = output.split(separator: "\n")
                .last(where: { $0.hasPrefix(marker) })
                .map { String($0.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces) }
            Task { @MainActor in completion(target) }
        }
    }

    private static func presentFailure(context: String, detail: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "LGTM couldn’t \(context)."
            let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            alert.informativeText = trimmed.isEmpty
                ? "The worktree command failed. Check that git and gh are installed and authenticated, and that the repo's local path is correct."
                : String(trimmed.suffix(1500))
            alert.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    /// READ path (open editor / guided review): leaves the shell in a DETACHED
    /// worktree at the PR's head commit, in the PR-number-keyed conventional dir,
    /// with `$TARGET` set to its path. Detaching — rather than checking the branch
    /// out by name — means it can never collide with the main clone or another
    /// fork's same-named branch (the bug where a fork PR whose head branch is
    /// `main` got reviewed against your own `main` checkout). `pull/<n>/head`
    /// fetches the head even from forks. If the conventional dir already exists
    /// (e.g. a prior write session left a branch there) it's reused as-is.
    /// Callers append `&& <action>`.
    private static func worktreeShellRead(pr: PullRequest, repo: TrackedRepo,
                                          local: String) -> String {
        let n = pr.number
        let wt = Worktrees.shellPath(for: pr, in: repo)
        // Only the targeted pull/<n>/head fetch runs, and only when creating the
        // worktree — NOT a full `git fetch origin` first. The detached worktree is
        // built from that fetch's FETCH_HEAD, so an all-refs fetch buys nothing
        // here but a second ~1.5s network round-trip before the window can open.
        // The diff base (merge-base HEAD origin/<base> in WorktreeData) is stable
        // under a slightly-stale origin/<base> — the PR's fork point is an old
        // commit already present locally — so skipping it doesn't shift the base.
        return "cd \"\(local)\" && "
            + "TARGET=\"\(wt)\" && mkdir -p \"\(Worktrees.rootShell)\" && "
            + "if [ ! -d \"$TARGET\" ]; then "
            +   "git fetch origin \"pull/\(n)/head\" --quiet && "
            +   "git worktree add --detach \"$TARGET\" FETCH_HEAD; "
            + "fi && cd \"$TARGET\" && "
            + hookSnippet(for: repo)
    }

    /// WRITE path (address comments): leaves the shell in a worktree with the PR's
    /// BRANCH checked out, so the agent can commit and the user can push to update
    /// the PR. If the branch is ALREADY checked out somewhere (the main clone or a
    /// prior worktree) we reuse that directory — git refuses one branch in two
    /// worktrees — otherwise we add a dedicated worktree and `gh pr checkout`.
    /// Callers append `&& <action>`.
    private static func worktreeShellWrite(pr: PullRequest, repo: TrackedRepo,
                                           local: String) -> String {
        let n = pr.number
        let wt = Worktrees.shellPath(for: pr, in: repo)
        // awk over `git worktree list --porcelain` to find where $BR is checked out.
        let findTree = "awk -v b=\"refs/heads/$BR\" '/^worktree /{wt=substr($0,10)} "
            + "$0==\"branch \"b{print wt; exit}'"
        return "cd \"\(local)\" && git fetch origin --quiet && "
            + "BR=$(gh pr view \(n) --json headRefName -q .headRefName) && "
            + "TARGET=$(git worktree list --porcelain | \(findTree)) && "
            + "if [ -z \"$TARGET\" ]; then "
            +   "TARGET=\"\(wt)\" && mkdir -p \"\(Worktrees.rootShell)\" && "
            +   "{ [ -d \"$TARGET\" ] || git worktree add --detach \"$TARGET\"; } && "
            +   "cd \"$TARGET\" && gh pr checkout \(n); "
            + "else echo \"[lgtm] '$BR' is already checked out at $TARGET — using it\" && cd \"$TARGET\"; fi && "
            + hookSnippet(for: repo)
    }

    /// Neutral working dir for the clone-less review fallback: the agent reviews
    /// via `gh pr view/diff <url>` (full URLs), so cwd only needs to exist and not
    /// sit inside an unrelated git repo.
    private static func scratchShell() -> String {
        "mkdir -p \"$HOME/.lgtm/scratch\" && cd \"$HOME/.lgtm/scratch\""
    }

    /// Runs a machine-local, per-repo setup hook if one exists (e.g. symlink env
    /// files, install deps). Non-fatal: a failing or missing hook must never block
    /// the action. Both worktree paths end with this, with `$TARGET` already set.
    private static func hookSnippet(for repo: TrackedRepo) -> String {
        "{ HOOK=\"$HOME/.lgtm/hooks/\(Worktrees.slug(for: repo)).sh\"; [ -x \"$HOOK\" ] && "
            + "echo \"[lgtm] running setup hook $HOOK\" && \"$HOOK\" \"$TARGET\"; true; }"
    }

    /// Writes a prompt to a managed file under `~/.lgtm/prompts`, first pruning any
    /// prompt files older than a day (the terminal `cat`s the file asynchronously,
    /// so we can't delete it the moment we launch). Returns the file URL, or nil on
    /// write failure. Replaces the old scheme that leaked files into the temp dir.
    private static func writePrompt(_ text: String, kind: String, number: Int) -> URL? {
        let fm = FileManager.default
        let dir = fm.homeDirectoryForCurrentUser.appendingPathComponent(".lgtm/prompts")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) {
            let cutoff = Date().addingTimeInterval(-86_400)
            for url in entries where (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate).flatMap({ $0 < cutoff }) ?? false {
                try? fm.removeItem(at: url)
            }
        }
        let url = dir.appendingPathComponent("lgtm-\(kind)-\(number)-\(UUID().uuidString.prefix(8)).md")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            NSLog("lgtm: failed to write \(kind) prompt: \(error.localizedDescription)")
            return nil
        }
    }

    /// Self-contained prompt for the guided, one-at-a-time comment walkthrough.
    /// Baked into the app (no external skill) so it works with any agent. Scopes
    /// to the current review round by default — the comments left after my last
    /// re-request — while letting me widen to all of them on request.
    private static func commentsPrompt(number: Int) -> String {
        """
        I want to address the review comments on GitHub pull request #\(number) together, \
        ONE AT A TIME. I'm already in a working tree with this PR's branch checked out. \
        The most important thing: I stay in control — you make a change only after I say so.

        Step 1 — Work out which comments to address (current review round only).
        By default, only handle the comments from the LATEST review round: the ones left after \
        I most recently re-requested review. Don't re-surface comments from earlier rounds I've \
        already dealt with.
        - Find the cutoff — the time of my most recent review (re-)request: \
        `gh api "repos/{owner}/{repo}/issues/\(number)/timeline" --paginate -q '[.[] | select(.event=="review_requested") | .created_at] | last'`. \
        Call this CUTOFF. If it's empty (no review was ever requested), there is no cutoff — \
        consider all comments.
        - Fetch the comments: `gh pr view \(number) --json reviews,comments` and \
        `gh api repos/{owner}/{repo}/pulls/\(number)/comments --paginate`.
        - Build the ordered list: include a comment only if it is NOT resolved/outdated AND \
        (CUTOFF is empty OR its `created_at` >= CUTOFF). Do NOT silently drop the rest — tell me \
        how many older/resolved comments you're skipping, e.g. "Focusing on 6 comments from the \
        latest round (since your re-request on <date>); skipping 21 older/resolved — say 'include \
        older' to widen." If I say "include older" / "all comments", widen to every unresolved comment.

        Step 2 — For EACH comment, present it like this, then STOP and wait:
        **Comment N of M** — by @author on `path/to/file:line`
        > the actual comment text
        **What they're saying:** 1-2 sentence plain-English explanation.
        **The actual problem (or not):** look at the code at that location; say whether the \
        concern is valid, partly valid, or invalid, and why.
        **Options:** A — Fix it: [the concrete change]. B — Push back: [draft reply explaining \
        why no change is needed].
        Then ask: fix / reply / skip / show me the code first? Do not move on until I decide.

        Step 3 — Execute my choice:
        - fix: make the edit, run relevant tests/lint if available, show me the diff, then \
        `git commit` with a clear message. Do NOT push.
        - reply: post via `gh api repos/{owner}/{repo}/pulls/comments/<comment_id>/replies` and confirm.
        - skip: note it and move on.

        Step 4 — At the end: summarise N fixed (with commit SHAs), N replied to, N skipped, and \
        remind me to push when ready.

        Rules: one comment at a time, never batch; always wait for my decision; never push unless \
        I explicitly ask; if a comment refers to code already changed in a later commit, flag that.

        Begin with Step 1 now: compute the cutoff, build the scoped list, tell me the count, then \
        present the first comment.
        """
    }

    private static func makePrompt(url: String) -> String {
        """
        I want to review GitHub pull request \(url) together with you, going through it \
        one piece at a time. The most important thing: I need to genuinely understand this \
        PR myself. Do NOT review it on your own or jump to a verdict — we do this \
        collaboratively, and I stay in control of the pace.

        Please work like this:

        1. Load the PR: run `gh pr view \(url)` and `gh pr diff \(url)` to read the \
        description and the full diff.
        2. Give me a short, plain-English overview: what this PR is trying to accomplish, \
        and where the risk or the tricky parts are.
        3. Then walk me through the changes ONE FILE AT A TIME (split large files into \
        smaller hunks). For each one:
           - Explain what changed and why, in plain language.
           - Flag anything I should scrutinise, and label each finding with a confidence \
        level (high / medium / low) and a severity (blocker / major / minor / nit) so I can \
        tell the real issues from the nitpicks. Cover likely bugs, edge cases, unclear \
        intent, performance concerns, and missing tests.
           - If the change touches anything security-sensitive — authentication, \
        authorisation, secrets or credentials, payment or money handling, user input \
        parsing, or newly added external/third-party dependencies — call it out clearly as \
        "VERIFY YOURSELF" and tell me exactly what to check. Do not let me wave these \
        through on your say-so; this is where AI review is least reliable.
           - Then STOP and wait for me. Do not move on to the next file until I tell you to \
        continue.
        4. Let me interrupt and ask questions at any point. If I don't follow something, \
        explain it more simply or show me the relevant code.
        5. Before we settle on a verdict, ask me to explain the gist of this PR back to you \
        in my own words — what it does and why. If my explanation has gaps or gets something \
        wrong, point that out and clear it up before moving on. I should not approve a change \
        I can't explain.
        6. Then help me decide on a verdict (approve / request changes / comment). Only if I \
        explicitly confirm, help me post it with `gh pr review`.

        Begin with steps 1 and 2 now, then pause and wait for me before the first file.
        """
    }
}
