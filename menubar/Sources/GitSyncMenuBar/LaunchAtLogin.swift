import Foundation
import ServiceManagement

// Launch at Login via SMAppService. macOS 13+ ships this as the official
// replacement for the deprecated SMLoginItem APIs. The app is its own
// login item — no helper bundle needed for a simple menu-bar app.
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) -> Result<Void, Error> {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return .success(())
        } catch {
            return .failure(error)
        }
    }
}
