import SwiftUI

struct SettingsWindow: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        // Each tab's content is pinned to the same fixed size. Without this,
        // live updates inside a tab (e.g. the Providers list refreshing during
        // a sync) change that tab's ideal size, AppKit re-measures the TabView,
        // and the tab-bar icons jitter a few pixels. A constant content size
        // keeps the measurement — and the tab bar — stable.
        TabView {
            PathsTab().tabContentFrame().tabItem { Label("Locations", systemImage: "folder") }
            ProvidersTab().tabContentFrame().tabItem { Label("Providers", systemImage: "rectangle.connected.to.line.below") }
            BehaviorTab().tabContentFrame().tabItem { Label("Behavior", systemImage: "slider.horizontal.3") }
            ScheduleTab().tabContentFrame().tabItem { Label("Schedule", systemImage: "clock") }
        }
        .frame(width: 580, height: 460)
        .padding()
        // Force the Settings window to float to the front when opened; the
        // default behavior in a LSUIElement app leaves it behind other
        // app windows on the same Space.
        .onAppear { bringWindowToFront() }
    }
}

private extension View {
    // Pin a tab's content to fill the TabView's fixed area, so its measured
    // size doesn't drift as the content updates (which would jitter the tab bar).
    func tabContentFrame() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Tabs

private struct PathsTab: View {
    @EnvironmentObject private var settings: SettingsStore
    var body: some View {
        Form {
            Section("Default location") {
                FolderField(value: $settings.syncRoot,
                            prompt: "/Users/you/git")
                Text("The starting folder suggested when you add a new provider. Each provider sets its own folder under the Providers tab — that's where its repos actually clone. This is only the default the picker opens to.")
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
            }

            Section {
                Text("“Include archived repos” and “Skip patterns” are now set per provider — open the Providers tab and edit a provider.")
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

// A labeled text field used across the Settings tabs.
struct LabeledField: View {
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

struct LabeledSecureField: View {
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
struct FolderField: View {
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
