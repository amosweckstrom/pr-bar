import SwiftUI
import AppKit

/// The dropdown content rendered by MenuBarExtra (.window style).
struct MenuView: View {
    @EnvironmentObject var state: AppState
    @State private var showingSettings = false

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar(showingSettings: $showingSettings)

            Divider().opacity(0.6)

            if showingSettings || !state.hasToken {
                SettingsView(showingSettings: $showingSettings)
                    .frame(maxHeight: 440)
            } else {
                content
            }

            Divider().opacity(0.6)
            FooterBar()
        }
        .frame(width: Theme.width)
        .background(backdrop)
    }

    /// Subtle atmospheric tint over the system material — just enough depth to
    /// feel intentional, not enough to fight the native vibrancy.
    private var backdrop: some View {
        LinearGradient(
            colors: [Theme.brand.opacity(0.05), .clear],
            startPoint: .top,
            endPoint: .center
        )
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var content: some View {
        if state.repos.isEmpty {
            EmptyState(
                icon: "folder.badge.plus",
                title: "No repositories yet",
                subtitle: "Open settings to add a repo to track."
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !state.respondedPRs.isEmpty {
                        YourPRsSection(items: state.respondedPRs)
                        Divider().opacity(0.4).padding(.horizontal, 14)
                    }
                    ForEach(Array(state.results.enumerated()), id: \.element.id) { index, repoResult in
                        if index > 0 {
                            Divider().opacity(0.4).padding(.horizontal, 14)
                        }
                        RepoSection(repoResult: repoResult)
                    }
                }
                .padding(.vertical, 6)
            }
            .frame(maxHeight: 480)
        }
    }
}

// MARK: - Header

private struct HeaderBar: View {
    @EnvironmentObject var state: AppState
    @Binding var showingSettings: Bool

    var body: some View {
        HStack(spacing: 9) {
            LogoMark()

            Text("PR Bar")
                .font(.system(size: 14, weight: .bold, design: .rounded))

            if state.reviewRequestedTotal > 0 {
                StatPill(count: state.reviewRequestedTotal, text: "to review",
                         fill: AnyShapeStyle(Theme.brandGradient), glow: Theme.brand)
                    .transition(.scale.combined(with: .opacity))
            }
            if !state.respondedPRs.isEmpty {
                StatPill(count: state.respondedPRs.count, text: "responded",
                         fill: AnyShapeStyle(Theme.responseGradient), glow: Theme.success)
                    .transition(.scale.combined(with: .opacity))
            }

            Spacer(minLength: 4)

            if state.isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 22, height: 22)
            } else {
                IconButton(symbol: "arrow.clockwise", help: "Refresh now") {
                    Task { await state.refresh() }
                }
            }

            IconButton(
                symbol: showingSettings ? "chevron.backward" : "gearshape.fill",
                help: showingSettings ? "Back" : "Settings"
            ) {
                withAnimation(.easeInOut(duration: 0.18)) { showingSettings.toggle() }
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: state.attentionTotal)
    }
}

/// The little brand glyph — a gradient-filled rounded square with a checklist.
private struct LogoMark: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Theme.brandGradient)
            .frame(width: 22, height: 22)
            .overlay(
                Image(systemName: "checklist")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
            )
            .shadow(color: Theme.brand.opacity(0.4), radius: 3, y: 1)
    }
}

private struct StatPill: View {
    let count: Int
    let text: String
    let fill: AnyShapeStyle
    let glow: Color

    var body: some View {
        HStack(spacing: 3) {
            Text("\(count)")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
            Text(text)
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(fill, in: Capsule())
        .shadow(color: glow.opacity(0.35), radius: 3, y: 1)
    }
}

// MARK: - Repo section

private struct RepoSection: View {
    @EnvironmentObject var state: AppState
    let repoResult: RepoPRs
    @State private var headerHovering = false

    private var collapsed: Bool { state.isCollapsed(repoResult.repo) }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            header

            if !collapsed {
                if let error = repoResult.error {
                    InlineNote(text: error, symbol: "exclamationmark.triangle.fill", tint: Theme.failure)
                } else if repoResult.pullRequests.isEmpty {
                    InlineNote(text: "No open pull requests", symbol: "checkmark.circle", tint: .secondary)
                } else {
                    ForEach(repoResult.pullRequests) { pr in
                        PRRow(pr: pr)
                    }
                    .padding(.horizontal, 8)
                }
            }
        }
        .padding(.bottom, 4)
    }

    private var header: some View {
        Button {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                state.toggleCollapsed(repoResult.repo)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Text(repoResult.repo.slug)
                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if repoResult.reviewRequestedCount > 0 {
                    CountChip(count: repoResult.reviewRequestedCount)
                }
                if collapsed && repoResult.error == nil {
                    Text("\(repoResult.pullRequests.count)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Color.primary.opacity(headerHovering ? 0.05 : 0))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { headerHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: headerHovering)
    }
}

private struct CountChip: View {
    let count: Int
    var body: some View {
        Text("\(count)")
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(Theme.brand)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(Theme.brand.opacity(0.15), in: Capsule())
    }
}

private struct InlineNote: View {
    let text: String
    let symbol: String
    let tint: Color
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 10))
            Text(text).font(.system(size: 11)).lineLimit(2)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
    }
}

// MARK: - PR row

