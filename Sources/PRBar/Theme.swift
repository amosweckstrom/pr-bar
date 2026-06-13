import SwiftUI

/// Central design tokens — the SwiftUI analogue of CSS variables. One source of
/// truth for the palette, spacing, and the semantic colors that encode PR state.
///
/// Direction: a "developer console". The brand sits in the indigo/blue family so
/// it never collides with the green / amber / red reserved strictly for CI
/// signal. Numbers and repo paths are monospaced — they're dev artifacts and
/// should read like it.
enum Theme {
    // Brand — used for "awaiting your review" emphasis and primary accents.
    static let brand = Color(red: 0.42, green: 0.47, blue: 0.96)      // #6B78F5
    static let brandDeep = Color(red: 0.34, green: 0.36, blue: 0.86)  // gradient partner

    // CI / checks semantics.
    static let success = Color(red: 0.18, green: 0.74, blue: 0.42)    // #2EBD6B
    static let failure = Color(red: 0.93, green: 0.31, blue: 0.31)    // #ED4F4F
    static let pending = Color(red: 0.95, green: 0.72, blue: 0.02)    // #F2B705

    // Layout.
    static let width: CGFloat = 380
    static let rowRadius: CGFloat = 7

    static var brandGradient: LinearGradient {
        LinearGradient(colors: [brand, brandDeep], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static var responseGradient: LinearGradient {
        LinearGradient(
            colors: [success, Color(red: 0.11, green: 0.58, blue: 0.34)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static var changesGradient: LinearGradient {
        LinearGradient(
            colors: [failure, Color(red: 0.78, green: 0.18, blue: 0.2)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

extension CheckStatus {
    var color: Color {
        switch self {
        case .success: return Theme.success
        case .failure: return Theme.failure
        case .pending: return Theme.pending
        case .none: return Color.secondary.opacity(0.45)
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

extension ReviewState {
    var label: String? {
        switch self {
        case .approved: return "approved"
        case .changesRequested: return "changes requested"
        case .reviewRequired: return "review required"
        case .none: return nil
        }
    }

    var color: Color {
        switch self {
        case .approved: return Theme.success
        case .changesRequested: return Theme.failure
        case .reviewRequired: return Theme.pending
        case .none: return .secondary
        }
    }

    var symbol: String? {
        switch self {
        case .approved: return "checkmark.seal.fill"
        case .changesRequested: return "arrow.triangle.2.circlepath"
        case .reviewRequired: return "hourglass"
        case .none: return nil
        }
    }
}
