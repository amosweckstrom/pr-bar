import SwiftUI

@main
struct LGTMApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(state)
                .onAppear { state.start() }
        } label: {
            // Icon + attention count badge. Filled glyph when something wants you.
            let count = state.attentionTotal
            if count > 0 {
                Label("\(count)", systemImage: "checklist.checked")
            } else {
                Image(systemName: "checklist")
            }
        }
        .menuBarExtraStyle(.window)
    }
}
