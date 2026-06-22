import AppKit
import SwiftTerm

/// The editor window's right pane: a real terminal (SwiftTerm's PTY-backed
/// `LocalProcessTerminalView`) running the user's login shell in the PR's
/// worktree, styled with a light palette to match the rest of the window.
final class EditorTerminalPane: NSViewController, @preconcurrency LocalProcessTerminalViewDelegate {

    private let workingDirectory: URL
    /// Coding-agent command to launch on open (e.g. `claude`, `gemini -i`), or
    /// nil for a plain login shell.
    private let agentInvocation: String?
    private var terminal: LocalProcessTerminalView!
    private var started = false
    private var appearanceObserver: NSKeyValueObservation?
    /// Local monitor that forwards wheel scrolling to a mouse-tracking TUI (see
    /// installScrollForwarding). `Any?` because that's NSEvent's monitor token type.
    private var scrollMonitor: Any?

    init(workingDirectory: URL, agentInvocation: String?) {
        self.workingDirectory = workingDirectory
        self.agentInvocation = agentInvocation
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    /// Padding between the pane edges and the terminal grid, so the agent's
    /// output isn't jammed against the window chrome.
    private static let padding: CGFloat = 10

    override func loadView() {
        let tv = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 480, height: 480))
        tv.font = Self.terminalFont(size: 12.5)
        tv.selectedTextBackgroundColor = .selectedTextBackgroundColor
        tv.translatesAutoresizingMaskIntoConstraints = false
        self.terminal = tv

