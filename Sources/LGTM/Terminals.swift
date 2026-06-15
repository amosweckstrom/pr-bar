import AppKit

/// A terminal emulator LGTM knows how to launch a command in.
struct TerminalApp: Identifiable, Hashable {
    let name: String
    let bundleID: String
    var id: String { bundleID }
}

/// Detects installed terminal emulators and launches a shell command in the
/// user's chosen one. Terminal and iTerm are driven via AppleScript; the rest
/// via their documented `-e`-style CLI in the app bundle.
enum Terminals {
    static let defaultBundleID = "com.apple.Terminal"

    /// Terminals we know how to drive, in display order.
    static let known: [TerminalApp] = [
        TerminalApp(name: "Terminal", bundleID: "com.apple.Terminal"),
        TerminalApp(name: "iTerm", bundleID: "com.googlecode.iterm2"),
        TerminalApp(name: "Ghostty", bundleID: "com.mitchellh.ghostty"),
        TerminalApp(name: "WezTerm", bundleID: "com.github.wez.wezterm"),
        TerminalApp(name: "kitty", bundleID: "net.kovidgoyal.kitty"),
        TerminalApp(name: "Alacritty", bundleID: "org.alacritty"),
    ]

    /// The subset of `known` that is actually installed, resolved via LaunchServices.
    static func installed() -> [TerminalApp] {
        known.filter { appURL(for: $0.bundleID) != nil }
    }

    static func name(for bundleID: String) -> String {
        known.first { $0.bundleID == bundleID }?.name ?? "Terminal"
    }

    static func appURL(for bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    /// Open a new terminal window running `shellCommand`. Falls back to
    /// Terminal.app if the chosen terminal isn't installed.
    static func launch(bundleID: String, shellCommand cmd: String) {
        let target = appURL(for: bundleID) != nil ? bundleID : defaultBundleID
        let full = keepOpen(cmd)
        switch target {
        case "com.apple.Terminal":
            runAppleScript("""
            tell application "Terminal"
                activate
                do script "\(escapeAppleScript(full))"
            end tell
            """)
        case "com.googlecode.iterm2":
            runAppleScript("""
            tell application "iTerm"
                activate
                set w to (create window with default profile)
                tell current session of w to write text "\(escapeAppleScript(full))"
            end tell
            """)
        default:
            runCLI(bundleID: target, command: full)
        }
    }

    /// Wrap a command so the terminal window stays open after it ends: run it,
    /// then exec the user's login shell. This keeps an exited agent session (and
    /// crucially, any error from the setup chain) visible instead of letting
    /// terminals like Ghostty close the window the instant the command exits.
    private static func keepOpen(_ cmd: String) -> String {
        "{ \(cmd); }; status=$?; echo; "
            + "if [ $status -ne 0 ]; then echo \"[lgtm] command exited with status $status (see above)\"; fi; "
            + "echo \"[lgtm] session ended — this shell is yours; type exit to close.\"; "
            + "exec \"${SHELL:-/bin/zsh}\" -l"
    }

    // MARK: - CLI-driven terminals

    private static func runCLI(bundleID: String, command cmd: String) {
        guard let app = appURL(for: bundleID) else { return }
        let macOS = app.appendingPathComponent("Contents/MacOS")
        let binaryAndArgs: (String, [String])?
        switch bundleID {
        case "com.mitchellh.ghostty":
            binaryAndArgs = ("ghostty", ["-e", "bash", "-lc", cmd])
        case "org.alacritty":
            binaryAndArgs = ("alacritty", ["-e", "bash", "-lc", cmd])
        case "net.kovidgoyal.kitty":
            binaryAndArgs = ("kitty", ["bash", "-lc", cmd])
        case "com.github.wez.wezterm":
            binaryAndArgs = ("wezterm-gui", ["start", "--", "bash", "-lc", cmd])
        default:
            binaryAndArgs = nil
        }
        guard let (binary, args) = binaryAndArgs else { return }
        run(macOS.appendingPathComponent(binary), args)
        // Bring the terminal to the foreground (binary launch may stay in back).
        run(URL(fileURLWithPath: "/usr/bin/open"), ["-b", bundleID])
    }

    // MARK: - Process helpers

    private static func runAppleScript(_ script: String) {
        run(URL(fileURLWithPath: "/usr/bin/osascript"), ["-e", script])
    }

    private static func run(_ executable: URL, _ arguments: [String]) {
        let proc = Process()
        proc.executableURL = executable
        proc.arguments = arguments
        do {
            try proc.run()
        } catch {
            NSLog("lgtm: failed to launch \(executable.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// Escape a string for embedding inside an AppleScript double-quoted literal.
    private static func escapeAppleScript(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
