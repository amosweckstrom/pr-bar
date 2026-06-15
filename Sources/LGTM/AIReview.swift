import Foundation

/// Hands a pull request off to Claude Code for a guided, one-file-at-a-time
/// review. We write a prompt to a temp file, then open Terminal and start an
/// interactive `claude` session seeded with it — the user stays in the loop and
/// drives the pace; Claude explains each change and waits before moving on.
enum AIReview {
    /// - Parameters:
    ///   - agentInvocation: command prefix (e.g. `claude`, `gemini -i`); the
    ///     prompt is appended to it as the final quoted argument.
    static func start(pr: PullRequest, terminalBundleID: String, agentInvocation: String) {
        let prompt = makePrompt(url: pr.url)
        let tmp = FileManager.default.temporaryDirectory
        let promptURL = tmp.appendingPathComponent(
            "lgtm-review-\(pr.number)-\(UUID().uuidString.prefix(8)).md")
        do {
            try prompt.write(to: promptURL, atomically: true, encoding: .utf8)
        } catch {
            NSLog("lgtm: failed to write review prompt: \(error.localizedDescription)")
            return
        }

        // Fresh working dir, then the chosen agent seeded with the prompt file's
        // contents as the first interactive message.
        let shellCmd = "cd \"$(mktemp -d)\" && \(agentInvocation) \"$(cat '\(promptURL.path)')\""
        Terminals.launch(bundleID: terminalBundleID, shellCommand: shellCmd)
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
        guard let local = repo.localPath, !local.isEmpty else { return false }

        let prompt = commentsPrompt(number: pr.number)
        let tmp = FileManager.default.temporaryDirectory
        let promptURL = tmp.appendingPathComponent(
            "lgtm-comments-\(pr.number)-\(UUID().uuidString.prefix(8)).md")
        do {
            try prompt.write(to: promptURL, atomically: true, encoding: .utf8)
        } catch {
            NSLog("lgtm: failed to write comments prompt: \(error.localizedDescription)")
            return false
        }

        // Open the PR branch in a working tree off the user's clone, then seed
        // the agent. Order matters: if the branch is ALREADY checked out
        // somewhere (the main clone or a prior worktree) we reuse that directory,
        // because git refuses to check one branch out in two worktrees. Only
        // when it's checked out nowhere do we add a dedicated worktree — that
        // keeps the main checkout's current branch untouched in the common case.
        let n = pr.number
        let slug = "\(repo.owner)-\(repo.name)"
        let wt = "$HOME/.lgtm/worktrees/\(slug)-pr-\(n)"
        // awk over `git worktree list --porcelain` to find where $BR is checked out.
        let findTree = "awk -v b=\"refs/heads/$BR\" '/^worktree /{wt=substr($0,10)} "
            + "$0==\"branch \"b{print wt; exit}'"
        let shellCmd = "cd \"\(local)\" && git fetch origin --quiet && "
            + "BR=$(gh pr view \(n) --json headRefName -q .headRefName) && "
            + "TARGET=$(git worktree list --porcelain | \(findTree)) && "
            + "if [ -z \"$TARGET\" ]; then "
            +   "TARGET=\"\(wt)\" && mkdir -p \"$HOME/.lgtm/worktrees\" && "
            +   "{ [ -d \"$TARGET\" ] || git worktree add --detach \"$TARGET\"; } && "
            +   "cd \"$TARGET\" && gh pr checkout \(n); "
            + "else echo \"[lgtm] '$BR' is already checked out at $TARGET — using it\" && cd \"$TARGET\"; fi && "
            + "\(agentInvocation) \"$(cat '\(promptURL.path)')\""
        Terminals.launch(bundleID: terminalBundleID, shellCommand: shellCmd)
        return true
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
