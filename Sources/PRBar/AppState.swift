import Foundation
import SwiftUI

/// Central observable state: tracked repos, the fetched PRs, and refresh logic.
@MainActor
final class AppState: ObservableObject {
    @Published var repos: [TrackedRepo] {
        didSet { persistRepos() }
    }
    @Published private(set) var results: [RepoPRs] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastError: String?
    @Published private(set) var lastUpdated: Date?
    @Published var hasToken: Bool
    @Published var launchAtLogin: Bool
    @Published private(set) var collapsedRepoIDs: Set<String> {
        didSet { UserDefaults.standard.set(Array(collapsedRepoIDs), forKey: collapsedKey) }
    }

    private let reposKey = "trackedRepos"
    private let collapsedKey = "collapsedRepos"
    private let refreshInterval: TimeInterval = 180 // 3 minutes
    private var timer: Timer?
    private var viewerLogin: String?

    init() {
        self.hasToken = Keychain.loadToken() != nil
        self.launchAtLogin = LoginItem.isEnabled
        let savedCollapsed = UserDefaults.standard.array(forKey: collapsedKey) as? [String] ?? []
        self.collapsedRepoIDs = Set(savedCollapsed)
        if let data = UserDefaults.standard.data(forKey: reposKey),
           let saved = try? JSONDecoder().decode([TrackedRepo].self, from: data) {
            self.repos = saved
        } else {
            self.repos = []
        }
    }

    /// Total number of PRs awaiting the user's review across all repos.
    var reviewRequestedTotal: Int {
        results.reduce(0) { $0 + $1.reviewRequestedCount }
    }

    /// Your authored PRs that a reviewer has approved or requested changes on,
    /// across all repos. Changes-requested sort first (more to do), then approved.
    var respondedPRs: [AttentionPR] {
        results
            .flatMap { result in
                result.pullRequests
                    .filter { $0.awaitingMyResponse }
                    .map { AttentionPR(repo: result.repo, pr: $0) }
            }
            .sorted { lhs, rhs in
                func rank(_ s: ReviewState) -> Int { s == .changesRequested ? 0 : 1 }
                return rank(lhs.pr.reviewState) < rank(rhs.pr.reviewState)
            }
    }

    /// Everything that wants the user's attention: reviews owed + responses received.
    var attentionTotal: Int {
        reviewRequestedTotal + respondedPRs.count
    }

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
        let repo = TrackedRepo(owner: o, name: n)
        guard !repos.contains(repo) else { return }
        repos.append(repo)
        Task { await refresh() }
    }

    func removeRepo(_ repo: TrackedRepo) {
        repos.removeAll { $0 == repo }
        results.removeAll { $0.repo == repo }
        collapsedRepoIDs.remove(repo.id)
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

        var newResults: [RepoPRs] = []
        var firstError: String?
        for repo in repos {
            do {
                let prs = try await client.pullRequests(for: repo, viewerLogin: login)
                newResults.append(RepoPRs(repo: repo, pullRequests: prs, error: nil))
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                if firstError == nil { firstError = message }
                newResults.append(RepoPRs(repo: repo, pullRequests: [], error: message))
            }
        }
        results = newResults
        lastError = firstError
        lastUpdated = Date()
    }

    private func persistRepos() {
        if let data = try? JSONEncoder().encode(repos) {
            UserDefaults.standard.set(data, forKey: reposKey)
        }
    }
}
