import SwiftUI

// First-launch setup. A menu-bar (LSUIElement) app can't reliably force-open
// the macOS `Settings` scene programmatically, so onboarding is its OWN window
// (opened via openWindow(id: "onboarding")). It embeds the exact same
// ProvidersTab as Settings → Providers, so the two never drift — onboarding is
// just a welcome header around it plus a finish button.
//
// Shown automatically on first launch when nothing is configured (see
// App.swift). Also reachable any time via the menu's "Set up GitSync…".
struct OnboardingView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var providers: ProviderStore
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
                Text("Keep your git repositories cloned and up to date. Add at least one provider (a GitLab/GitHub/Bitbucket source) to get started — you can change any of this later in Settings.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 460)
                Label {
                    Text("You'll need an access token, not your account password. Each provider tells you which kind and links to where to create it — use **Test Connection** to confirm it works before finishing.")
                } icon: {
                    Image(systemName: "key.fill")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 460)
                .padding(.top, 2)
            }
            .padding(.top, 24)
            .padding(.horizontal, 24)
            .padding(.bottom, 12)

            Divider()

            // The same provider list/editor as Settings → Providers, so the two
            // never drift. Add a provider here and it's configured for real.
            ProvidersTab()
                .environmentObject(providers)
                .environmentObject(settings)

            Divider()

            HStack {
                if !providers.isConfigured {
                    Label("Add a provider to enable syncing",
                          systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if providers.isConfigured {
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
        .frame(width: 580, height: 640)
        .onAppear { bringAppWindowsToFront() }
    }

    private func finish() {
        // Mark setup done so it doesn't auto-pop again, then close. If the user
        // configured something, the next scheduled/manual run will pick it up.
        settings.hasCompletedSetup = true
        dismiss()
    }
}
