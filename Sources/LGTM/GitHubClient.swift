import Foundation

enum GitHubError: LocalizedError {
    case noToken
    case http(Int, String)
    case graphQL(String)
    case decoding(String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .noToken:
            return "No GitHub token set. Add one in Settings."
        case .http(let code, let body):
            return "GitHub HTTP \(code): \(body)"
        case .graphQL(let message):
            return message
        case .decoding(let message):
            return "Could not read GitHub response: \(message)"
        case .transport(let message):
            return message
        }
    }
}

/// Talks to the GitHub GraphQL API. One query per repo returns everything a
/// menu row needs: author, review decision, requested reviewers, and the CI
/// rollup for the head commit.
struct GitHubClient: Sendable {
    let token: String
    private let endpoint = URL(string: "https://api.github.com/graphql")!

    /// Returns the login of the authenticated user.
    func viewerLogin() async throws -> String {
        let query = "query { viewer { login } }"
        let json = try await post(query: query, variables: [:])
        guard let data = json["data"] as? [String: Any],
              let viewer = data["viewer"] as? [String: Any],
              let login = viewer["login"] as? String else {
            throw GitHubError.decoding("missing viewer.login")
        }
        return login
    }

    /// Fetches open PRs for a repo, sorted with review-requested-from-me first.
    func pullRequests(for repo: TrackedRepo, viewerLogin: String) async throws -> [PullRequest] {
        let query = """
        query($owner: String!, $name: String!) {
          repository(owner: $owner, name: $name) {
            pullRequests(states: OPEN, first: 50, orderBy: {field: UPDATED_AT, direction: DESC}) {
              nodes {
                id
                number
                title
                url
                isDraft
                author { login avatarUrl(size: 40) }
                reviewDecision
                reviewRequests(first: 30) {
                  nodes {
                    requestedReviewer {
                      __typename
                      ... on User { login }
                      ... on Team { slug }
                    }
                  }
                }
                timelineItems(itemTypes: [REVIEW_REQUESTED_EVENT], last: 20) {
                  nodes {
                    __typename
                    ... on ReviewRequestedEvent {
                      createdAt
                      requestedReviewer {
                        __typename
                        ... on User { login }
                      }
                    }
                  }
                }
                commits(last: 1) {
                  nodes {
                    commit {
                      statusCheckRollup { state }
                    }
                  }
                }
              }
            }
          }
        }
        """
        let variables: [String: Any] = ["owner": repo.owner, "name": repo.name]
        let json = try await post(query: query, variables: variables)
        return try Self.decodePullRequests(from: json, viewerLogin: viewerLogin)
    }

    /// Cross-repo search for open PRs where a review is requested from the viewer —
    /// including via a team they belong to (GitHub's `review-requested:@me`
    /// resolves team membership), and NOT capped by any single repo's list size.
    /// Returns repo-tagged PRs for `merge(_:reviewRequested:)` to fold in, so the
    /// badge can't miss a team-routed request or one beyond a busy repo's 50
    /// most-recently-updated PRs.
    func reviewRequested(in repos: [TrackedRepo], viewerLogin: String) async throws -> [ReviewRequestedPR] {
        guard !repos.isEmpty else { return [] }
        let scope = repos.map { "repo:\($0.owner)/\($0.name)" }.joined(separator: " ")
        let q = "is:open is:pr review-requested:@me \(scope)"

        var collected: [ReviewRequestedPR] = []
        var after: String?
        var pages = 0
        repeat {
            var variables: [String: Any] = ["q": q]
            if let after { variables["after"] = after }
            let json = try await post(query: Self.searchQuery, variables: variables)
            let page = try Self.decodeReviewRequested(from: json, viewerLogin: viewerLogin)
            collected.append(contentsOf: page.prs)
            after = page.nextCursor
            pages += 1
        } while after != nil && pages < 10   // hard page cap (search tops out at 1000 hits)
        return collected
    }

    private static let searchQuery = """
    query($q: String!, $after: String) {
      search(query: $q, type: ISSUE, first: 50, after: $after) {
        pageInfo { hasNextPage endCursor }
        nodes {
          __typename
          ... on PullRequest {
            id
            number
            title
            url
            isDraft
            repository { name owner { login } }
            author { login avatarUrl(size: 40) }
            reviewDecision
            commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
          }
        }
      }
    }
    """

