import SwiftUI

@main
struct GitSyncMenuBarApp: App {
    @StateObject private var state = AppState()

    init() {
        // CLI-mode entry points. Detected at startup so we don't spin up a
        // GUI for tooling commands.
        let args = CommandLine.arguments.dropFirst()
        if args.contains("--verify-parser") {
            exit(VerifyParser.run())
        }
        if args.contains("--smoke-test") {
            exit(SmokeTest.run())
        }
    }

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
