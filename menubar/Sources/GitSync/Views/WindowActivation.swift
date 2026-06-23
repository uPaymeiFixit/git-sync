import AppKit

// Nudge the app's visible windows to the front. SwiftUI's Settings/Window
// scenes opened from a MenuBarExtra (LSUIElement) app don't activate the app,
// so a newly-opened window can stack behind whatever the user was focused on.
// Calling this from .onAppear (and from menu actions that open a window) brings
// it forward.
//
// Dispatched to the next main-loop tick so it runs after the window is actually
// on screen — calling orderFrontRegardless() mid-presentation is a no-op. This
// is the single source of truth; previously five views each had their own copy
// (and MenuContent's skipped the dispatch).
@MainActor
func bringAppWindowsToFront() {
    DispatchQueue.main.async { @MainActor in
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows
            .filter { $0.isVisible }
            .forEach { $0.orderFrontRegardless() }
    }
}
