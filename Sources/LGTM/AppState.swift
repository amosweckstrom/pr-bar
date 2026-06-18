import Foundation
import SwiftUI

/// Central observable state: tracked repos, the fetched PRs, and refresh logic.
@MainActor
final class AppState: ObservableObject {
    @Published var repos: [TrackedRepo] {
        didSet { persistRepos() }
    }
    @Published private(set) var results: [RepoPRs] = [] {
        didSet { persistResults() }
    }
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastError: String?
    @Published private(set) var lastUpdated: Date?
    @Published var hasToken: Bool
    @Published var launchAtLogin: Bool
    /// Bundle ID of the terminal to open AI reviews in.
    @Published var terminalBundleID: String {
        didSet { UserDefaults.standard.set(terminalBundleID, forKey: terminalKey) }
    }
    /// Which coding agent "Review with AI" launches.
    @Published var agentID: String {
        didSet { UserDefaults.standard.set(agentID, forKey: agentKey) }
    }
    /// Command used when `agentID` is the custom agent.
    @Published var customAgentCommand: String {
        didSet { UserDefaults.standard.set(customAgentCommand, forKey: customAgentKey) }
    }
    @Published private(set) var collapsedRepoIDs: Set<String> {
        didSet { UserDefaults.standard.set(Array(collapsedRepoIDs), forKey: collapsedKey) }
    }

    private let reposKey = "trackedRepos"
    private let resultsKey = "cachedResults"
    private let collapsedKey = "collapsedRepos"
    private let terminalKey = "terminalBundleID"
    private let agentKey = "agentID"
    private let customAgentKey = "customAgentCommand"
    private let refreshInterval: TimeInterval = 180 // 3 minutes
    private var timer: Timer?
    private var viewerLogin: String?
    private var lastWorktreeCleanup: Date?

    init() {
        self.hasToken = Keychain.loadToken() != nil
        self.launchAtLogin = LoginItem.isEnabled
        self.terminalBundleID = UserDefaults.standard.string(forKey: terminalKey)
            ?? Terminals.defaultBundleID
        self.agentID = UserDefaults.standard.string(forKey: agentKey) ?? Agents.defaultID
        self.customAgentCommand = UserDefaults.standard.string(forKey: customAgentKey) ?? ""
        let savedCollapsed = UserDefaults.standard.array(forKey: collapsedKey) as? [String] ?? []
        self.collapsedRepoIDs = Set(savedCollapsed)
        if let data = UserDefaults.standard.data(forKey: reposKey),
           let saved = try? JSONDecoder().decode([TrackedRepo].self, from: data) {
            self.repos = saved
        } else {
            self.repos = []
        }
        // Show the last fetched PRs instantly on launch; refresh() updates them
        // in the background. (Assigning here doesn't fire the didSet observer.)
        if let data = UserDefaults.standard.data(forKey: resultsKey),
           let cached = try? JSONDecoder().decode([RepoPRs].self, from: data) {
            self.results = cached
        }
    }

    /// Total number of PRs awaiting the user's review across all repos.
    var reviewRequestedTotal: Int { Attention.reviewRequestedTotal(in: results) }

    /// Your authored PRs that a reviewer has approved or requested changes on,
    /// across all repos. Changes-requested sort first (more to do), then approved.
    var respondedPRs: [AttentionPR] { Attention.respondedPRs(in: results) }

    /// All of your open PRs across tracked repos, ordered by what needs action
    /// first: changes requested, then approved, then still awaiting review.
    var myPRs: [AttentionPR] { Attention.myPRs(in: results) }

    /// Everything that wants the user's attention: reviews owed + responses received.
    var attentionTotal: Int { Attention.attentionTotal(in: results) }

    /// What the menu-bar badge shows: actionable-now work (reviews owed + your PRs
    /// with changes requested). Excludes approved-but-unmerged PRs so the icon
    /// doesn't stay lit forever for PRs you're intentionally holding open.
    var menuBarBadgeCount: Int { Attention.menuBarBadgeCount(in: results) }

    func start() {
        Task { await refresh() }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
    }

    func setToken(_ token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Keychain.save(token: trimmed)
        hasToken = true
        viewerLogin = nil
        Task { await refresh() }
    }

    func clearToken() {
        Keychain.delete()
        hasToken = false
        viewerLogin = nil
        results = []
        lastError = nil
    }

    func addRepo(owner: String, name: String) {
        let o = owner.trimmingCharacters(in: .whitespaces)
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !o.isEmpty, !n.isEmpty else { return }
        guard Self.isValidRepoComponent(o), Self.isValidRepoComponent(n) else {
            lastError = "Invalid repository “\(o)/\(n)”. Use a plain owner/name, e.g. octocat/Hello-World."
            return
        }
        let repo = TrackedRepo(owner: o, name: n)
        guard !repos.contains(repo) else { return }
        lastError = nil
        repos.append(repo)
        Task { await refresh() }
    }

