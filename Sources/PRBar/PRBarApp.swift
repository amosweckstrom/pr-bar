import SwiftUI

@main
struct PRBarApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(state)
                .onAppear { state.start() }
        } label: {
            // Icon + review-request count badge.
            let count = state.reviewRequestedTotal
            if count > 0 {
                Label("\(count)", systemImage: "checklist")
            } else {
                Image(systemName: "checklist")
            }
        }
        .menuBarExtraStyle(.window)
    }
}
