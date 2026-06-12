import SwiftUI

// Primary detail window for GitSync. Lists every repository the app
// knows about — locally cloned, remote-known-but-not-cloned, skipped,
// stale, errored — with searchable + filterable navigation and
// per-repo actions.
//
// The view is intentionally read-only over InventoryStore; mutations
// flow through AppState (syncRepo) or SettingsStore (add to skip list).
struct RepositoriesView: View {
    @EnvironmentObject private var inventory: InventoryStore
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var settings: SettingsStore

    @State private var searchText: String = ""
    @State private var enabledStatuses: Set<SyncStatus> = Set(SyncStatus.allCases)
    @State private var enabledPlatforms: Set<String> = ["gitlab", "github", "bitbucket"]
    @State private var collapsedSections: Set<SyncStatus> = []

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if filteredRepos.isEmpty {
                ContentUnavailableView(
                    inventory.repos.isEmpty ? "No repositories yet" : "Nothing matches",
                    systemImage: inventory.repos.isEmpty
                        ? "tray" : "magnifyingglass",
                    description: Text(inventory.repos.isEmpty
                        ? "Run a sync to populate the inventory. The repos you have access to will appear here."
                        : "Adjust the search or filter chips above.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                repoList
            }
        }
        .frame(minWidth: 820, minHeight: 540)
        .onAppear { bringWindowToFront() }
    }

