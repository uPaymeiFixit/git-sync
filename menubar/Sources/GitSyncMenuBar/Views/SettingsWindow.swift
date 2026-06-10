import SwiftUI

struct SettingsWindow: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        TabView {
            PathsTab().tabItem { Label("Paths", systemImage: "folder") }
            GitLabTab().tabItem { Label("GitLab", systemImage: "g.circle") }
            GitHubTab().tabItem { Label("GitHub", systemImage: "g.square") }
            BitbucketTab().tabItem { Label("Bitbucket", systemImage: "b.square") }
            BehaviorTab().tabItem { Label("Behavior", systemImage: "slider.horizontal.3") }
            ScheduleTab().tabItem { Label("Schedule", systemImage: "clock") }
        }
        .frame(width: 520, height: 360)
        .padding()
    }
}

private struct PathsTab: View {
    @EnvironmentObject private var settings: SettingsStore
    var body: some View {
        Form {
            FolderPickerRow(label: "Sync root",
                            help: "Where mirrored repos are cloned to. Gitlab/, Bitbucket/, Github/ subdirectories are created underneath.",
                            value: $settings.syncRoot)
            FolderPickerRow(label: "Scripts directory",
                            help: "Path to the scripts/ directory in your git-sync checkout.",
                            value: $settings.scriptsDirectory)
            LabeledContent("Python interpreter") {
                TextField("", text: $settings.pythonPath)
                    .textFieldStyle(.roundedBorder)
            }
            Text("Needs Python 3.9+. Default /usr/bin/python3 on macOS 14+ works. Point at Homebrew/pyenv if you need a different one.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct GitLabTab: View {
    @EnvironmentObject private var settings: SettingsStore
    var body: some View {
        Form {
            LabeledContent("GitLab host") {
                TextField("gitlab.example.com", text: $settings.gitlabHost)
                    .textFieldStyle(.roundedBorder)
            }
            Toggle("Skip GitLab", isOn: $settings.skipGitlab)
            Text("Auth lives in glab's config. Run `glab auth login --hostname <host>` once if you haven't.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct GitHubTab: View {
    @EnvironmentObject private var settings: SettingsStore
    var body: some View {
        Form {
            LabeledContent("Organization") {
                TextField("your-github-org", text: $settings.githubOrg)
                    .textFieldStyle(.roundedBorder)
            }
            LabeledContent("Personal access token") {
                SecureField("", text: $settings.githubToken)
                    .textFieldStyle(.roundedBorder)
            }
            Toggle("Skip GitHub", isOn: $settings.skipGithub)
            Text("Token stored in Keychain. Needs 'repo' (classic) or Contents+Metadata read (fine-grained).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct BitbucketTab: View {
    @EnvironmentObject private var settings: SettingsStore
    var body: some View {
        Form {
            LabeledContent("Workspace") {
                TextField("your-workspace-slug", text: $settings.bitbucketWorkspace)
                    .textFieldStyle(.roundedBorder)
            }
            LabeledContent("Username") {
                TextField("", text: $settings.bitbucketUser)
                    .textFieldStyle(.roundedBorder)
            }
            LabeledContent("App password") {
                SecureField("", text: $settings.bitbucketAppPassword)
                    .textFieldStyle(.roundedBorder)
            }
            Toggle("Skip Bitbucket", isOn: $settings.skipBitbucket)
            Text("Credentials stored in Keychain. App password needs read:repository:bitbucket scope.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct BehaviorTab: View {
    @EnvironmentObject private var settings: SettingsStore
    var body: some View {
        Form {
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
            LabeledContent("Skip patterns") {
                TextField("comma-separated prefixes", text: $settings.skipPatterns,
                          axis: .vertical)
                    .lineLimit(2...4)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }
}

private struct ScheduleTab: View {
    @EnvironmentObject private var settings: SettingsStore
    var body: some View {
        Form {
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

            Divider()
            Text("Scheduled runs fire only while this app is running. Enable Launch at Login in the menu to keep it open across reboots.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct FolderPickerRow: View {
    let label: String
    let help: String
    @Binding var value: String

    var body: some View {
        VStack(alignment: .leading) {
            LabeledContent(label) {
                HStack {
                    TextField("", text: $value)
                        .textFieldStyle(.roundedBorder)
                    Button("Choose…") { pickFolder() }
                }
            }
            Text(help).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if !value.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: value)
        }
        if panel.runModal() == .OK, let url = panel.url {
            value = url.path
        }
    }
}
