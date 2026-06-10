import SwiftUI

struct MenuContent: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        if state.isRunning {
            Text("Running…")
        } else if let last = state.lastRun {
            Text("Last run: \(last.startedAt.formatted(.relative(presentation: .named)))")
        } else {
            Text("No runs yet")
        }

        Divider()

        Button("Run now") {
            // Wired up in a later commit when SyncRunner lands.
        }
        .disabled(state.isRunning)
        .keyboardShortcut("r", modifiers: .command)

        Button("Dismiss notification") {
            state.dismissCurrentNotification()
        }
        .disabled(!state.showsAttention)
        .keyboardShortcut("d", modifiers: .command)

        Divider()

        Button("Quit") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }
}
