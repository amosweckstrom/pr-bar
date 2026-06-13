import Foundation
import ServiceManagement

/// Wraps SMAppService so the app can register itself as a login item.
/// Only works when running from a proper .app bundle (not `swift run`).
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            NSLog("pr-bar: failed to update login item: \(error.localizedDescription)")
        }
    }
}
