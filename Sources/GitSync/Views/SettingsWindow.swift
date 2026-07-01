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
        .onAppear { bringAppWindowsToFront() }
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
    @EnvironmentObject private var updater: SparkleUpdater
    @State private var launchAtLogin: Bool = LaunchAtLogin.isEnabled

    // The single on/off that used to be the "Manual / Every N / Daily" picker.
    // With "Daily at time" gone, the choice is binary — automatic or not — so a
    // checkbox reads cleaner than a segmented control. On ⇒ .everyNHours,
    // off ⇒ .manualOnly. The interval stepper below it is the only knob.
    private var autoSync: Binding<Bool> {
        Binding(
            get: { settings.scheduleMode == .everyNHours },
            set: { settings.scheduleMode = $0 ? .everyNHours : .manualOnly }
        )
    }

    var body: some View {
        Form {
            Section("Sync") {
                Toggle("Sync automatically", isOn: autoSync)
                    .toggleStyle(.checkbox)
                LabeledContent("Every") {
                    Stepper(value: $settings.scheduleHours, in: 1...168) {
                        Text("\(settings.scheduleHours) hour(s)")
                    }
                }
                .disabled(settings.scheduleMode != .everyNHours)
                Text(settings.scheduleMode == .everyNHours
                     ? "Missed runs (Mac asleep or off) catch up automatically on the next wake or launch."
                     : "Syncs only when you click “Run now”.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Updates") {
                Toggle("Check for updates automatically", isOn: $updater.automaticallyChecks)
                    .toggleStyle(.checkbox)
                Text("Checks in the background and offers new versions as they’re released. You can always check manually from the menu.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Startup") {
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
