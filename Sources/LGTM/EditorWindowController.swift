import AppKit

/// Encodes a value to a JSON string for safe interpolation into a JS call
/// (`window.LGTM.renderTree(<json>, …)`). JSON is valid JS, so this also escapes
/// quotes/newlines in file contents. Free function so it's callable off-actor.
private func jsonString<T: Encodable>(_ value: T) -> String? {
    guard let data = try? JSONEncoder().encode(value) else { return nil }
    return String(data: data, encoding: .utf8)
}

private struct GitStatusEntry: Encodable {
    let path: String
    let status: String
}

/// Hosts the editor window's middle column: a `[Diff] [Conversation]` segmented
/// toggle over two stacked web panes (only one visible at a time). The diff pane
/// is the existing split-diff; the conversation pane is the review timeline +
/// inline-by-file roll-up. Swapping is a cheap `isHidden` flip — both panes stay
/// mounted so neither reloads or loses scroll/state when you tab away.
@MainActor
final class MiddlePaneHost: NSViewController {
    let diffPane: EditorWebPane
    let conversationPane: EditorWebPane
    /// Called with the newly selected tab index (0 = Diff, 1 = Conversation).
    var onTabChanged: ((Int) -> Void)?
    /// Called with the newly selected diff mode (0 = PR changes, 1 = Agent edits).
    var onDiffModeChanged: ((Int) -> Void)?

    private let segmented = NSSegmentedControl(labels: ["Diff", "Conversation"],
                                               trackingMode: .selectOne, target: nil, action: nil)
    /// Right-aligned sub-toggle: the PR's reviewed diff vs. the agent's session
    /// edits (blue). Only meaningful on the Diff tab, so it's hidden on Conversation.
    private let diffModeControl = NSSegmentedControl(labels: ["PR changes", "Agent edits"],
                                                     trackingMode: .selectOne, target: nil, action: nil)

    init(diffPane: EditorWebPane, conversationPane: EditorWebPane) {
        self.diffPane = diffPane
        self.conversationPane = conversationPane
        super.init(nibName: nil, bundle: nil)
        addChild(diffPane)
        addChild(conversationPane)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    /// Currently selected tab (0 = Diff, 1 = Conversation).
    var selectedTab: Int { segmented.selectedSegment }
    /// Currently selected diff mode (0 = PR changes, 1 = Agent edits).
    var selectedDiffMode: Int { diffModeControl.selectedSegment }

    override func loadView() {
        let container = NSView()

        let bar = NSView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.wantsLayer = true

        segmented.segmentStyle = .automatic
        segmented.selectedSegment = 0
        segmented.target = self
        segmented.action = #selector(tabClicked)
        segmented.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(segmented)

        diffModeControl.segmentStyle = .automatic
        diffModeControl.selectedSegment = 0
        diffModeControl.target = self
        diffModeControl.action = #selector(diffModeClicked)
        diffModeControl.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(diffModeControl)

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(separator)

        let diffView = diffPane.view
        let convView = conversationPane.view
        diffView.translatesAutoresizingMaskIntoConstraints = false
        convView.translatesAutoresizingMaskIntoConstraints = false
        convView.isHidden = true

        container.addSubview(bar)
        container.addSubview(diffView)
        container.addSubview(convView)

        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: container.topAnchor),
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: 34),

            segmented.centerXAnchor.constraint(equalTo: bar.centerXAnchor),
            segmented.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            diffModeControl.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -8),
            diffModeControl.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            separator.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),
        ])
        for v in [diffView, convView] {
            NSLayoutConstraint.activate([
                v.topAnchor.constraint(equalTo: bar.bottomAnchor),
                v.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                v.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                v.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            ])
        }
        self.view = container
    }

    /// Select a tab programmatically (e.g. jump-to-line switches back to Diff).
    func selectTab(_ index: Int) {
        guard index != segmented.selectedSegment else { return }
        segmented.selectedSegment = index
        applyVisibility()
        onTabChanged?(index)
    }

    @objc private func tabClicked() {
        applyVisibility()
        onTabChanged?(segmented.selectedSegment)
    }

    @objc private func diffModeClicked() {
        onDiffModeChanged?(diffModeControl.selectedSegment)
    }

    private func applyVisibility() {
        let conversation = segmented.selectedSegment == 1
        diffPane.view.isHidden = conversation
        conversationPane.view.isHidden = !conversation
        diffModeControl.isHidden = conversation
    }
}

