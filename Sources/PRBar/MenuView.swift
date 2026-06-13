import SwiftUI
import AppKit
import Luminare

/// The dropdown content rendered by MenuBarExtra (.window style), styled with
/// the Luminare design system (rounded bordered sections, material fills,
/// hover-highlighted cells — the "Loop" aesthetic).
struct MenuView: View {
    @EnvironmentObject var state: AppState
    @State private var showingSettings = false

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar(showingSettings: $showingSettings)
            Divider().opacity(0.5)

            if showingSettings || !state.hasToken {
                SettingsView(showingSettings: $showingSettings)
                    .frame(maxHeight: 460)
            } else {
                content
            }

            Divider().opacity(0.5)
            FooterBar()
        }
        .frame(width: Theme.width)
        .luminareTint(overridingWith: Theme.brand)
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
                VStack(alignment: .leading, spacing: 10) {
                    if !state.respondedPRs.isEmpty {
                        YourPRsGroup(items: state.respondedPRs)
                    }
                    ForEach(state.results) { repoResult in
                        RepoGroup(repoResult: repoResult)
                    }
                }
                .padding(10)
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
                ProgressView().controlSize(.small).frame(width: 22, height: 22)
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

// MARK: - Groups (repo + your PRs)

private struct RepoGroup: View {
    @EnvironmentObject var state: AppState
    let repoResult: RepoPRs

    private var collapsed: Bool { state.isCollapsed(repoResult.repo) }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            GroupHeader(
                icon: "shippingbox.fill",
                iconTint: .secondary,
                title: repoResult.repo.slug,
                titleMonospaced: true,
                reviewCount: repoResult.reviewRequestedCount,
                trailingCount: collapsed && repoResult.error == nil ? repoResult.pullRequests.count : nil,
                collapsed: collapsed
            ) {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                    state.toggleCollapsed(repoResult.repo)
                }
            }

            if !collapsed {
                if let error = repoResult.error {
                    InlineNote(text: error, symbol: "exclamationmark.triangle.fill", tint: Theme.failure)
                } else if repoResult.pullRequests.isEmpty {
                    InlineNote(text: "No open pull requests", symbol: "checkmark.circle", tint: .secondary)
                } else {
                    LuminareSection {
                        ForEach(repoResult.pullRequests) { pr in
                            Button { open(pr.url) } label: { RepoPRRow(pr: pr) }
                                .buttonStyle(.luminare)
                        }
                    }
                    .luminareMinHeight(34)
                }
            }
        }
    }
}

private struct YourPRsGroup: View {
    @EnvironmentObject var state: AppState
    let items: [AttentionPR]

    private let sectionID = "__your_prs__"
    private var collapsed: Bool { state.isCollapsed(id: sectionID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            GroupHeader(
                icon: "person.crop.circle.badge.checkmark",
                iconTint: Theme.success,
                title: "YOUR PRS",
                titleMonospaced: false,
                reviewCount: 0,
                trailingCount: items.count,
                trailingTint: Theme.success,
                collapsed: collapsed
            ) {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                    state.toggleCollapsed(id: sectionID)
                }
            }

            if !collapsed {
                LuminareSection {
                    ForEach(items) { item in
                        Button { open(item.pr.url) } label: { MyPRRow(item: item) }
                            .buttonStyle(.luminare)
                    }
                }
                .luminareMinHeight(34)
            }
        }
    }
}

/// Shared collapsible header for both group kinds.
private struct GroupHeader: View {
    let icon: String
    let iconTint: Color
    let title: String
    let titleMonospaced: Bool
    var reviewCount: Int = 0
    var trailingCount: Int? = nil
    var trailingTint: Color = .secondary
    let collapsed: Bool
    let toggle: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                Image(systemName: icon)
                    .font(.system(size: 10))
                    .foregroundStyle(iconTint)
                Text(title)
                    .font(.system(size: titleMonospaced ? 11.5 : 11,
                                  weight: titleMonospaced ? .semibold : .bold,
                                  design: titleMonospaced ? .monospaced : .default))
                    .tracking(titleMonospaced ? 0 : 0.4)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if reviewCount > 0 {
                    CountChip(count: reviewCount, tint: Theme.brand)
                }
                if let trailingCount {
                    CountChip(count: trailingCount, tint: trailingTint, soft: true)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(hovering ? 0.06 : 0),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

private struct CountChip: View {
    let count: Int
    let tint: Color
    var soft: Bool = false

    var body: some View {
        Text("\(count)")
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(soft ? AnyShapeStyle(.tertiary) : AnyShapeStyle(tint))
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(soft ? Color.clear : tint.opacity(0.15), in: Capsule())
    }
}

// MARK: - Rows

private struct RepoPRRow: View {
    let pr: PullRequest

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            StatusDot(status: pr.checkStatus)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    if pr.reviewRequestedFromMe { ReviewTag() }
                    Text(pr.title)
                        .font(.system(size: 12.5, weight: pr.reviewRequestedFromMe ? .semibold : .regular))
                        .lineLimit(1)
                }
                HStack(spacing: 7) {
                    PRNumber(pr.number)
                    Label("@\(pr.author)", systemImage: "person.fill")
                        .labelStyle(CompactLabel())
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                    ReviewBadge(state: pr.reviewState)
                }
            }
            Spacer(minLength: 0)
            OpenArrow()
        }
        .padding(.vertical, 3)
    }
}

private struct MyPRRow: View {
    let item: AttentionPR
    private var pr: PullRequest { item.pr }
    private var approved: Bool { pr.reviewState == .approved }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            StatusDot(status: pr.checkStatus)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    TagLabel(
                        text: approved ? "APPROVED" : "CHANGES",
                        fill: AnyShapeStyle(approved ? Theme.responseGradient : Theme.changesGradient)
                    )
                    Text(pr.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                }
                HStack(spacing: 7) {
                    PRNumber(pr.number)
                    Label(item.repo.slug, systemImage: "shippingbox")
                        .labelStyle(CompactLabel())
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
            OpenArrow()
        }
        .padding(.vertical, 3)
    }
}

private struct PRNumber: View {
    let number: Int
    init(_ number: Int) { self.number = number }
    var body: some View {
        Text("#\(number)")
            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
            .foregroundStyle(Theme.brand.opacity(0.85))
    }
}

private struct OpenArrow: View {
    var body: some View {
        Image(systemName: "arrow.up.forward")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
    }
}

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

private struct CompactLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 2.5) {
            configuration.icon
            configuration.title
        }
    }
}

// MARK: - Chrome

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
                .background(Circle().fill(Color.primary.opacity(hovering ? 0.08 : 0)))
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
            Text(title).font(.system(size: 13, weight: .semibold))
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
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
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
            Button { NSApplication.shared.terminate(nil) } label: {
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

private func open(_ url: String) {
    if let u = URL(string: url) { NSWorkspace.shared.open(u) }
}