private struct PRRow: View {
    let pr: PullRequest
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 10) {
                StatusDot(status: pr.checkStatus)
                    .padding(.top, 4)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        if pr.reviewRequestedFromMe {
                            ReviewTag()
                        }
                        Text(pr.title)
                            .font(.system(size: 12.5, weight: pr.reviewRequestedFromMe ? .semibold : .regular))
                            .lineLimit(1)
                    }
                    HStack(spacing: 7) {
                        Text("#\(pr.number)")
                            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(Theme.brand.opacity(0.85))
                        Label("@\(pr.author)", systemImage: "person.fill")
                            .labelStyle(CompactLabel())
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                        ReviewBadge(state: pr.reviewState)
                    }
                }

                Spacer(minLength: 0)

                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.brand)
                    .opacity(hovering ? 1 : 0)
                    .padding(.top, 3)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(rowBackground)
            .overlay(alignment: .leading) {
                if pr.reviewRequestedFromMe {
                    Capsule()
                        .fill(Theme.brandGradient)
                        .frame(width: 3)
                        .padding(.vertical, 4)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    @ViewBuilder
    private var rowBackground: some View {
        if pr.reviewRequestedFromMe {
            Theme.brand.opacity(hovering ? 0.16 : 0.09)
        } else {
            Color.primary.opacity(hovering ? 0.07 : 0)
        }
    }

    private func open() {
        if let url = URL(string: pr.url) {
            NSWorkspace.shared.open(url)
        }
    }
}

/// CI status dot — filled and softly glowing, hollow when there are no checks,
/// gently pulsing while checks are running.
private struct StatusDot: View {
    let status: CheckStatus

    var body: some View {
        Image(systemName: status == .none ? "circle" : "circle.fill")
            .font(.system(size: 8, weight: .black))
            .foregroundStyle(status.color)
            .shadow(color: status == .none ? .clear : status.color.opacity(0.6), radius: 2.5)
            .symbolEffect(.pulse, options: .repeating, isActive: status == .pending)
            .help(status.help)
    }
}

/// A small uppercase pill tag (REVIEW / APPROVED / CHANGES).
private struct TagLabel: View {
    let text: String
    let fill: AnyShapeStyle

    var body: some View {
        Text(text)
            .font(.system(size: 8.5, weight: .heavy))
            .tracking(0.5)
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 1.5)
            .background(fill, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
    }
}

private struct ReviewTag: View {
    var body: some View { TagLabel(text: "REVIEW", fill: AnyShapeStyle(Theme.brandGradient)) }
}

// MARK: - Your PRs (responses received, across repos)

private struct YourPRsSection: View {
    @EnvironmentObject var state: AppState
    let items: [AttentionPR]
    @State private var headerHovering = false

    private let sectionID = "__your_prs__"
    private var collapsed: Bool { state.isCollapsed(id: sectionID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            header
            if !collapsed {
                ForEach(items) { item in
                    MyPRRow(item: item)
                }
                .padding(.horizontal, 8)
            }
        }
        .padding(.bottom, 4)
    }

    private var header: some View {
        Button {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                state.toggleCollapsed(id: sectionID)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.success)
                Text("YOUR PRS")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.4)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text("\(items.count)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.success)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(Theme.success.opacity(0.15), in: Capsule())
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Color.primary.opacity(headerHovering ? 0.05 : 0))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { headerHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: headerHovering)
    }
}

/// A row in the Your PRs section — shows the repo for context (author is you)
/// and is rail-tinted by the review decision: green approved, red changes.
private struct MyPRRow: View {
    let item: AttentionPR
    @State private var hovering = false

    private var pr: PullRequest { item.pr }
    private var approved: Bool { pr.reviewState == .approved }
    private var accent: Color { approved ? Theme.success : Theme.failure }

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 10) {
                StatusDot(status: pr.checkStatus)
                    .padding(.top, 4)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        TagLabel(
                            text: approved ? "APPROVED" : "CHANGES",
                            fill: AnyShapeStyle(approved ? Theme.responseGradient
                                                         : LinearGradient(colors: [Theme.failure, Color(red: 0.78, green: 0.18, blue: 0.2)],
                                                                          startPoint: .topLeading, endPoint: .bottomTrailing))
                        )
                        Text(pr.title)
                            .font(.system(size: 12.5, weight: .semibold))
                            .lineLimit(1)
                    }
                    HStack(spacing: 7) {
                        Text("#\(pr.number)")
                            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(Theme.brand.opacity(0.85))
                        Label(item.repo.slug, systemImage: "shippingbox")
                            .labelStyle(CompactLabel())
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer(minLength: 0)

                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.brand)
                    .opacity(hovering ? 1 : 0)
                    .padding(.top, 3)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(accent.opacity(hovering ? 0.16 : 0.09))
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(accent)
                    .frame(width: 3)
                    .padding(.vertical, 4)
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private func open() {
        if let url = URL(string: pr.url) {
            NSWorkspace.shared.open(url)
        }
    }
}

private struct ReviewBadge: View {
    let state: ReviewState
    var body: some View {
        if let label = state.label, let symbol = state.symbol {
            Label(label, systemImage: symbol)
                .labelStyle(CompactLabel())
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(state.color)
        }
    }
}

/// Tight icon+text label with minimal gap, for the dense metadata row.
private struct CompactLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 2.5) {
            configuration.icon
            configuration.title
        }
    }
}

// MARK: - Shared chrome

private struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(hovering ? Theme.brand : .secondary)
                .frame(width: 22, height: 22)
                .background(
                    Circle().fill(Color.primary.opacity(hovering ? 0.08 : 0))
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(help)
    }
}

private struct EmptyState: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Theme.brand.opacity(0.7))
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 38)
        .padding(.horizontal, 20)
    }
}

private struct FooterBar: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack {
            if let updated = state.lastUpdated {
                Label(updated.formatted(date: .omitted, time: .shortened), systemImage: "clock")
                    .labelStyle(CompactLabel())
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            } else {
                Text("Not yet refreshed")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Text("Quit")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Quit PR Bar")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}