        // SwiftTerm draws edge-to-edge within its own bounds (no inset property),
        // so inset the terminal inside a container view. applyTheme paints the
        // container the same colour as the terminal background, so the inset reads
        // as terminal padding rather than a gap showing the window behind.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 480))
        container.wantsLayer = true
        container.autoresizingMask = [.width, .height]
        container.addSubview(tv)
        let pad = Self.padding
        NSLayoutConstraint.activate([
            tv.topAnchor.constraint(equalTo: container.topAnchor, constant: pad),
            tv.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -pad),
            tv.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: pad),
            tv.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -pad),
        ])
        self.view = container

        applyTheme()   // light or dark palette + matching padding background
        // Live-follow system light/dark changes while the window is open.
        // effectiveAppearance KVO fires on the main thread; hop to satisfy isolation.
        appearanceObserver = tv.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async { self?.applyTheme() }
        }
    }

    // MARK: Appearance (follow the system light/dark setting)

    private var isDark: Bool {
        (isViewLoaded ? view.effectiveAppearance : NSApp.effectiveAppearance)
            .bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    private func applyTheme() {
        guard let tv = terminal else { return }
        let bg: NSColor
        if isDark {
            bg = NSColor(srgbRed: 0.051, green: 0.067, blue: 0.090, alpha: 1)  // #0d1117
            tv.nativeBackgroundColor = bg
            tv.nativeForegroundColor = NSColor(srgbRed: 0.90, green: 0.93, blue: 0.95, alpha: 1)
            tv.caretColor = NSColor(srgbRed: 0.31, green: 0.55, blue: 0.97, alpha: 1)
            tv.installColors(Self.darkPalette)
        } else {
            bg = .white
            tv.nativeBackgroundColor = bg
            tv.nativeForegroundColor = NSColor(white: 0.12, alpha: 1)
            tv.caretColor = NSColor(srgbRed: 0.20, green: 0.40, blue: 0.85, alpha: 1)
            tv.installColors(Self.lightPalette)
        }
        // Keep the padding container's background in lock-step with the terminal.
        view.layer?.backgroundColor = bg.cgColor
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // Defer one runloop hop so the split view's initial layout (applied by
        // EditorWindowController.start right after the window is shown) has sized
        // the terminal before the PTY starts. Starting at the final width avoids
        // the shell prompt reflowing across the burst of startup resize events —
        // the stacked, half-drawn prompts you'd otherwise see on open.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.startShellIfNeeded()
            self.installScrollForwarding()
            self.view.window?.makeFirstResponder(self.terminal)
        }
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
        let args: [String]
        let execName: String
        if let agent = agentInvocation, !agent.isEmpty {
            // Open straight into the coding agent: a login + interactive shell
            // (so PATH, aliases and functions all resolve) runs the agent, then
            // `exec`s a fresh interactive login shell when the agent exits — so
            // closing the agent leaves a usable shell, not a dead pane.
            args = ["-l", "-i", "-c", "\(agent); exec \"\(shell)\" -l -i"]
            execName = shellName
        } else {
            // Plain login shell (execName "-zsh") — loads the user's profile so
            // PATH (git/gh, often Homebrew) resolves under the minimal GUI launch
            // environment.
            args = []
            execName = "-\(shellName)"
        }

        terminal.startProcess(
            executable: shell,
            args: args,
            environment: env,
            execName: execName,
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

    /// GitHub-Dark-style 16-colour ANSI palette for the dark appearance.
    private static let darkPalette: [SwiftTerm.Color] = {
        func c(_ r: Int, _ g: Int, _ b: Int) -> SwiftTerm.Color {
            SwiftTerm.Color(red: UInt16(r * 257), green: UInt16(g * 257), blue: UInt16(b * 257))
        }
        return [
            c(72, 79, 88),    c(255, 123, 114), c(63, 185, 80),  c(210, 153, 34),
            c(88, 166, 255),  c(188, 140, 255), c(57, 197, 207), c(177, 186, 196),
            c(110, 118, 129), c(255, 161, 152), c(86, 211, 100), c(227, 179, 65),
            c(121, 192, 255), c(210, 168, 255), c(86, 212, 221), c(240, 246, 252),
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

    /// Called from EditorWindowController.windowWillClose (main thread), so the
    /// scroll monitor is torn down here rather than in a nonisolated deinit.
    func terminate() {
        terminal?.terminate()
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor); self.scrollMonitor = nil }
    }

    /// Forward mouse-wheel scrolling to the running program when it has mouse
    /// tracking on in the alternate screen buffer (full-screen TUIs like the coding
    /// agent). SwiftTerm's stock `scrollWheel` only scrolls its own scrollback,
    /// which is empty in the alternate buffer — so without this the wheel does
    /// nothing over the agent and its scroll view is unreachable. We can't override
    /// `scrollWheel` (SwiftTerm marks it `public`, not `open`), so intercept wheel
    /// events with a local monitor and translate them to mouse-wheel button presses.
    /// In every other case the event passes through to SwiftTerm's native scrollback.
    private func installScrollForwarding() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            return self.forwardScroll(event) ? nil : event
        }
    }

    /// Returns true when `event` was forwarded to a mouse-tracking TUI (and should
    /// be swallowed); false to let SwiftTerm handle it natively.
    private func forwardScroll(_ event: NSEvent) -> Bool {
        guard let terminal, isViewLoaded, event.deltaY != 0,
              event.window === view.window,
              let term = terminal.terminal,
              term.mouseMode != .off,
              term.isCurrentBufferAlternate else { return false }
        // Only when the pointer is actually over the terminal grid.
        let local = terminal.convert(event.locationInWindow, from: nil)
        guard terminal.bounds.contains(local) else { return false }

        // Wheel up = button 4, wheel down = button 5 (xterm convention), at the cell
        // under the pointer so the app scrolls the region the user is over. SwiftTerm
        // draws the grid edge-to-edge, so cells divide the bounds evenly; AppKit's
        // y-origin is bottom-left while terminal row 0 is at the top.
        let button = event.deltaY > 0 ? 4 : 5
        let flags = term.encodeButton(button: button, release: false,
                                      shift: false, meta: false, control: false)
        let cols = max(1, term.cols), rows = max(1, term.rows)
        let cellW = max(1, terminal.bounds.width / CGFloat(cols))
        let cellH = max(1, terminal.bounds.height / CGFloat(rows))
        let col = min(cols - 1, max(0, Int(local.x / cellW)))
        let row = min(rows - 1, max(0, Int((terminal.bounds.height - local.y) / cellH)))
        let magnitude = Int(abs(event.deltaY))
        let steps = magnitude > 9 ? 4 : (magnitude > 3 ? 2 : 1)
        for _ in 0 ..< steps { term.sendEvent(buttonFlags: flags, x: col, y: row) }
        return true
    }

    /// Inject a prompt into the running coding agent: paste the text — bracketed
    /// when the agent's TUI has bracketed-paste mode on, so a multi-line prompt
    /// arrives as one message instead of submitting line-by-line — then submit
    /// with a carriage return and focus the terminal so the user sees it run.
    /// If a plain shell is running instead (the agent was quit), the text simply
    /// lands at the shell prompt; we don't try to detect that.
    func sendToAgent(_ text: String) {
        guard let terminal else { return }
        let active = terminal.terminal?.bracketedPasteMode ?? false
        terminal.send(BracketedPaste.bytes(text, active: active, submit: true))
        focusTerminal()
    }

    /// Make the terminal the window's first responder (keyboard focus).
    func focusTerminal() {
        guard let terminal else { return }
        view.window?.makeFirstResponder(terminal)
    }

    // MARK: LocalProcessTerminalViewDelegate
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        // Leave the pane in place; the user closed their shell. A restart button
        // could go here later.
    }
}