    // MARK: - Decoding

    /// Pure, synchronous decode of a GitHub GraphQL pull-requests response into
    /// `[PullRequest]`, with the pin-on-top stable sort. No networking, so it is
    /// exercised directly in tests with fixture dictionaries.
    static func decodePullRequests(from json: [String: Any], viewerLogin: String) throws -> [PullRequest] {
        guard let data = json["data"] as? [String: Any] else {
            throw GitHubError.decoding("missing data")
        }
        guard let repository = data["repository"] as? [String: Any],
              let prs = repository["pullRequests"] as? [String: Any],
              let nodes = prs["nodes"] as? [[String: Any]] else {
            throw GitHubError.decoding("missing repository.pullRequests")
        }
        return sortPinned(nodes.compactMap { decodeNode($0, viewerLogin: viewerLogin) })
    }

    /// Decodes ONE PR node — shared by the per-repo list query and the team-aware
    /// `review-requested:@me` search. Derives author/avatar/check rollup,
    /// case-insensitive authored-by-me, the User-login review-requested flag, the
    /// draft flag, the pending-request flag (only User/Team reviewers count — a
    /// pending *bot* reviewer like Copilot must not mask a real CHANGES_REQUESTED),
    /// and the most-recent review-requested-from-me timestamp.
    /// `forceReviewRequestedFromMe` is set for search nodes, which already proved
    /// the request reaches the viewer (possibly via a team they're on).
    static func decodeNode(_ node: [String: Any], viewerLogin: String,
                           forceReviewRequestedFromMe: Bool = false) -> PullRequest? {
        guard let id = node["id"] as? String,
              let number = node["number"] as? Int,
              let title = node["title"] as? String,
              let url = node["url"] as? String else {
            return nil
        }
        let authorNode = node["author"] as? [String: Any]
        let author = authorNode?["login"] as? String ?? "ghost"
        let authorAvatarURL = authorNode?["avatarUrl"] as? String

        let checkRollup = (((node["commits"] as? [String: Any])?["nodes"] as? [[String: Any]])?
            .first?["commit"] as? [String: Any])?["statusCheckRollup"] as? [String: Any]
        let rollupState = checkRollup?["state"] as? String

        let reviewers = (((node["reviewRequests"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? [])
            .compactMap { $0["requestedReviewer"] as? [String: Any] }
        let requestedLogins = reviewers.compactMap { $0["login"] as? String }
        let requestedFromMe = forceReviewRequestedFromMe
            || requestedLogins.contains { $0.caseInsensitiveCompare(viewerLogin) == .orderedSame }
        // Only a pending human or team reviewer means "awaiting review"; a pending
        // Bot/Mannequin reviewer must not flip a PR out of CHANGES_REQUESTED.
        let humanOrTeamPending = reviewers.contains {
            let t = $0["__typename"] as? String
            return t == "User" || t == "Team"
        }
        let hasPendingReviewRequest = forceReviewRequestedFromMe || humanOrTeamPending
        let authoredByMe = author.caseInsensitiveCompare(viewerLogin) == .orderedSame

        // Most recent "review requested from me" event, for the row's age label.
        let iso = ISO8601DateFormatter()
        let timelineNodes = ((node["timelineItems"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
        var requestedAt: Date?
        for event in timelineNodes {
            guard let login = (event["requestedReviewer"] as? [String: Any])?["login"] as? String,
                  login.caseInsensitiveCompare(viewerLogin) == .orderedSame,
                  let createdStr = event["createdAt"] as? String,
                  let date = iso.date(from: createdStr) else { continue }
            if requestedAt == nil || date > requestedAt! { requestedAt = date }
        }

        return PullRequest(
            id: id,
            number: number,
            title: title,
            url: url,
            author: author,
            authorAvatarURL: authorAvatarURL,
            checkStatus: CheckStatus(rollup: rollupState),
            reviewState: ReviewState(decision: node["reviewDecision"] as? String),
            reviewRequestedFromMe: requestedFromMe,
            authoredByMe: authoredByMe,
            isDraft: node["isDraft"] as? Bool ?? false,
            reviewRequestedAt: requestedAt,
            hasPendingReviewRequest: hasPendingReviewRequest
        )
    }

    /// Review-requested-from-me pinned on top; otherwise keep input order (the
    /// list query returns most-recently-updated first).
    static func sortPinned(_ prs: [PullRequest]) -> [PullRequest] {
        prs.enumerated().sorted { lhs, rhs in
            if lhs.element.reviewRequestedFromMe != rhs.element.reviewRequestedFromMe {
                return lhs.element.reviewRequestedFromMe
            }
            return lhs.offset < rhs.offset
        }.map { $0.element }
    }

    /// A PR (from the team-aware search) tagged with the repo it belongs to, so
    /// the merge can route it back into the right `RepoPRs`.
    struct ReviewRequestedPR {
        let owner: String
        let name: String
        let pr: PullRequest
    }

    /// Pure decode of one page of the `review-requested:@me` search into
    /// repo-tagged PRs (each already flagged `reviewRequestedFromMe`), plus the
    /// next page cursor (nil when there are no more pages).
    static func decodeReviewRequested(from json: [String: Any],
                                      viewerLogin: String) throws -> (prs: [ReviewRequestedPR], nextCursor: String?) {
        guard let data = json["data"] as? [String: Any],
              let search = data["search"] as? [String: Any] else {
            throw GitHubError.decoding("missing data.search")
        }
        let nodes = search["nodes"] as? [[String: Any]] ?? []
        let pageInfo = search["pageInfo"] as? [String: Any]
        let nextCursor = (pageInfo?["hasNextPage"] as? Bool ?? false)
            ? pageInfo?["endCursor"] as? String : nil

        let prs: [ReviewRequestedPR] = nodes.compactMap { node in
            guard (node["__typename"] as? String) == "PullRequest",
                  let repo = node["repository"] as? [String: Any],
                  let owner = (repo["owner"] as? [String: Any])?["login"] as? String,
                  let name = repo["name"] as? String,
                  let pr = decodeNode(node, viewerLogin: viewerLogin, forceReviewRequestedFromMe: true)
            else { return nil }
            return ReviewRequestedPR(owner: owner, name: name, pr: pr)
        }
        return (prs, nextCursor)
    }

    /// Pure merge of the team-aware search results into the per-repo list results:
    /// flips `reviewRequestedFromMe` on PRs already shown, and appends any
    /// review-requested PR the per-repo list missed (older than its 50
    /// most-recent, or requested only via a team). Re-pins each touched repo;
    /// repos with no search hits are returned untouched.
    static func merge(_ results: [RepoPRs], reviewRequested requested: [ReviewRequestedPR]) -> [RepoPRs] {
        guard !requested.isEmpty else { return results }
        var byRepo: [String: [PullRequest]] = [:]
        for r in requested {
            byRepo["\(r.owner)/\(r.name)".lowercased(), default: []].append(r.pr)
        }
        return results.map { repoPRs in
            guard let reqs = byRepo[repoPRs.repo.id.lowercased()], !reqs.isEmpty else { return repoPRs }
            let requestedIDs = Set(reqs.map(\.id))
            var list = repoPRs.pullRequests
            for i in list.indices where requestedIDs.contains(list[i].id) {
                list[i].reviewRequestedFromMe = true
            }
            let presentIDs = Set(list.map(\.id))
            for pr in reqs where !presentIDs.contains(pr.id) {
                list.append(pr)
            }
            var merged = repoPRs
            merged.pullRequests = sortPinned(list)
            return merged
        }
    }

    // MARK: - Transport

    private func post(query: String, variables: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30   // don't let one hung repo stall the whole refresh
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("lgtm", forHTTPHeaderField: "User-Agent")

        let body: [String: Any] = ["query": query, "variables": variables]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw GitHubError.transport(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw GitHubError.http(http.statusCode, String(bodyText.prefix(200)))
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GitHubError.decoding("invalid JSON")
        }

        if let errors = json["errors"] as? [[String: Any]], !errors.isEmpty {
            let messages = errors.compactMap { $0["message"] as? String }.joined(separator: "; ")
            throw GitHubError.graphQL(messages.isEmpty ? "GraphQL error" : messages)
        }

        return json
    }
}