/// Window subclass that routes ⌘S to a file-tree toggle regardless of which
/// subview (terminal, web panes) holds first responder: `performKeyEquivalent`
/// is sent to the key window before `keyDown` reaches the responder, so we catch
/// it here and short-circuit before the panes can swallow it.
final class EditorWindow: NSWindow {
    var onToggleTree: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "s",
           let onToggleTree {
            onToggleTree()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// The in-app "mini editor" window opened by the `</>` action: a resizable
/// 3-pane split — file tree (left), file diff + conversation (middle), terminal
/// (right) — over one PR worktree. The tree and diff are web panes
/// (`@pierre/trees` / `@pierre/diffs`); the terminal is native SwiftTerm. This
/// controller is the coordinator: it loads the worktree snapshot into the tree,
/// computes per-file diffs on selection, and fetches/polls the PR conversation,
/// placing inline threads on the diff (when the checkout matches the PR head) and
/// the full timeline in the conversation pane.
@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate {

    /// One window per worktree; reopening focuses the existing one.
    private static var open: [String: EditorWindowController] = [:]

    @discardableResult
    static func show(worktree: URL, repo: TrackedRepo, pr: PullRequest,
                     agentInvocation: String?) -> EditorWindowController {
        let key = worktree.standardizedFileURL.path
        if let existing = open[key] {
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return existing
        }
        let wc = EditorWindowController(worktree: worktree, repo: repo, pr: pr,
                                        agentInvocation: agentInvocation)
        open[key] = wc
        wc.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        wc.start()
        return wc
    }

    private let worktree: URL
    private let repo: TrackedRepo
    private let pr: PullRequest

    private let treePane: EditorWebPane
    private let diffPane: EditorWebPane
    private let conversationPane: EditorWebPane
    private let middle: MiddlePaneHost
    private let terminalPane: EditorTerminalPane
    private let split: NSSplitViewController

    private var base: String?
    private var statusMap: [String: WorktreeData.Status] = [:]
    private var renames: [String: String] = [:]      // new path -> old path
    private var knownPaths: Set<String> = []          // paths the tree actually offered
    private var worktreeHeadSHA: String?              // the worktree's live HEAD (may be ahead of the PR head if the agent committed)
    private var prHeadSHA: String?                     // the PR head to diff/anchor against — see resolvePRHeadSHA
    private var lastResolvedHeadSHA: String?           // the PR head the diff was last rendered against, to detect changes

    // MARK: Conversation state
    /// PAT for reads + reply/resolve writes; nil disables the conversation feature.
    private let token: String?
    /// Latest decoded conversation (threads merged non-destructively across polls).
    private var conversation: PRConversation?
    /// Anchor-gate result for the current conversation + worktree head.
    private var anchors = CommentAnchoring.Result(inlineByPath: [:], listOnly: [])
    /// In-flight optimistic writes, reconciled away once the server confirms.
    private var pending = ConversationReconcile.Pending.empty
    /// Threads with a focused/dirty reply box, kept intact across background polls.
    private var dirtyThreadIDs: Set<String> = []
    /// The file currently shown in the diff pane (so we can re-push its threads).
    private var currentDiffPath: String?
    /// Last inline-threads JSON pushed to the diff pane, to skip no-op re-renders.
    private var lastDiffThreadsJSON: String?
    /// Last comment-count JSON pushed to the tree, to skip no-op badge redraws.
    private var lastCountsJSON: String?
    /// True while a conversation fetch is in flight (avoid overlapping polls).
    private var fetching = false
    private var pollTimer: Timer?

    // MARK: Agent-edits state
    /// Which version pair the diff pane shows: the reviewed PR diff or the agent's
    /// session edits (blue).
    private var diffMode: DiffMode = .pr
    /// Repo-relative paths the agent has changed since the window opened (drives the
    /// tree markers + which files have a blue diff). Recomputed by the watcher.
    private var agentTouched: Set<String> = []
    /// Live worktree file watcher; nil until the head SHA is known. Torn down on close.
    private var watcher: WorktreeWatcher?

    init(worktree: URL, repo: TrackedRepo, pr: PullRequest, agentInvocation: String?) {
        self.worktree = worktree
        self.repo = repo
        self.pr = pr
        self.token = Keychain.loadToken()
        self.treePane = EditorWebPane(page: "tree.html", messageNames: ["fileSelected"])
        self.diffPane = EditorWebPane(page: "diff.html", messageNames: ["commentIntent"])
        self.conversationPane = EditorWebPane(page: "conversation.html", messageNames: ["commentIntent"])
        self.middle = MiddlePaneHost(diffPane: diffPane, conversationPane: conversationPane)
        self.terminalPane = EditorTerminalPane(workingDirectory: worktree,
                                               agentInvocation: agentInvocation)

        let split = NSSplitViewController()
        split.splitView.isVertical = true
        split.splitView.dividerStyle = .thin

        let treeItem = NSSplitViewItem(viewController: treePane)
        treeItem.minimumThickness = 170
        treeItem.canCollapse = true          // ⌘S / titlebar button toggles it
        treeItem.holdingPriority = NSLayoutConstraint.Priority(260)

        let diffItem = NSSplitViewItem(viewController: middle)
        diffItem.minimumThickness = 300
        // Lowest holding priority ⇒ the middle pane absorbs window resizing.
        diffItem.holdingPriority = NSLayoutConstraint.Priority(240)

        let termItem = NSSplitViewItem(viewController: terminalPane)
        termItem.minimumThickness = 240
        termItem.holdingPriority = NSLayoutConstraint.Priority(250)

        split.addSplitViewItem(treeItem)
        split.addSplitViewItem(diffItem)
        split.addSplitViewItem(termItem)
        self.split = split

        let window = EditorWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1240, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.contentViewController = split
        window.title = "\(repo.slug) #\(pr.number)"
        // No forced appearance: the window, its web panes, and the terminal all
        // follow the system light/dark setting (see EditorWebPane/TerminalPane).
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("LGTMEditorWindow-\(repo.slug)-\(pr.number)")
        window.center()

        super.init(window: window)
        window.delegate = self
        window.onToggleTree = { [weak self] in self?.toggleTree() }
        addTreeToggleButton(to: window)

        // File selection in the tree → render that file's diff.
        treePane.onMessage = { [weak self] name, body in
            guard name == "fileSelected", let path = body as? String else { return }
            self?.loadDiff(path: path)
        }
        // Reply / resolve / jump / dirty intents from either web pane.
        let intent: (String, Any) -> Void = { [weak self] name, body in
            guard name == "commentIntent", let dict = body as? [String: Any] else { return }
            self?.handleIntent(dict)
        }
        diffPane.onMessage = intent
        conversationPane.onMessage = intent
        // PR changes / Agent edits sub-toggle.
        middle.onDiffModeChanged = { [weak self] index in self?.setDiffMode(index) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    /// Kick off snapshotting + initial layout once the window is on screen.
    private func start() {
        applyInitialLayout()
        let root = worktree.path
        let number = pr.number
        DispatchQueue.global(qos: .userInitiated).async {
            let snap = WorktreeData.snapshot(root: root, prNumber: number)
            DispatchQueue.main.async { self.feedTree(snap) }
        }
        startConversation()
        pushSkills()
    }

    private func applyInitialLayout() {
        let total = split.splitView.bounds.width
        guard total > 400 else { return }
        split.splitView.setPosition(250, ofDividerAt: 0)              // tree width
        split.splitView.setPosition(total - 380, ofDividerAt: 1)      // terminal width ≈ 380
    }

    private func feedTree(_ snap: WorktreeData.Snapshot) {
        base = snap.base
        statusMap = snap.status
        renames = snap.renames
        knownPaths = Set(snap.paths)
        worktreeHeadSHA = snap.headSHA
        resolvePRHeadSHA()
        let entries = snap.status.map { GitStatusEntry(path: $0.key, status: $0.value.rawValue) }
        guard let pathsJSON = jsonString(snap.paths),
              let statusJSON = jsonString(entries) else { return }
        treePane.callJS("window.LGTM.renderTree(\(pathsJSON), \(statusJSON));")
        // The worktree head is now known; re-gate any conversation already loaded.
        recomputeAnchorsAndPush()
        // …and start watching for the agent's edits (needs the head SHA as baseline).
        startWatcher()
        refreshAgentTouched()
    }

    private func loadDiff(path: String) {
        // Only diff paths the snapshot actually offered — never a path the web
        // pane might post that escapes the worktree (defense-in-depth).
        guard knownPaths.contains(path) else { return }
        currentDiffPath = path
        let status = statusMap[path] ?? .modified
        let oldPath = renames[path]
        let root = worktree.path
        let mode = diffMode
        let (oldRef, newRef) = AgentDiff.refs(mode: mode, base: base, headSHA: prHeadSHA)

        // Agent mode shows only files the agent actually touched; for the rest a
        // placeholder beats rendering the whole (unchanged) file as if it were a diff.
        if mode == .agent {
            guard prHeadSHA != nil else {
                diffPlaceholder("Agent edits unavailable — couldn’t resolve the PR head commit.")
                return
            }
            guard agentTouched.contains(path) else {
                diffPlaceholder("No agent edits to this file yet.")
                return
            }
        }

        // Inline threads anchor to the reviewed (PR) lines; the agent view renumbers
        // them, so threads are only placed in PR mode.
        let threadsJSON = (mode == .pr ? jsonString(inlineThreads(forPath: path)) : "[]") ?? "[]"
        if mode == .pr { lastDiffThreadsJSON = threadsJSON }

        DispatchQueue.global(qos: .userInitiated).async {
            let fd = WorktreeData.fileDiff(root: root, oldRef: oldRef, newRef: newRef,
                                           path: path, status: status, oldPath: oldPath)
            guard let json = jsonString(fd) else { return }
            DispatchQueue.main.async {
                self.diffPane.callJS("window.LGTM.renderDiff(\(json), \(threadsJSON), '\(mode.rawValue)');")
            }
        }
    }

    /// Switch between the reviewed PR diff (green/red) and the agent's edits (blue),
    /// re-rendering the current file in the new mode.
    private func setDiffMode(_ index: Int) {
        let mode: DiffMode = index == 1 ? .agent : .pr
        guard mode != diffMode else { return }
        diffMode = mode
        // Force the next PR-mode render to re-push threads (cleared while in agent mode).
        lastDiffThreadsJSON = nil
        if let path = currentDiffPath {
            loadDiff(path: path)
        } else {
            diffPlaceholder(mode == .agent ? "Select a file to see the agent’s edits"
                                           : "Select a file to view its diff")
        }
    }

    private func diffPlaceholder(_ message: String) {
        guard let json = jsonString(message) else { return }
        diffPane.callJS("window.LGTM.showPlaceholder(\(json));")
    }

    // MARK: - Agent edits (file watcher)

    private func startWatcher() {
        guard watcher == nil, prHeadSHA != nil else { return }
        let w = WorktreeWatcher(root: worktree) { [weak self] in self?.refreshAgentTouched() }
        w.start()
        watcher = w
    }

    /// Recompute (off-main) the set of files the agent has changed since open, then
    /// push the tree markers and, if the agent view is showing, refresh the diff.
    private func refreshAgentTouched() {
        guard let sinceSHA = prHeadSHA else { return }
        let root = worktree.path
        DispatchQueue.global(qos: .userInitiated).async {
            let touched = WorktreeData.agentTouchedPaths(root: root, sinceSHA: sinceSHA)
            DispatchQueue.main.async { self.applyAgentTouched(touched) }
        }
    }

    private func applyAgentTouched(_ touched: [String]) {
        let set = Set(touched)
        let changed = set != agentTouched
        agentTouched = set
        if changed, let json = jsonString(touched) {
            treePane.callJS("window.LGTM.setAgentEdits(\(json));")
        }
        // Keep the blue diff live while the user watches it.
        if diffMode == .agent, let path = currentDiffPath { loadDiff(path: path) }
    }

    /// Push the installed skill library (seeding the default on first use) to both
    /// comment surfaces, so each comment's "Fix with AI" button can offer them.
    private func pushSkills() {
        SkillStore.ensureSeeded()
        let skills = SkillStore.list().map { ["id": $0.id, "name": $0.name] }
        guard let json = jsonString(skills) else { return }
        let js = "window.LGTM.setSkills(\(json));"
        diffPane.callJS(js)
        conversationPane.callJS(js)
    }

    // MARK: - Conversation: fetch + poll

    private func startConversation() {
        guard token != nil else {
            conversationPane.callJS(renderConversationJS(.error(
                "No GitHub token set. Add one in Settings to see PR comments.")))
            return
        }
        conversationPane.callJS(renderConversationJS(.loading()))
        refreshConversation(initial: true)
        // Background poll so others' new comments surface while the window is open.
        let timer = Timer(timeInterval: 45, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshConversation(initial: false) }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    /// Fetch the conversation and fold it into local state. `initial` distinguishes
    /// the first load (replace) from a poll/post-write refresh (non-destructive
    /// merge over what's on screen).
    private func refreshConversation(initial: Bool) {
        guard let token, !fetching else { return }
        fetching = true
        let client = GitHubClient(token: token)
        let owner = repo.owner, name = repo.name, number = pr.number
        Task { @MainActor in
            defer { self.fetching = false }
            do {
                let fresh = try await client.conversation(owner: owner, name: name, number: number)
                self.applyFresh(fresh, initial: initial)
            } catch {
                // Keep whatever's on screen on a poll failure; only surface the
                // error when we have nothing to show yet.
                if self.conversation == nil {
                    self.conversationPane.callJS(self.renderConversationJS(
                        .error(error.localizedDescription)))
                }
            }
        }
    }

    /// Merge a freshly fetched conversation over current state (preserving dirty
    /// threads and in-flight optimistic writes), then re-gate and push.
    private func applyFresh(_ fresh: PRConversation, initial: Bool) {
        let mergedThreads: [ReviewThread]
        if let previous = conversation, !initial {
            mergedThreads = ConversationReconcile.merge(
                previous: previous.threads, fresh: fresh.threads,
                pending: pending, dirtyThreadIDs: dirtyThreadIDs)
        } else {
            mergedThreads = fresh.threads
        }
        conversation = PRConversation(
            headRefOid: fresh.headRefOid, threads: mergedThreads,
            reviews: fresh.reviews, conversation: fresh.conversation)
        recomputeAnchorsAndPush()
    }

    /// Resolve the PR head to diff and anchor comments against: the GitHub head OID
    /// when that commit is present locally (it's an ancestor of the worktree HEAD,
    /// even after the agent commits a fix on top), else the worktree's own HEAD as a
    /// fallback. Using the GitHub head keeps the green PR diff = base→PR-head and
    /// inline comments anchored regardless of the agent's local commits — those show
    /// in the blue "Agent edits" view (PR-head → working tree) instead.
    private func resolvePRHeadSHA() {
        if let oid = conversation?.headRefOid,
           WorktreeData.commitExists(root: worktree.path, oid: oid) {
            prHeadSHA = oid
        } else {
            prHeadSHA = worktreeHeadSHA
        }
    }

    /// Recompute the anchor gate from the current conversation + PR head and push the
    /// result to all three panes (diff annotations, conversation payload, tree badges).
    private func recomputeAnchorsAndPush() {
        guard let conversation else { return }
        // The conversation may have just told us the real PR head, which differs from
        // the worktree HEAD when the agent has committed a fix on top — resolve before
        // anchoring so comments gate against base→PR-head, not base→agent-commit.
        resolvePRHeadSHA()
        anchors = CommentAnchoring.resolve(
            threads: conversation.threads,
            prHeadOid: conversation.headRefOid,
            worktreeHeadSHA: prHeadSHA)

        let headMatches = conversation.headRefOid != nil
            && conversation.headRefOid == prHeadSHA

        // When the resolved PR head changes (typically: the conversation loads after
        // the diff first rendered against the worktree HEAD), re-render so green stays
        // base→PR-head and the agent's commit moves to the blue view, and recompute the
        // agent-touched set off the corrected baseline.
        if prHeadSHA != lastResolvedHeadSHA {
            lastResolvedHeadSHA = prHeadSHA
            refreshAgentTouched()
            if let path = currentDiffPath { loadDiff(path: path) }
        }

        let inlineIDs = Set(anchors.inlineByPath.values.flatMap { $0.map(\.threadID) })
        let payload = ConversationPayload.loaded(conversation,
                                                 inlineThreadIDs: inlineIDs,
                                                 headMatches: headMatches)
        conversationPane.callJS(renderConversationJS(payload))

        // Inline threads for the file currently in the diff pane — only re-pushed
        // when they actually change, so a background poll doesn't re-highlight the
        // diff under the user every interval. Skipped in agent mode (the blue diff
        // carries no anchored threads).
        if diffMode == .pr,
           let path = currentDiffPath, let threadsJSON = jsonString(inlineThreads(forPath: path)),
           threadsJSON != lastDiffThreadsJSON {
            lastDiffThreadsJSON = threadsJSON
            diffPane.callJS("window.LGTM.setThreads(\(threadsJSON));")
        }

        // Per-file feedback counts for the tree badges (all threads, anchored or
        // not), again only when changed.
        let counts = Dictionary(grouping: conversation.threads, by: \.path).mapValues { $0.count }
        if let countsJSON = jsonString(counts), countsJSON != lastCountsJSON {
            lastCountsJSON = countsJSON
            treePane.callJS("window.LGTM.setCommentCounts(\(countsJSON));")
        }
    }

    /// The gated-inline threads for one file, as bridge DTOs for the diff pane.
    private func inlineThreads(forPath path: String) -> [ThreadBridge] {
        guard let conversation else { return [] }
        let ids = Set((anchors.inlineByPath[path] ?? []).map(\.threadID))
        return conversation.threads.filter { ids.contains($0.id) }.map(ThreadBridge.init)
    }

    private func renderConversationJS(_ payload: ConversationPayload) -> String {
        guard let json = jsonString(payload) else { return "" }
        return "window.LGTM.renderConversation(\(json));"
    }

    // MARK: - Conversation: write intents (optimistic + rollback)

    private func handleIntent(_ dict: [String: Any]) {
        guard let action = dict["action"] as? String else { return }
        let threadID = dict["threadId"] as? String
        switch action {
        case "reply":
            if let threadID, let body = dict["body"] as? String, !body.isEmpty {
                reply(threadID: threadID, body: body)
            }
        case "resolve", "unresolve":
            if let threadID { setResolved(threadID: threadID, resolved: action == "resolve") }
        case "jump":
            if let threadID { jump(toThread: threadID, path: dict["path"] as? String) }
        case "dirty":
            if let threadID {
                if dict["dirty"] as? Bool == true { dirtyThreadIDs.insert(threadID) }
                else { dirtyThreadIDs.remove(threadID) }
            }
        case "fixWithAI":
            if let threadID, let commentID = dict["commentId"] as? String {
                fixWithAI(threadID: threadID, commentID: commentID, skillID: dict["skillId"] as? String)
            }
        default:
            break
        }
    }

    /// Render the chosen skill against one comment and inject it into the running
    /// agent in the terminal pane. The skill instructs the agent to analyze and
    /// wait, so auto-submitting keeps the user in control at the agent level.
    private func fixWithAI(threadID: String, commentID: String, skillID: String?) {
        guard let conversation,
              let thread = conversation.threads.first(where: { $0.id == threadID }),
              let comment = thread.comments.first(where: { $0.id == commentID })
                ?? thread.comments.first
        else { return }

        let skills = SkillStore.list()
        guard let skill = skillID.flatMap({ id in skills.first { $0.id == id } }) ?? skills.first else {
            NSLog("lgtm: Fix with AI invoked but no skills are installed")
            return
        }

        let line = thread.line ?? thread.originalLine
        let context = CommentContext(
            comment: Self.htmlToText(comment.bodyHTML),
            file: thread.path,
            line: line.map(String.init) ?? "",
            author: comment.author,
            pr: String(pr.number))
        terminalPane.sendToAgent(SkillPrompt.render(body: skill.body, context: context))
    }

    /// Crude HTML→text for the prompt context: GitHub's server-rendered comment
    /// body to readable plain text (block tags → newlines, strip the rest, decode
    /// the handful of entities it emits).
    static func htmlToText(_ html: String) -> String {
        var s = html
        s = s.replacingOccurrences(of: "(?i)</(p|div|li|h[1-6]|blockquote|tr)>",
                                   with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?i)<br\\s*/?>", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
                        "&#39;": "'", "&nbsp;": " "]
        for (k, v) in entities { s = s.replacingOccurrences(of: k, with: v) }
        s = s.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func reply(threadID: String, body: String) {
        guard let token else { return }
        // Optimistic: show the reply immediately with a temporary id.
        let tempID = "optimistic-\(UUID().uuidString)"
        let optimistic = ReviewComment(id: tempID, author: "you", authorAvatarURL: nil,
                                       bodyHTML: escapedParagraph(body), createdAt: Date())
        pending.replies[threadID, default: []].append(optimistic)
        mutateThread(threadID) { thread in
            thread.with(comments: thread.comments + [optimistic])
        }
        recomputeAnchorsAndPush()

        let client = GitHubClient(token: token)
        Task { @MainActor in
            do {
                let real = try await client.replyToThread(threadID: threadID, body: body)
                // Swap the optimistic comment for the server one, drop the pending entry.
                self.pending.replies[threadID]?.removeAll { $0.id == tempID }
                if self.pending.replies[threadID]?.isEmpty == true { self.pending.replies[threadID] = nil }
                self.mutateThread(threadID) { thread in
                    let kept = thread.comments.filter { $0.id != tempID && $0.id != real.id }
                    return thread.with(comments: kept + [real])
                }
                self.dirtyThreadIDs.remove(threadID)
                self.recomputeAnchorsAndPush()
                self.refreshConversation(initial: false)   // catch concurrent changes
            } catch {
                // Roll back the optimistic comment and surface why.
                self.pending.replies[threadID]?.removeAll { $0.id == tempID }
                if self.pending.replies[threadID]?.isEmpty == true { self.pending.replies[threadID] = nil }
                self.mutateThread(threadID) { thread in
                    thread.with(comments: thread.comments.filter { $0.id != tempID })
                }
                self.recomputeAnchorsAndPush()
                self.postCommentError(threadID: threadID, error: error)
            }
        }
    }

    private func setResolved(threadID: String, resolved: Bool) {
        guard let token else { return }
        let previous = conversation?.threads.first { $0.id == threadID }?.isResolved ?? false
        pending.resolved[threadID] = resolved
        mutateThread(threadID) { $0.with(isResolved: resolved) }
        recomputeAnchorsAndPush()

        let client = GitHubClient(token: token)
        Task { @MainActor in
            do {
                let confirmed = try await client.setThreadResolved(threadID: threadID, resolved: resolved)
                self.pending.resolved[threadID] = nil
                self.mutateThread(threadID) { $0.with(isResolved: confirmed) }
                self.recomputeAnchorsAndPush()
            } catch {
                self.pending.resolved[threadID] = nil
                self.mutateThread(threadID) { $0.with(isResolved: previous) }
                self.recomputeAnchorsAndPush()
                self.postCommentError(threadID: threadID, error: error)
            }
        }
    }

    /// Switch to the Diff tab, select the file in the tree, and scroll the diff to
    /// the thread once its file has rendered.
    private func jump(toThread threadID: String, path: String?) {
        middle.selectTab(0)
        guard let path, knownPaths.contains(path) else { return }
        if currentDiffPath != path {
            loadDiff(path: path)
        }
        // Defer the scroll so the (possibly fresh) diff render lands first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.diffPane.callJS("window.LGTM.scrollToThread('\(threadID)');")
        }
    }

    /// Apply an in-place edit to one thread in the current conversation.
    private func mutateThread(_ threadID: String, _ transform: (ReviewThread) -> ReviewThread) {
        guard var convo = conversation else { return }
        var threads = convo.threads
        if let i = threads.firstIndex(where: { $0.id == threadID }) {
            threads[i] = transform(threads[i])
            convo = PRConversation(headRefOid: convo.headRefOid, threads: threads,
                                   reviews: convo.reviews, conversation: convo.conversation)
            conversation = convo
        }
    }

    private func postCommentError(threadID: String, error: Error) {
        let message = Self.writeErrorMessage(error)
        let payload = ["message": message]
        guard let json = jsonString(payload) else { return }
        let js = "window.LGTM.commentError('\(threadID)', \(json));"
        diffPane.callJS(js)
        conversationPane.callJS(js)
    }

    /// Friendly message for a failed write, calling out the most common cause —
    /// a read-only token — when the error looks like a permission rejection.
    static func writeErrorMessage(_ error: Error) -> String {
        let raw = error.localizedDescription
        let lower = raw.lowercased()
        if lower.contains("forbidden") || lower.contains("not accessible")
            || lower.contains("permission") || lower.contains("scope")
            || lower.contains("401") || lower.contains("403") {
            return "Couldn’t save — your GitHub token needs write access to reply or resolve. "
                + "Update it in Settings. (\(raw))"
        }
        return "Couldn’t save: \(raw)"
    }

    /// Wrap a plain-text optimistic reply as minimal sanitized HTML (the server
    /// echo later replaces it with real `bodyHTML`).
    private func escapedParagraph(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\n", with: "<br>")
        return "<p>\(escaped)</p>"
    }

    // MARK: - File-tree collapse

    /// Collapse or expand the left file-tree pane. Driven by ⌘S (via
    /// `EditorWindow`) and the leading titlebar button; the middle pane (lowest
    /// holding priority) absorbs the freed/returned width.
    @objc private func toggleTree() {
        guard let treeItem = split.splitViewItems.first else { return }
        treeItem.animator().isCollapsed = !treeItem.isCollapsed
    }

    /// Adds a leading titlebar button (sidebar glyph) that toggles the file-tree
    /// pane, mirroring the ⌘S shortcut.
    private func addTreeToggleButton(to window: NSWindow) {
        let button = NSButton(
            image: NSImage(systemSymbolName: "sidebar.left",
                           accessibilityDescription: "Toggle file tree") ?? NSImage(),
            target: self, action: #selector(toggleTree))
        button.isBordered = false
        button.bezelStyle = .texturedRounded
        button.imagePosition = .imageOnly
        button.toolTip = "Toggle file tree (⌘S)"
        button.frame = NSRect(x: 8, y: 3, width: 28, height: 22)

        let host = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 28))
        host.addSubview(button)

        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = host
        accessory.layoutAttribute = .leading
        window.addTitlebarAccessoryViewController(accessory)
    }

    // MARK: NSWindowDelegate
    func windowWillClose(_ notification: Notification) {
        pollTimer?.invalidate()
        pollTimer = nil
        watcher?.stop()
        watcher = nil
        terminalPane.terminate()
        Self.open[worktree.standardizedFileURL.path] = nil
    }
}

private extension ReviewThread {
    /// A copy of this thread with a different comment list (the struct is
    /// otherwise immutable).
    func with(comments: [ReviewComment]) -> ReviewThread {
        ReviewThread(
            id: id, path: path, line: line, originalLine: originalLine, startLine: startLine,
            side: side, isResolved: isResolved, isOutdated: isOutdated,
            subject: subject, comments: comments)
    }

    /// A copy of this thread with a different resolved state.
    func with(isResolved: Bool) -> ReviewThread {
        ReviewThread(
            id: id, path: path, line: line, originalLine: originalLine, startLine: startLine,
            side: side, isResolved: isResolved, isOutdated: isOutdated,
            subject: subject, comments: comments)
    }
}
