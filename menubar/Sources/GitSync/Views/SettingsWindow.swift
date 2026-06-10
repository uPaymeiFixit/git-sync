import SwiftUI

struct SettingsWindow: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        TabView {
            PathsTab().tabItem { Label("Paths", systemImage: "folder") }
            PlatformsTab().tabItem { Label("Platforms", systemImage: "rectangle.connected.to.line.below") }
            BehaviorTab().tabItem { Label("Behavior", systemImage: "slider.horizontal.3") }
            ScheduleTab().tabItem { Label("Schedule", systemImage: "clock") }
        }
        .frame(width: 560, height: 420)
        .padding()
        // Force the Settings window to float to the front when opened; the
        // default behavior in a LSUIElement app leaves it behind other
        // app windows on the same Space.
        .onAppear { bringWindowToFront() }
    }
}

// MARK: - Tabs

private struct PathsTab: View {
    @EnvironmentObject private var settings: SettingsStore
    var body: some View {
        Form {
            Section("Sync root") {
                FolderField(value: $settings.syncRoot,
                            prompt: "/Users/you/git/synced")
                Text("Where mirrored repos are cloned. Bitbucket/, Gitlab/, Github/ subdirectories are created underneath.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct PlatformsTab: View {
    @EnvironmentObject private var settings: SettingsStore
    var body: some View {
        Form {
            Section("GitLab") {
                Toggle("Skip GitLab", isOn: $settings.skipGitlab)
                LabeledField(label: "Host",
                             value: $settings.gitlabHost,
                             prompt: "gitlab.example.com")
                Text("Auth lives in glab's config. Run `glab auth login --hostname <host>` once.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("GitHub") {
                Toggle("Skip GitHub", isOn: $settings.skipGithub)
                LabeledField(label: "Organization",
                             value: $settings.githubOrg,
                             prompt: "your-github-org")
                LabeledSecureField(label: "Personal access token",
                                   value: $settings.githubToken,
                                   prompt: "ghp_…")
                Text("Token stored in Keychain. Needs 'repo' (classic) or Contents+Metadata read (fine-grained).")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Bitbucket") {
                Toggle("Skip Bitbucket", isOn: $settings.skipBitbucket)
                LabeledField(label: "Workspace",
                             value: $settings.bitbucketWorkspace,
                             prompt: "your-workspace-slug")
                LabeledField(label: "Username",
                             value: $settings.bitbucketUser,
                             prompt: "your-bitbucket-username")
                LabeledSecureField(label: "App password",
                                   value: $settings.bitbucketAppPassword,
                                   prompt: "")
                Text("App password stored in Keychain. Needs read:repository:bitbucket scope.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct BehaviorTab: View {
    @EnvironmentObject private var settings: SettingsStore
    var body: some View {
        Form {
            Section {
                LabeledContent("Parallel workers") {
                    Stepper(value: $settings.parallel, in: 1...256) {
                        Text("\(settings.parallel)")
                    }
                }
                LabeledContent("Timeout (seconds)") {
                    Stepper(value: $settings.timeout, in: 60...7200, step: 60) {
                        Text("\(settings.timeout)")
                    }
                }
                LabeledContent("Clone depth") {
                    Stepper(value: $settings.depth, in: 0...10000, step: 10) {
                        Text(settings.depth == 0 ? "full history" : "\(settings.depth)")
                    }
                }
                Toggle("Include archived repos", isOn: $settings.includeArchived)
            }
            Section("Skip patterns") {
                TextField("", text: $settings.skipPatterns,
                          prompt: Text("legacy-monorepo, some-group/archive/"),
                          axis: .vertical)
                    .lineLimit(2...5)
                    .textFieldStyle(.roundedBorder)
                Text("Comma-separated. Case-insensitive prefix match.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct ScheduleTab: View {
    @EnvironmentObject private var settings: SettingsStore
    @State private var launchAtLogin: Bool = LaunchAtLogin.isEnabled

    var body: some View {
        Form {
            Section {
                Picker("Mode", selection: $settings.scheduleMode) {
                    ForEach(ScheduleMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                switch settings.scheduleMode {
                case .manualOnly:
                    Text("Runs only when you click 'Run now'.")
                        .foregroundStyle(.secondary)
                case .everyNHours:
                    LabeledContent("Every") {
                        Stepper(value: $settings.scheduleHours, in: 1...168) {
                            Text("\(settings.scheduleHours) hour(s)")
                        }
                    }
                case .dailyAt:
                    LabeledContent("Daily at") {
                        HStack {
                            Stepper(value: $settings.scheduleDailyHour, in: 0...23) {
                                Text(String(format: "%02d", settings.scheduleDailyHour))
                            }
                            Text(":")
                            Stepper(value: $settings.scheduleDailyMinute, in: 0...59, step: 5) {
                                Text(String(format: "%02d", settings.scheduleDailyMinute))
                            }
                        }
                    }
                }
            }

            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        _ = LaunchAtLogin.setEnabled(newValue)
                        // Re-read system truth in case the toggle failed.
                        launchAtLogin = LaunchAtLogin.isEnabled
                    }
                Text("Scheduled runs fire only while GitSync is running. Enable this so the app comes back up after a reboot.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Field primitives

// Generic labeled text field. Label is OUTSIDE the box; the actual value
// shows INSIDE the box. Empty values show the prompt as placeholder text.
// roundedBorder gives a visible outline so the field doesn't disappear
// into the form background.
private struct LabeledField: View {
    let label: String
    @Binding var value: String
    let prompt: String

    var body: some View {
        LabeledContent(label) {
            TextField("", text: $value, prompt: Text(prompt))
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 220)
        }
    }
}

private struct LabeledSecureField: View {
    let label: String
    @Binding var value: String
    let prompt: String

    var body: some View {
        LabeledContent(label) {
            SecureField("", text: $value, prompt: Text(prompt))
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 220)
        }
    }
}

// Folder picker: a text field showing the current path with a "Choose…"
// button that opens NSOpenPanel.
private struct FolderField: View {
    @Binding var value: String
    let prompt: String

    var body: some View {
        HStack {
            TextField("", text: $value, prompt: Text(prompt))
                .textFieldStyle(.roundedBorder)
            Button("Choose…") { pick() }
        }
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        if !value.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
        }
        if panel.runModal() == .OK, let url = panel.url {
            value = url.path
        }
    }
}

// Helper: nudge the foreground app's key window to the front. SwiftUI's
// Settings scene doesn't activate the app, so opening Settings from a
// MenuBarExtra leaves the window stacked behind whatever the user was
// previously focused on.
@MainActor
private func bringWindowToFront() {
    DispatchQueue.main.async { @MainActor in
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows
            .filter { $0.isVisible }
            .forEach { $0.orderFrontRegardless() }
    }
}
