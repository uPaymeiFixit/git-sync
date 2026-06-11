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
        .frame(width: 580, height: 460)
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
                EnabledCheckbox(skipBinding: $settings.skipGitlab,
                                label: "Enable GitLab sync")
                LabeledField(label: "Host",
                             value: $settings.gitlabHost,
                             prompt: "gitlab.example.com")
                LabeledSecureField(label: "Personal access token",
                                   value: $settings.gitlabToken,
                                   prompt: "glpat-…",
                                   generateURL: gitlabTokenURL())
                Text("Token stored in Keychain. Needs `read_api` and `read_repository` scopes. If left blank, the bundled glab falls back to your existing `glab auth login` config (if any).")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("GitHub") {
                EnabledCheckbox(skipBinding: $settings.skipGithub,
                                label: "Enable GitHub sync")
                LabeledField(label: "Organization",
                             value: $settings.githubOrg,
                             prompt: "your-github-org")
                LabeledSecureField(label: "Personal access token",
                                   value: $settings.githubToken,
                                   prompt: "ghp_…",
                                   generateURL: URL(string: "https://github.com/settings/tokens/new?scopes=repo&description=GitSync"))
                Text("Token stored in Keychain. Classic PAT needs `repo` scope; fine-grained needs Contents+Metadata read on the org.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Bitbucket") {
                EnabledCheckbox(skipBinding: $settings.skipBitbucket,
                                label: "Enable Bitbucket sync")
                LabeledField(label: "Workspace",
                             value: $settings.bitbucketWorkspace,
                             prompt: "your-workspace-slug")
                LabeledField(label: "Username",
                             value: $settings.bitbucketUser,
                             prompt: "your-bitbucket-username")
                LabeledSecureField(label: "App password",
                                   value: $settings.bitbucketAppPassword,
                                   prompt: "",
                                   generateURL: URL(string: "https://bitbucket.org/account/settings/app-passwords/new"))
                Text("App password stored in Keychain. Needs read:repository:bitbucket scope.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func gitlabTokenURL() -> URL? {
        let host = settings.gitlabHost.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return nil }
        return URL(string: "https://\(host)/-/user_settings/personal_access_tokens?name=GitSync&scopes=read_api,read_repository")
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
                    .toggleStyle(.checkbox)
            }

            // Skip patterns gets its own Section without a LabeledContent
            // row so the text area spans the full content width instead
            // of being squeezed into the right-aligned value column.
            Section {
                Text("Skip patterns")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                TextEditor(text: $settings.skipPatterns)
                    .font(.body)
                    .frame(minHeight: 70, maxHeight: 110)
                    .padding(6)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    )
                Text("Comma-separated repo names or path prefixes to skip. Case-insensitive. Example: `legacy-monorepo, some-group/archive/`")
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
                    .toggleStyle(.checkbox)
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

// Wraps an inverted Skip* toggle into an "Enabled" checkbox. The wire
// format (env var) stays as GIT_SYNC_SKIP_X=1 so the Python scripts
// don't have to change; the UI just shows the user the opposite.
private struct EnabledCheckbox: View {
    @Binding var skipBinding: Bool
    let label: String

    var body: some View {
        Toggle(label, isOn: Binding(
            get: { !skipBinding },
            set: { skipBinding = !$0 }
        ))
        .toggleStyle(.checkbox)
    }
}

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
                .frame(minWidth: 240)
        }
    }
}

private struct LabeledSecureField: View {
    let label: String
    @Binding var value: String
    let prompt: String
    var generateURL: URL? = nil

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 6) {
                SecureField("", text: $value, prompt: Text(prompt))
                    .textFieldStyle(.roundedBorder)
                if let url = generateURL {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                    }
                    .buttonStyle(.borderless)
                    .help("Open token-generation page in your browser")
                }
            }
            .frame(minWidth: 240)
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
