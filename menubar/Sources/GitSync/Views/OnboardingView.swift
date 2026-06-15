import SwiftUI

// First-launch setup. A menu-bar (LSUIElement) app can't reliably force-open
// the macOS `Settings` scene programmatically, so onboarding is its OWN window
// (opened via openWindow(id: "onboarding")). It reuses the exact same form
// components as Settings (PathsTab's folder picker + PlatformConfigSections),
// so the two never drift — onboarding is just a friendlier first pass at the
// same fields, plus a sync-root step and a finish button.
//
// Shown automatically on first launch when nothing is configured (see
// App.swift). Also reachable any time via the menu's "Set up GitSync…".
struct OnboardingView: View {
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 6) {
                Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.tint)
                Text("Welcome to GitSync")
                    .font(.title2.weight(.semibold))
                Text("Keep your git repositories cloned and up to date. Set up at least one platform below to get started — you can change any of this later in Settings.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 460)
            }
            .padding(.top, 24)
            .padding(.horizontal, 24)
            .padding(.bottom, 12)

            Divider()

            Form {
                Section("Where to sync") {
                    FolderField(value: $settings.syncRoot,
                                prompt: "/Users/you/git/synced")
                    Text("Repositories are cloned under this folder, organized by platform (e.g. \(displayRoot)/Gitlab/…).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                // Same credential sections as Settings → Platforms (the
                // advanced whitelist toggle is hidden here to keep it simple).
                PlatformConfigSections(showFilterMode: false)
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                if !settings.isConfigured {
                    Label("Configure at least one platform to enable syncing",
                          systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                // When nothing's configured, the primary action is a soft
                // "Skip for now"; once something's set up it becomes "Done".
                if settings.isConfigured {
                    Button("Done") { finish() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Skip for now") { finish() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(12)
        }
        .frame(width: 560, height: 640)
        .onAppear { bringOnboardingToFront() }
    }

    private var displayRoot: String {
        let r = settings.syncRoot.trimmingCharacters(in: .whitespaces)
        return r.isEmpty ? "~/git" : r
    }

    private func finish() {
        // Mark setup done so it doesn't auto-pop again, then close. If the user
        // configured something, the next scheduled/manual run will pick it up.
        settings.hasCompletedSetup = true
        dismiss()
    }
}

@MainActor
private func bringOnboardingToFront() {
    DispatchQueue.main.async { @MainActor in
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.filter { $0.isVisible }.forEach { $0.orderFrontRegardless() }
    }
}
