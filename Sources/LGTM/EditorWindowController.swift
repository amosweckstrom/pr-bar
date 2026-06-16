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

/// The in-app "mini editor" window opened by the `</>` action: a resizable
/// 3-pane split — file tree (left), file diff (middle), terminal (right) — over
/// one PR worktree. The tree and diff are web panes (`@pierre/trees` /
/// `@pierre/diffs`); the terminal is native SwiftTerm. This controller is also
/// the coordinator: it loads the worktree snapshot into the tree and, on file
/// selection, computes and pushes that file's diff.
@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate {

    /// One window per worktree; reopening focuses the existing one.
    private static var open: [String: EditorWindowController] = [:]

    @discardableResult
    static func show(worktree: URL, repo: TrackedRepo, pr: PullRequest) -> EditorWindowController {
        let key = worktree.standardizedFileURL.path
        if let existing = open[key] {
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return existing
        }
        let wc = EditorWindowController(worktree: worktree, repo: repo, pr: pr)
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
    private let terminalPane: EditorTerminalPane
    private let split: NSSplitViewController

    private var base: String?
    private var statusMap: [String: WorktreeData.Status] = [:]

    init(worktree: URL, repo: TrackedRepo, pr: PullRequest) {
        self.worktree = worktree
        self.repo = repo
        self.pr = pr
        self.treePane = EditorWebPane(page: "tree.html", messageNames: ["fileSelected"])
        self.diffPane = EditorWebPane(page: "diff.html", messageNames: [])
        self.terminalPane = EditorTerminalPane(workingDirectory: worktree)

        let split = NSSplitViewController()
        split.splitView.isVertical = true
        split.splitView.dividerStyle = .thin

        let treeItem = NSSplitViewItem(viewController: treePane)
        treeItem.minimumThickness = 170
        treeItem.holdingPriority = NSLayoutConstraint.Priority(260)

        let diffItem = NSSplitViewItem(viewController: diffPane)
        diffItem.minimumThickness = 300
        // Lowest holding priority ⇒ the diff pane absorbs window resizing.
        diffItem.holdingPriority = NSLayoutConstraint.Priority(240)

        let termItem = NSSplitViewItem(viewController: terminalPane)
        termItem.minimumThickness = 240
        termItem.holdingPriority = NSLayoutConstraint.Priority(250)

        split.addSplitViewItem(treeItem)
        split.addSplitViewItem(diffItem)
        split.addSplitViewItem(termItem)
        self.split = split

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1240, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.contentViewController = split
        window.title = "\(repo.slug) #\(pr.number)"
        window.appearance = NSAppearance(named: .aqua)   // light chrome
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("LGTMEditorWindow-\(repo.slug)-\(pr.number)")
        window.center()

        super.init(window: window)
        window.delegate = self

        // File selection in the tree → render that file's diff.
        treePane.onMessage = { [weak self] name, body in
            guard name == "fileSelected", let path = body as? String else { return }
            self?.loadDiff(path: path)
        }
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
        let entries = snap.status.map { GitStatusEntry(path: $0.key, status: $0.value.rawValue) }
        guard let pathsJSON = jsonString(snap.paths),
              let statusJSON = jsonString(entries) else { return }
        treePane.callJS("window.LGTM.renderTree(\(pathsJSON), \(statusJSON));")
    }

    private func loadDiff(path: String) {
        let status = statusMap[path] ?? .modified
        let base = self.base
        let root = worktree.path
        DispatchQueue.global(qos: .userInitiated).async {
            let fd = WorktreeData.fileDiff(root: root, base: base, path: path, status: status)
            guard let json = jsonString(fd) else { return }
            DispatchQueue.main.async {
                self.diffPane.callJS("window.LGTM.renderDiff(\(json));")
            }
        }
    }

    // MARK: NSWindowDelegate
    func windowWillClose(_ notification: Notification) {
        terminalPane.terminate()
        Self.open[worktree.standardizedFileURL.path] = nil
    }
}
