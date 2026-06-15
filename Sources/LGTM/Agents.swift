import Foundation

/// A terminal coding agent LGTM can hand a review off to. The review prompt is
/// appended as the final quoted argument to `command`, so the agent must accept
/// an initial prompt positionally and stay interactive.
struct AgentApp: Identifiable, Hashable {
    let name: String
    let id: String
    /// Invocation prefix (command + flags). `nil` for the custom agent, whose
    /// command comes from user settings.
    let command: String?
}

enum Agents {
    static let defaultID = "claude"
    static let customID = "custom"

    static let known: [AgentApp] = [
        AgentApp(name: "Claude Code", id: "claude", command: "claude"),
        AgentApp(name: "OpenAI Codex", id: "codex", command: "codex"),
        AgentApp(name: "Gemini CLI", id: "gemini", command: "gemini -i"),
        AgentApp(name: "Cursor Agent", id: "cursor", command: "cursor-agent"),
        AgentApp(name: "Custom…", id: customID, command: nil),
    ]

    static func name(for id: String) -> String {
        known.first { $0.id == id }?.name ?? "Claude Code"
    }

    /// The invocation prefix for an agent id, using `customCommand` when the
    /// custom agent is selected. Returns nil only if custom is selected but blank.
    static func invocation(for id: String, customCommand: String) -> String? {
        if id == customID {
            let trimmed = customCommand.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return known.first { $0.id == id }?.command ?? known.first { $0.id == defaultID }?.command
    }
}
