import SwiftUI

@main
struct GitSyncMenuBarApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environmentObject(state)
        } label: {
            Label("git-sync", systemImage: state.menuBarIconName)
        }
        .menuBarExtraStyle(.menu)
    }
}
