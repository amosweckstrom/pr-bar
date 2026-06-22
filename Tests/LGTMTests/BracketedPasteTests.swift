import XCTest
@testable import LGTM

/// Pins the byte sequence injected into the terminal. Pure — no terminal.
final class BracketedPasteTests: XCTestCase {

    // "hi" → h = 0x68, i = 0x69.
    private let hi: [UInt8] = [0x68, 0x69]
    private let start: [UInt8] = [0x1b, 0x5b, 0x32, 0x30, 0x30, 0x7e]  // ESC[200~
    private let end:   [UInt8] = [0x1b, 0x5b, 0x32, 0x30, 0x31, 0x7e]  // ESC[201~
    private let cr: UInt8 = 0x0d

    func testActiveWrapsInBracketsThenSubmitsOutsideThem() {
        let bytes = BracketedPaste.bytes("hi", active: true, submit: true)
        XCTAssertEqual(bytes, start + hi + end + [cr])
    }

    func testInactiveSendsRawTextThenCarriageReturn() {
        let bytes = BracketedPaste.bytes("hi", active: false, submit: true)
        XCTAssertEqual(bytes, hi + [cr])
    }

    func testNoSubmitOmitsCarriageReturn() {
        XCTAssertEqual(BracketedPaste.bytes("hi", active: true, submit: false), start + hi + end)
        XCTAssertEqual(BracketedPaste.bytes("hi", active: false, submit: false), hi)
    }

    func testMultilineStaysOnePasteBlock() {
        // A newline lives inside the paste markers, never as a bare submit.
        let bytes = BracketedPaste.bytes("a\nb", active: true, submit: true)
        XCTAssertEqual(bytes, start + [0x61, 0x0a, 0x62] + end + [cr])
    }
}
