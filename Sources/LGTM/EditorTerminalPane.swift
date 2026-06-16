import AppKit
import SwiftTerm

/// The editor window's right pane: a real terminal (SwiftTerm's PTY-backed
/// `LocalProcessTerminalView`) running the user's login shell in the PR's
/// worktree, styled with a light palette to match the rest of the window.
final class EditorTerminalPane: NSViewController, @preconcurrency LocalProcessTerminalViewDelegate {

    private let workingDirectory: URL
    private var terminal: LocalProcessTerminalView!
    private var started = false

    init(workingDirectory: URL) {
        self.workingDirectory = workingDirectory
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override func loadView() {
        let tv = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 480, height: 480))
        tv.autoresizingMask = [.width, .height]
        tv.font = Self.terminalFont(size: 12.5)

        // ---- Light theme ----
        tv.nativeBackgroundColor = .white
        tv.nativeForegroundColor = NSColor(white: 0.12, alpha: 1)
        tv.caretColor = NSColor(srgbRed: 0.20, green: 0.40, blue: 0.85, alpha: 1)
        tv.selectedTextBackgroundColor = .selectedTextBackgroundColor
        tv.installColors(Self.lightPalette)

        self.terminal = tv
        self.view = tv
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        startShellIfNeeded()
        view.window?.makeFirstResponder(terminal)
    }

    private func startShellIfNeeded() {
        guard !started else { return }
        started = true
        terminal.processDelegate = self

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let shellName = (shell as NSString).lastPathComponent
        var env = Terminal.getEnvironmentVariables(termName: "xterm-256color", trueColor: true)
        env.append("LGTM_EDITOR_TERMINAL=1")

        // currentDirectory is applied via chdir() in the forked child before exec.
        // A login shell (execName "-zsh") loads the user's profile so PATH (git/gh,
        // often Homebrew) resolves under the minimal GUI launch environment.
        terminal.startProcess(
            executable: shell,
            args: [],
            environment: env,
            execName: "-\(shellName)",
            currentDirectory: workingDirectory.path
        )
    }

    /// A readable Solarized-light-ish 16-colour ANSI palette (channels are
    /// UInt16 0…65535, hence ×257 from 8-bit values).
    private static let lightPalette: [SwiftTerm.Color] = {
        func c(_ r: Int, _ g: Int, _ b: Int) -> SwiftTerm.Color {
            SwiftTerm.Color(red: UInt16(r * 257), green: UInt16(g * 257), blue: UInt16(b * 257))
        }
        return [
            c(7, 54, 66),    c(220, 50, 47),  c(133, 153, 0),  c(181, 137, 0),
            c(38, 139, 210), c(211, 54, 130), c(42, 161, 152), c(101, 123, 131),
            c(88, 110, 117), c(203, 75, 22),  c(0, 43, 54),    c(7, 54, 66),
            c(38, 139, 210), c(108, 113, 196), c(42, 161, 152), c(147, 161, 161),
        ]
    }()

    /// Prefer an installed Nerd Font (so powerline/devicon prompt glyphs render)
    /// and fall back to the system monospaced font.
    private static func terminalFont(size: CGFloat) -> NSFont {
        let candidates = [
            "MesloLGS NF", "MesloLGS Nerd Font", "Hack Nerd Font Mono", "Hack Nerd Font",
            "FiraCode Nerd Font", "JetBrainsMono Nerd Font", "JetBrainsMonoNL Nerd Font",
            "SauceCodePro Nerd Font", "Symbols Nerd Font Mono",
        ]
        for name in candidates {
            if let f = NSFont(name: name, size: size) { return f }
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    func terminate() { terminal?.terminate() }

    // MARK: LocalProcessTerminalViewDelegate
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        // Leave the pane in place; the user closed their shell. A restart button
        // could go here later.
    }
}
