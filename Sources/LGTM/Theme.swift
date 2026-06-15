import SwiftUI

/// GitHub Primer color tokens, resolved for light or dark appearance.
/// Values mirror Primer's `canvas` / `fg` / `border` / role foreground colors.
struct PrimerPalette {
    let bg: Color          // canvas.default
    let canvas: Color      // canvas.subtle (headers, footer, hovers)
    let fg: Color          // fg.default
    let muted: Color       // fg.muted
    let border: Color      // border.default
    let accent: Color      // accent.fg (links, "to review")
    let success: Color     // success.fg (open, approved, CI pass)
    let danger: Color      // danger.fg (changes, CI fail)
    let attention: Color   // attention.fg (review required, CI pending)
    let done: Color        // done.fg

    static let light = PrimerPalette(
        bg: hex(0xFFFFFF), canvas: hex(0xF6F8FA), fg: hex(0x1F2328), muted: hex(0x656D76),
        border: hex(0xD0D7DE), accent: hex(0x0969DA), success: hex(0x1A7F37),
        danger: hex(0xCF222E), attention: hex(0x9A6700), done: hex(0x8250DF)
    )

    static let dark = PrimerPalette(
        bg: hex(0x0D1117), canvas: hex(0x161B22), fg: hex(0xE6EDF3), muted: hex(0x7D8590),
        border: hex(0x30363D), accent: hex(0x2F81F7), success: hex(0x3FB950),
        danger: hex(0xF85149), attention: hex(0xD29922), done: hex(0xA371F7)
    )

    static func resolve(_ scheme: ColorScheme) -> PrimerPalette {
        scheme == .dark ? .dark : .light
    }

    private static func hex(_ v: UInt32) -> Color {
        Color(
            .sRGB,
            red: Double((v >> 16) & 0xFF) / 255,
            green: Double((v >> 8) & 0xFF) / 255,
            blue: Double(v & 0xFF) / 255
        )
    }
}

// Inject the resolved palette through the environment (manual key — no macros).
private struct PrimerPaletteKey: EnvironmentKey {
    static let defaultValue = PrimerPalette.light
}

extension EnvironmentValues {
    var primer: PrimerPalette {
        get { self[PrimerPaletteKey.self] }
        set { self[PrimerPaletteKey.self] = newValue }
    }
}

enum Theme {
    static let width: CGFloat = 460
}

extension CheckStatus {
    func color(_ p: PrimerPalette) -> Color {
        switch self {
        case .success: return p.success
        case .failure: return p.danger
        case .pending: return p.attention
        case .none: return p.muted.opacity(0.5)
        }
    }

    var help: String {
        switch self {
        case .success: return "Checks passing"
        case .failure: return "Checks failing"
        case .pending: return "Checks running"
        case .none: return "No checks"
        }
    }
}

/// The one place a review state becomes pixels: label text, leading row icon,
/// in-pill glyph, and color all live together so they can never drift apart.
/// Every row consumes this; nothing else maps a review state to presentation.
extension DisplayReviewState {
    var label: String {
        switch self {
        case .approved: return "approved"
        case .changesRequested: return "changes requested"
        case .awaitingReview: return "awaiting review"
        }
    }

    /// SF Symbol for the leading row icon, where a row shows a review-state icon.
    var icon: String {
        switch self {
        case .approved: return "checkmark.circle.fill"
        case .changesRequested: return "arrow.triangle.2.circlepath"
        case .awaitingReview: return "clock"
        }
    }

    /// Glyph shown inside the `LabelPill`, if any.
    var leadingSymbol: String? { self == .approved ? "checkmark" : nil }

    func color(_ p: PrimerPalette) -> Color {
        switch self {
        case .approved: return p.success
        case .changesRequested: return p.danger
        case .awaitingReview: return p.muted
        }
    }
}