    // MARK: - Toolbar (search + filters)

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search by path", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Text("\(filteredRepos.count) of \(inventory.repos.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            HStack(spacing: 8) {
                ForEach(statusOrder, id: \.self) { status in
                    let count = countByStatus[status] ?? 0
                    if count > 0 {
                        FilterChip(
                            label: status.displayName,
                            count: count,
                            isOn: enabledStatuses.contains(status),
                            color: status.color
                        ) {
                            toggle(status: status)
                        }
                    }
                }
                Spacer()
                ForEach(["gitlab", "github", "bitbucket"], id: \.self) { platform in
                    PlatformChip(platform: platform,
                                 isOn: enabledPlatforms.contains(platform)) {
                        togglePlatform(platform)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Repo list

    private var repoList: some View {
        List {
            ForEach(statusOrder, id: \.self) { status in
                let group = groupedFiltered[status] ?? []
                if !group.isEmpty {
                    Section {
                        if !collapsedSections.contains(status) {
                            ForEach(group, id: \.id) { repo in
                                RepoRow(repo: repo)
                                    .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                            }
                        }
                    } header: {
                        Button {
                            if collapsedSections.contains(status) {
                                collapsedSections.remove(status)
                            } else {
                                collapsedSections.insert(status)
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: collapsedSections.contains(status)
                                      ? "chevron.right" : "chevron.down")
                                    .font(.caption)
                                Image(systemName: status.sfSymbol)
                                    .foregroundStyle(status.color)
                                Text(status.displayName)
                                    .font(.headline)
                                Text("(\(group.count))")
                                    .foregroundStyle(.secondary)
                                    .font(.subheadline)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                            .help(status.explanation)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    // MARK: - Filtering + grouping

    // Display order: anomalies first, then unchanged/cloned, then
    // not-cloned-yet, then skipped/empty.
    private var statusOrder: [SyncStatus] {
        [
            .error, .dirty, .diverged, .branchMissing, .updatedDirty,
            .staleOnDisk, .nonGitDir,
            .cloned, .updated, .upToDate,
            .notClonedYet, .emptyRemote, .skipped,
        ]
    }

    private var filteredRepos: [Repo] {
        let needle = searchText.lowercased()
        return inventory.repos.values.filter { repo in
            guard enabledPlatforms.contains(repo.id.platform) else { return false }
            guard enabledStatuses.contains(repo.effectiveStatus) else { return false }
            if needle.isEmpty { return true }
            return repo.id.rel.lowercased().contains(needle)
                || repo.id.platform.lowercased().contains(needle)
        }
    }

    private var groupedFiltered: [SyncStatus: [Repo]] {
        var groups: [SyncStatus: [Repo]] = [:]
        for repo in filteredRepos {
            groups[repo.effectiveStatus, default: []].append(repo)
        }
        for status in groups.keys {
            groups[status]?.sort { $0.id.rel.localizedCaseInsensitiveCompare($1.id.rel) == .orderedAscending }
        }
        return groups
    }

    private var countByStatus: [SyncStatus: Int] {
        var c: [SyncStatus: Int] = [:]
        for repo in inventory.repos.values where enabledPlatforms.contains(repo.id.platform) {
            c[repo.effectiveStatus, default: 0] += 1
        }
        return c
    }

    private func toggle(status: SyncStatus) {
        if enabledStatuses.contains(status) {
            enabledStatuses.remove(status)
        } else {
            enabledStatuses.insert(status)
        }
    }

    private func togglePlatform(_ p: String) {
        if enabledPlatforms.contains(p) {
            enabledPlatforms.remove(p)
        } else {
            enabledPlatforms.insert(p)
        }
    }
}

// MARK: - Row

private struct RepoRow: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var settings: SettingsStore
    let repo: Repo

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            statusPill
                .frame(width: 130, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(repo.id.rel)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(repo.id.platform)
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .foregroundStyle(.secondary)
                }
                if !repo.lastDetail.isEmpty {
                    Text(repo.lastDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let when = repo.lastUpdatedAt {
                    Text("Synced \(when.formatted(.relative(presentation: .named)))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Button {
                reveal()
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.plain)
            .help("Reveal in Finder")
        }
        .contentShape(Rectangle())
        .onTapGesture { reveal() }
        .contextMenu {
            Button("Sync this repo") {
                state.syncRepo(repo.id)
            }
            .disabled(state.isRunning)

            Button("Reveal in Finder") { reveal() }

            if !repo.sshURL.isEmpty {
                Button("Copy SSH URL") {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(repo.sshURL, forType: .string)
                }
            }

            Divider()

            Button("Add to skip list") {
                addToSkipList()
            }
            .disabled(isInSkipList)
        }
    }

    private var statusPill: some View {
        HStack(spacing: 4) {
            Image(systemName: repo.effectiveStatus.sfSymbol)
            Text(repo.effectiveStatus.displayName)
                .lineLimit(1)
        }
        .font(.caption)
        .foregroundStyle(repo.effectiveStatus.color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(repo.effectiveStatus.color.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .help(repo.effectiveStatus.explanation)
    }

    private func reveal() {
        let root = URL(fileURLWithPath:
            (settings.syncRoot as NSString).expandingTildeInPath)
        let platformDir: String
        switch repo.id.platform {
        case "gitlab":    platformDir = "Gitlab"
        case "github":    platformDir = "Github"
        case "bitbucket": platformDir = "Bitbucket"
        default:          platformDir = repo.id.platform.capitalized
        }
        let target = root
            .appendingPathComponent(platformDir, isDirectory: true)
            .appendingPathComponent(repo.id.rel)
        if FileManager.default.fileExists(atPath: target.path) {
            NSWorkspace.shared.activateFileViewerSelecting([target])
        } else {
            // Repo isn't on disk; fall back to opening the platform root
            // so the user can see what is there.
            NSWorkspace.shared.open(root.appendingPathComponent(platformDir, isDirectory: true))
        }
    }

    private var isInSkipList: Bool {
        let entries = settings.skipPatterns
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return entries.contains { entry in
            !entry.isEmpty && repo.id.rel.lowercased().hasPrefix(entry.lowercased())
        }
    }

    private func addToSkipList() {
        let trimmed = settings.skipPatterns.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            settings.skipPatterns = repo.id.rel
        } else {
            settings.skipPatterns = trimmed + ", " + repo.id.rel
        }
    }
}

// MARK: - Filter chip primitives

private struct FilterChip: View {
    let label: String
    let count: Int
    let isOn: Bool
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
                Text(label)
                Text("\(count)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(isOn ? color.opacity(0.18) : Color.secondary.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isOn ? color.opacity(0.6) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct PlatformChip: View {
    let platform: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(platform)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(isOn ? Color.accentColor.opacity(0.20) : Color.secondary.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
    }
}

// Bring the window to the front when opened from the menu bar. SwiftUI
// MenuBarExtra → Window doesn't activate the app, so the window opens
// behind whatever the user previously had focused.
@MainActor
private func bringWindowToFront() {
    DispatchQueue.main.async { @MainActor in
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.filter { $0.isVisible }.forEach { $0.orderFrontRegardless() }
    }
}
