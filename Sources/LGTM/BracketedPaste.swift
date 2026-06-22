import Foundation

/// Builds the raw bytes to push into the terminal when injecting a prompt into
/// the running agent.
///
/// When the foreground program has bracketed-paste mode on (a TUI like Claude
/// Code), the text is wrapped in `ESC[200~ … ESC[201~` so embedded newlines
/// arrive as one multi-line paste instead of submitting line-by-line. A trailing
/// carriage return — sent *outside* the paste markers, so the TUI reads it as
/// Enter — then submits the message. Pure → unit-tested.
enum BracketedPaste {
    static let start: [UInt8] = [0x1b, 0x5b, 0x32, 0x30, 0x30, 0x7e]  // ESC [ 2 0 0 ~
    static let end:   [UInt8] = [0x1b, 0x5b, 0x32, 0x30, 0x31, 0x7e]  // ESC [ 2 0 1 ~
    static let carriageReturn: UInt8 = 0x0d

    static func bytes(_ text: String, active: Bool, submit: Bool) -> [UInt8] {
        var out: [UInt8] = []
        if active { out += start }
        out += Array(text.utf8)
        if active { out += end }
        if submit { out.append(carriageReturn) }
        return out
    }
}
