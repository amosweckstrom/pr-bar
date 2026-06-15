import SwiftUI
import AppKit

/// Settings / onboarding panel in GitHub Primer style: bold section headers,
/// bordered cards, Primer-styled inputs and buttons.
struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.primer) private var p
    @Binding var showingSettings: Bool

    @State private var tokenInput = ""
    @State private var newOwner = ""
    @State private var newName = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                tokenSection
                reposSection
                aiReviewSection
                optionsSection
            }
            .padding(14)
        }
        .background(p.bg)
    }

    // MARK: Token

    private var tokenSection: some View {
        SettingsSection(title: "GitHub token", icon: "key.fill") {
            if state.hasToken {
                HStack(spacing: 7) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(p.success)
                    Text("Connected").font(.system(size: 12, weight: .medium)).foregroundStyle(p.fg)
                    Text("stored in Keychain").font(.system(size: 11)).foregroundStyle(p.muted)
                    Spacer()
                    Button("Remove") { state.clearToken() }
                        .buttonStyle(PrimerButton(role: .danger))
                }
                .padding(11)
            } else {
                VStack(alignment: .leading, spacing: 9) {
                    Text("Paste a token with read access to the repos you track.")
                        .font(.system(size: 11))
                        .foregroundStyle(p.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        PrimerField { SecureField("ghp_…", text: $tokenInput).onSubmit(saveToken) }
                        Button("Save", action: saveToken)
                            .buttonStyle(PrimerButton(role: .primary))
                            .disabled(tokenIsEmpty)
                    }
                }
                .padding(11)
            }
        }
    }

    private var tokenIsEmpty: Bool { tokenInput.trimmingCharacters(in: .whitespaces).isEmpty }

    private func saveToken() {
        guard !tokenIsEmpty else { return }
        state.setToken(tokenInput)
        tokenInput = ""
    }

    // MARK: Repos

    private var reposSection: some View {
        SettingsSection(title: "Repositories", icon: "shippingbox.fill") {
            VStack(alignment: .leading, spacing: 9) {
                if state.repos.isEmpty {
                    Text("No repos tracked yet.")
                        .font(.system(size: 11))
                        .foregroundStyle(p.muted)
                } else {
                    VStack(spacing: 5) {
                        ForEach(state.repos) { repo in
                            RepoRow(
                                repo: repo,
                                onDelete: { state.removeRepo(repo) },
                                onSetPath: { state.setLocalPath($0, for: repo) }
                            )
                        }
                    }
                }
                HStack(spacing: 6) {
                    PrimerField { TextField("owner", text: $newOwner) }
                    Text("/").foregroundStyle(p.muted)
                    PrimerField { TextField("repo", text: $newName).onSubmit(addRepo) }
                    Button("Add", action: addRepo)
                        .buttonStyle(PrimerButton(role: .primary))
                        .disabled(repoIsEmpty)
                }
            }
            .padding(11)
        }
    }

    private var repoIsEmpty: Bool {
        newOwner.trimmingCharacters(in: .whitespaces).isEmpty
            || newName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func addRepo() {
        guard !repoIsEmpty else { return }
        state.addRepo(owner: newOwner, name: newName)
        newOwner = ""
        newName = ""
    }

    // MARK: AI review

    private var aiReviewSection: some View {
        SettingsSection(title: "AI review", icon: "sparkles") {
            VStack(alignment: .leading, spacing: 11) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Agent")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(p.fg)
                    Picker("", selection: Binding(
                        get: { state.agentID },
                        set: { state.agentID = $0 }
                    )) {
                        ForEach(Agents.known) { agent in
                            Text(agent.name).tag(agent.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .tint(p.accent)

                    if state.agentID == Agents.customID {
                        PrimerField {
                            TextField("e.g. aider --message", text: Binding(
                                get: { state.customAgentCommand },
                                set: { state.customAgentCommand = $0 }
                            ))
                        }
                        Text("The PR review prompt is appended as the final argument.")
                            .font(.system(size: 10.5))
                            .foregroundStyle(p.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text("Open in")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(p.fg)
                    Picker("", selection: Binding(
                        get: { state.terminalBundleID },
                        set: { state.terminalBundleID = $0 }
                    )) {
                        ForEach(Terminals.installed()) { term in
                            Text(term.name).tag(term.bundleID)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .tint(p.accent)
                }
            }
            .padding(11)
        }
    }

    // MARK: Options

    private var optionsSection: some View {
        SettingsSection(title: "Options", icon: "slider.horizontal.3") {
            VStack(alignment: .leading, spacing: 11) {
                Toggle(isOn: Binding(
                    get: { state.launchAtLogin },
                    set: { state.setLaunchAtLogin($0) }
                )) {
                    Text("Launch at login").font(.system(size: 12)).foregroundStyle(p.fg)
                }
                .toggleStyle(.switch)
                .tint(p.success)
                .controlSize(.small)

                if let error = state.lastError {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(p.danger)
                            .padding(.top, 1)
                        Text(error)
                            .font(.system(size: 10.5))
                            .foregroundStyle(p.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if state.hasToken {
                    Button("Done") {
                        withAnimation(.easeInOut(duration: 0.18)) { showingSettings = false }
                    }
                    .buttonStyle(PrimerButton(role: .primary))
                }
            }
            .padding(11)
        }
    }
}

// MARK: - Reusable Primer pieces

/// A titled section: bold header above a bordered card.
private struct SettingsSection<Content: View>: View {
    @Environment(\.primer) private var p
    let title: String
    let icon: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 10)).foregroundStyle(p.muted)
                Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(p.fg)
            }
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(p.canvas)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(p.border, lineWidth: 1)
                )
        }
    }
}

private struct RepoRow: View {
    @Environment(\.primer) private var p
    let repo: TrackedRepo
    let onDelete: () -> Void
    let onSetPath: (String?) -> Void
    @State private var hovering = false

    private var hasPath: Bool { repo.localPath?.isEmpty == false }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Image(systemName: "shippingbox").font(.system(size: 10)).foregroundStyle(p.muted)
                Text(repo.slug)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(p.fg)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Button(action: onDelete) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(hovering ? AnyShapeStyle(p.danger) : AnyShapeStyle(p.muted))
                }
                .buttonStyle(.plain)
                .help("Stop tracking")
            }

            // Local clone path — needed for "Address review comments with AI".
            HStack(spacing: 6) {
                Image(systemName: hasPath ? "folder.fill" : "folder.badge.questionmark")
                    .font(.system(size: 9))
                    .foregroundStyle(hasPath ? p.success : p.muted)
                Text(hasPath ? abbreviate(repo.localPath!) : "No local path set")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(hasPath ? p.muted : p.muted.opacity(0.8))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Button(hasPath ? "Change" : "Set path", action: chooseFolder)
                    .buttonStyle(PrimerButton(role: .normal))
                if hasPath {
                    Button(action: { onSetPath(nil) }) {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                    }
                    .buttonStyle(PrimerButton(role: .normal))
                    .help("Clear path")
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(p.bg)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(p.border, lineWidth: 1))
        .onHover { hovering = $0 }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use This Folder"
        panel.message = "Select your local clone of \(repo.slug)"
        if let current = repo.localPath, !current.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: current)
        }
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            onSetPath(url.path)
        }
    }

    /// Shorten an absolute path for display, collapsing the home dir to `~`.
    private func abbreviate(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}

/// A Primer-styled text field wrapper: bordered, canvas-default background.
private struct PrimerField<Content: View>: View {
    @Environment(\.primer) private var p
    @ViewBuilder var content: Content
    var body: some View {
        content
            .textFieldStyle(.plain)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(p.fg)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(p.bg)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(p.border, lineWidth: 1))
    }
}

/// GitHub Primer button: green primary, red danger, or default bordered.
private struct PrimerButton: ButtonStyle {
    enum Role { case primary, danger, normal }
    @Environment(\.primer) private var p
    @Environment(\.isEnabled) private var isEnabled
    var role: Role = .normal

    func makeBody(configuration: Configuration) -> some View {
        let bg: Color
        let fg: Color
        switch role {
        case .primary: bg = p.success; fg = .white
        case .danger:  bg = p.bg;      fg = p.danger
        case .normal:  bg = p.bg;      fg = p.fg
        }
        return configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(fg)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(bg)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(role == .primary ? .clear : p.border, lineWidth: 1)
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
    }
}
