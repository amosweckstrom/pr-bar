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
struct GitHubClient {
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
                author { login }
                reviewDecision
                reviewRequests(first: 30) {
                  nodes {
                    requestedReviewer {
                      __typename
                      ... on User { login }
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

        guard let data = json["data"] as? [String: Any] else {
            throw GitHubError.decoding("missing data")
        }
        guard let repository = data["repository"] as? [String: Any],
              let prs = repository["pullRequests"] as? [String: Any],
              let nodes = prs["nodes"] as? [[String: Any]] else {
            throw GitHubError.decoding("missing repository.pullRequests")
        }

        let parsed: [PullRequest] = nodes.compactMap { node in
            guard let id = node["id"] as? String,
                  let number = node["number"] as? Int,
                  let title = node["title"] as? String,
                  let url = node["url"] as? String else {
                return nil
            }
            let author = (node["author"] as? [String: Any])?["login"] as? String ?? "ghost"

            let checkRollup = (((node["commits"] as? [String: Any])?["nodes"] as? [[String: Any]])?
                .first?["commit"] as? [String: Any])?["statusCheckRollup"] as? [String: Any]
            let rollupState = checkRollup?["state"] as? String

            let requestNodes = ((node["reviewRequests"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
            let requestedLogins: [String] = requestNodes.compactMap {
                ($0["requestedReviewer"] as? [String: Any])?["login"] as? String
            }
            let requestedFromMe = requestedLogins.contains { $0.caseInsensitiveCompare(viewerLogin) == .orderedSame }
            let authoredByMe = author.caseInsensitiveCompare(viewerLogin) == .orderedSame

            return PullRequest(
                id: id,
                number: number,
                title: title,
                url: url,
                author: author,
                checkStatus: CheckStatus(rollup: rollupState),
                reviewState: ReviewState(decision: node["reviewDecision"] as? String),
                reviewRequestedFromMe: requestedFromMe,
                authoredByMe: authoredByMe
            )
        }

        // Review-requested-from-me pinned on top; otherwise keep API order (most recently updated).
        return parsed.enumerated().sorted { lhs, rhs in
            if lhs.element.reviewRequestedFromMe != rhs.element.reviewRequestedFromMe {
                return lhs.element.reviewRequestedFromMe
            }
            return lhs.offset < rhs.offset
        }.map { $0.element }
    }

    // MARK: - Transport

    private func post(query: String, variables: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("pr-bar", forHTTPHeaderField: "User-Agent")

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