    /// GitHub owner/repo names are ASCII letters, digits, `.`, `_`, `-` only.
    /// Validate before any value can flow into a shell command (worktree paths,
    /// `gh` invocations), so a stray metacharacter can never be interpolated.
    static func isValidRepoComponent(_ s: String) -> Bool {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return !s.isEmpty && s.count <= 100 && s != "." && s != ".."
            && s.allSatisfy(allowed.contains)
    }

    func removeRepo(_ repo: TrackedRepo) {
        repos.removeAll { $0 == repo }
        results.removeAll { $0.repo == repo }
        collapsedRepoIDs.remove(repo.id)
    }

    /// Set (or clear) the local clone path for a repo. Stored absolute, with any
    /// leading `~` expanded so shell sessions can `cd` into it directly.
    func setLocalPath(_ path: String?, for repo: TrackedRepo) {
        guard let idx = repos.firstIndex(of: repo) else { return }
        let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            repos[idx].localPath = nil
        } else {
            repos[idx].localPath = (trimmed as NSString).expandingTildeInPath
        }
        // Mirror the change onto already-fetched results so open sessions and the
        // menu's "Your PRs" rows see the new path without waiting for a refresh.
        if let ridx = results.firstIndex(where: { $0.repo == repo }) {
            results[ridx].repo.localPath = repos[idx].localPath
        }
    }

    func isCollapsed(id: String) -> Bool {
        collapsedRepoIDs.contains(id)
    }

    func toggleCollapsed(id: String) {
        if collapsedRepoIDs.contains(id) {
            collapsedRepoIDs.remove(id)
        } else {
            collapsedRepoIDs.insert(id)
        }
    }

    func isCollapsed(_ repo: TrackedRepo) -> Bool { isCollapsed(id: repo.id) }
    func toggleCollapsed(_ repo: TrackedRepo) { toggleCollapsed(id: repo.id) }

    func setLaunchAtLogin(_ enabled: Bool) {
        LoginItem.setEnabled(enabled)
        launchAtLogin = LoginItem.isEnabled
    }

    func refresh() async {
        guard let token = Keychain.loadToken() else {
            hasToken = false
            return
        }
        guard !repos.isEmpty else {
            results = []
            lastError = nil
            return
        }
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let client = GitHubClient(token: token)

        do {
            if viewerLogin == nil {
                viewerLogin = try await client.viewerLogin()
            }
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return
        }
        guard let login = viewerLogin else { return }

        // Fetch every repo concurrently — one slow repo no longer blocks the
        // rest, so total time is roughly the slowest single request instead of
        // the sum of all of them.
        let repoList = repos
        let fetched = await withTaskGroup(of: (Int, RepoPRs).self) { group in
            for (idx, repo) in repoList.enumerated() {
                group.addTask {
                    do {
                        let prs = try await client.pullRequests(for: repo, viewerLogin: login)
                        return (idx, RepoPRs(repo: repo, pullRequests: prs, error: nil))
                    } catch {
                        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                        return (idx, RepoPRs(repo: repo, pullRequests: [], error: message))
                    }
                }
            }
            var collected: [(Int, RepoPRs)] = []
            for await item in group { collected.append(item) }
            return collected
        }

        // Restore the tracked-repo order (task completion order is nondeterministic).
        var ordered = fetched.sorted { $0.0 < $1.0 }.map { $0.1 }

        // Fold in the team-aware `review-requested:@me` search so the badge counts
        // requests routed via a team (CODEOWNERS) and any review-requested PR
        // beyond a busy repo's 50 most-recently-updated. Best-effort: if the
        // search fails we keep the per-repo User-login detection rather than
        // dropping everything.
        do {
            let requested = try await client.reviewRequested(in: repoList, viewerLogin: login)
            ordered = GitHubClient.merge(ordered, reviewRequested: requested)
        } catch {
            NSLog("lgtm: review-requested search failed: \(error.localizedDescription)")
        }

        results = ordered
        lastError = ordered.compactMap(\.error).first
        lastUpdated = Date()

        // Reap worktrees whose PR has since merged/closed (throttled, background).
        maybeCleanupWorktrees()
    }

    /// Reap merged/closed PR worktrees, but at most every 30 minutes: cleanup
    /// shells out to `gh` once per worktree, so running it on every 3-minute
    /// refresh is wasteful.
    private func maybeCleanupWorktrees() {
        let now = Date()
        if let last = lastWorktreeCleanup, now.timeIntervalSince(last) < 1800 { return }
        lastWorktreeCleanup = now
        Worktrees.cleanupClosed()
    }

    private func persistRepos() {
        if let data = try? JSONEncoder().encode(repos) {
            UserDefaults.standard.set(data, forKey: reposKey)
        }
    }

    private func persistResults() {
        if let data = try? JSONEncoder().encode(results) {
            UserDefaults.standard.set(data, forKey: resultsKey)
        }
    }
}
