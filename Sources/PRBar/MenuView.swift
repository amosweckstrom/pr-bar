import SwiftUI
import AppKit

/// The dropdown content rendered by MenuBarExtra (.window style).
struct MenuView: View {
    @EnvironmentObject var state: AppState
    @State private var showingSettings = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if showingSettings || !state.hasToken {
                SettingsView(showingSettings: $showingSettings)
                    .frame(maxHeight: 420)
            } else {
                content
            }

            Divider()
            footer
        }
        .frame(width: 360)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "checklist")
                .foregroundStyle(.tint)
            Text("PR Bar")
                .font(.headline)
            if state.reviewRequestedTotal > 0 {
                Text("\(state.reviewRequestedTotal) to review")
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.2), in: Capsule())
            }
            Spacer()
            if state.isRefreshing {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    Task { await state.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Refresh now")
            }
            Button {
                showingSettings.toggle()
            } label: {
                Image(systemName: showingSettings ? "chevron.left" : "gearshape")
            }
            .buttonStyle(.plain)
            .help(showingSettings ? "Back" : "Settings")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        if state.repos.isEmpty {
            emptyState(
                icon: "folder.badge.plus",
                title: "No repositories yet",
                subtitle: "Open Settings to add a repo to track."
            )
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(state.results) { repoResult in
                        RepoSection(repoResult: repoResult)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 460)
        }
    }

    private func emptyState(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .padding(.horizontal, 16)
    }

    private var footer: some View {
        HStack {
            if let updated = state.lastUpdated {
                Text("Updated \(updated.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// One repo's header plus its PR rows.
private struct RepoSection: View {
    let repoResult: RepoPRs

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(repoResult.repo.slug)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if repoResult.reviewRequestedCount > 0 {
                    Text("\(repoResult.reviewRequestedCount)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.accentColor, in: Capsule())
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 2)

            if let error = repoResult.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            } else if repoResult.pullRequests.isEmpty {
                Text("No open PRs")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            } else {
                ForEach(repoResult.pullRequests) { pr in
                    PRRow(pr: pr)
                }
            }
        }
    }
}

/// A single tappable PR row.
private struct PRRow: View {
    let pr: PullRequest
    @State private var hovering = false

    var body: some View {
        Button {
            if let url = URL(string: pr.url) {
                NSWorkspace.shared.open(url)
            }
        } label: {
            HStack(alignment: .top, spacing: 8) {
                CheckDot(status: pr.checkStatus)
                    .padding(.top, 3)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        if pr.reviewRequestedFromMe {
                            Text("REVIEW")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 3))
                        }
                        Text(pr.title)
                            .font(.callout)
                            .lineLimit(1)
                    }
                    HStack(spacing: 6) {
                        Text("#\(pr.number)")
                        Text("@\(pr.author)")
                        ReviewBadge(state: pr.reviewState)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(hovering ? Color.primary.opacity(0.07) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct CheckDot: View {
    let status: CheckStatus

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .help(help)
    }

    private var color: Color {
        switch status {
        case .success: return .green
        case .failure: return .red
        case .pending: return .yellow
        case .none: return .gray.opacity(0.4)
        }
    }

    private var help: String {
        switch status {
        case .success: return "Checks passing"
        case .failure: return "Checks failing"
        case .pending: return "Checks running"
        case .none: return "No checks"
        }
    }
}

private struct ReviewBadge: View {
    let state: ReviewState

    var body: some View {
        if let label {
            Text(label)
                .foregroundStyle(color)
        }
    }

    private var label: String? {
        switch state {
        case .approved: return "approved"
        case .changesRequested: return "changes requested"
        case .reviewRequired: return "review required"
        case .none: return nil
        }
    }

    private var color: Color {
        switch state {
        case .approved: return .green
        case .changesRequested: return .red
        case .reviewRequired: return .orange
        case .none: return .secondary
        }
    }
}
