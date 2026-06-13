import SwiftUI

/// Settings / onboarding panel: token entry, repo management, login toggle.
struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @Binding var showingSettings: Bool

    @State private var tokenInput = ""
    @State private var newOwner = ""
    @State private var newName = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                tokenSection
                Divider()
                reposSection
                Divider()
                optionsSection
            }
            .padding(12)
        }
    }

    private var tokenSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("GitHub token", systemImage: "key.fill")
                .font(.subheadline.weight(.semibold))

            if state.hasToken {
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Token saved in Keychain")
                        .font(.caption)
                    Spacer()
                    Button("Remove") { state.clearToken() }
                        .font(.caption)
                }
            } else {
                Text("Paste a fine-grained or classic PAT with `repo` (read) scope.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    SecureField("ghp_…", text: $tokenInput)
                        .textFieldStyle(.roundedBorder)
                    Button("Save") {
                        state.setToken(tokenInput)
                        tokenInput = ""
                    }
                    .disabled(tokenInput.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private var reposSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Repositories", systemImage: "folder.fill")
                .font(.subheadline.weight(.semibold))

            if state.repos.isEmpty {
                Text("No repos tracked yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(state.repos) { repo in
                    HStack {
                        Text(repo.slug).font(.caption)
                        Spacer()
                        Button {
                            state.removeRepo(repo)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
            }

            HStack {
                TextField("owner", text: $newOwner)
                    .textFieldStyle(.roundedBorder)
                Text("/").foregroundStyle(.secondary)
                TextField("repo", text: $newName)
                    .textFieldStyle(.roundedBorder)
                Button("Add") {
                    state.addRepo(owner: newOwner, name: newName)
                    newOwner = ""
                    newName = ""
                }
                .disabled(newOwner.trimmingCharacters(in: .whitespaces).isEmpty
                          || newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Launch at login", isOn: Binding(
                get: { state.launchAtLogin },
                set: { state.setLaunchAtLogin($0) }
            ))
            .font(.caption)

            if let error = state.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }

            if state.hasToken {
                Button("Done") { showingSettings = false }
                    .font(.caption)
            }
        }
    }
}
