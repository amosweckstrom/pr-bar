import SwiftUI
import Luminare

/// Settings / onboarding panel: token entry, repo management, login toggle.
/// Built from Luminare sections, toggles, text fields, and prominent buttons.
struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @Binding var showingSettings: Bool

    @State private var tokenInput = ""
    @State private var newOwner = ""
    @State private var newName = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                tokenSection
                reposSection
                optionsSection
            }
            .padding(10)
        }
    }

    // MARK: Token

    private var tokenSection: some View {
        LuminareSection("GitHub Token", "") {
            if state.hasToken {
                HStack(spacing: 7) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success)
                    Text("Connected").font(.system(size: 12, weight: .medium))
                    Text("stored in Keychain").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Remove", role: .destructive) { state.clearToken() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.failure)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Paste a token with read access to the repos you track.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        SecureField("ghp_…", text: $tokenInput)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                            .onSubmit(saveToken)
                        Button("Save", action: saveToken)
                            .buttonStyle(.luminareProminent)
                            .disabled(tokenIsEmpty)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
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
        LuminareSection("Repositories", "") {
            if state.repos.isEmpty {
                Text("No repos tracked yet.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            } else {
                ForEach(state.repos) { repo in
                    RepoRow(repo: repo) { state.removeRepo(repo) }
                }
            }

            HStack(spacing: 6) {
                TextField("owner", text: $newOwner)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                Text("/").foregroundStyle(.secondary)
                TextField("repo", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .onSubmit(addRepo)
                Button("Add", action: addRepo)
                    .buttonStyle(.luminareProminent)
                    .disabled(repoIsEmpty)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
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

    // MARK: Options

    private var optionsSection: some View {
        LuminareSection("Options", "") {
            LuminareToggle("Launch at login", isOn: Binding(
                get: { state.launchAtLogin },
                set: { state.setLaunchAtLogin($0) }
            ))

            VStack(alignment: .leading, spacing: 10) {
                if let error = state.lastError {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.failure)
                            .padding(.top, 1)
                        Text(error)
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.failure)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if state.hasToken {
                    Button("Done") {
                        withAnimation(.easeInOut(duration: 0.18)) { showingSettings = false }
                    }
                    .buttonStyle(.luminareProminent)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
    }
}

/// A tracked-repo row in settings with hover-to-delete.
private struct RepoRow: View {
    let repo: TrackedRepo
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "shippingbox").font(.system(size: 10)).foregroundStyle(.tertiary)
            Text(repo.slug)
                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Button(action: onDelete) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(hovering ? AnyShapeStyle(Theme.failure) : AnyShapeStyle(.tertiary))
            }
            .buttonStyle(.plain)
            .help("Stop tracking")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
