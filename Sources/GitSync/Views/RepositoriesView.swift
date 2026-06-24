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
    @EnvironmentObject private var providers: ProviderStore
    @Environment(\.openWindow) private var openWindow

    @State private var searchText: String = ""
    @State private var enabledStatuses: Set<SyncStatus> = Set(SyncStatus.allCases)
    @State private var enabledPlatforms: Set<String> = Set(Platform.allCases.map(\.rawValue))
    @State private var collapsedSections: Set<SyncStatus> = []
    @State private var selection: Set<RepoID> = []
    @State private var pendingTrash: Set<RepoID> = []
    @State private var showTrashConfirm = false
    @State private var trashSummary: String?

    var body: some View {
        // The filter → group → sort pipeline is O(N log N) over ~2,000
        // repos. Hoist it so each body evaluation runs it exactly once —
        // referencing the computed property inside the per-status ForEach
        // used to re-run the whole pipeline once per status section (14×),
        // which made the window visibly sluggish whenever state changed
        // (selection clicks, search keystrokes, 10Hz inventory updates
        // during a sync).
        let groups = groupedFiltered
        let visibleCount = groups.values.reduce(0) { $0 + $1.count }
        let chipCounts = countByStatus
        VStack(spacing: 0) {
            // While a full run is in flight, show the live worker activity at
            // the top — this is where you watch progress and spot a wedge (a
            // worker stuck on one phase while its clock climbs). It collapses
            // to nothing between runs.
            if state.isRunning {
                LiveActivityPanel()
                Divider()
            }
            toolbar(visibleCount: visibleCount, chipCounts: chipCounts)
            Divider()
            if visibleCount == 0 {
                if inventory.repos.isEmpty && !providers.isConfigured {
                    // Fresh, unconfigured install: point at setup, not "run a
                    // sync" (which would do nothing with no platform configured).
                    ContentUnavailableView {
                        Label("Not set up yet", systemImage: "gearshape")
                    } description: {
                        Text("Configure at least one platform so GitSync knows what to sync.")
                    } actions: {
                        Button("Set Up GitSync…") {
                            openWindow(id: "onboarding")
                            NSApp.activate(ignoringOtherApps: true)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView(
                        inventory.repos.isEmpty ? "No repositories yet" : "Nothing matches",
                        systemImage: inventory.repos.isEmpty
                            ? "tray" : "magnifyingglass",
                        description: Text(inventory.repos.isEmpty
                            ? "Run a sync to populate the inventory. The repos you have access to will appear here."
                            : "Adjust the search or filter chips above.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                repoList(groups: groups)
            }
        }
        .frame(minWidth: 820, minHeight: 540)
        .onAppear { bringAppWindowsToFront() }
    }

    // MARK: - Toolbar (search + filters)

    private func toolbar(visibleCount: Int, chipCounts: [SyncStatus: Int]) -> some View {
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
                Text("\(visibleCount) of \(inventory.repos.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            HStack(spacing: 8) {
                ForEach(statusOrder, id: \.self) { status in
                    let count = chipCounts[status] ?? 0
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
                ForEach(Platform.allCases, id: \.rawValue) { platform in
                    PlatformChip(platform: platform.rawValue,
                                 isOn: enabledPlatforms.contains(platform.rawValue)) {
                        togglePlatform(platform.rawValue)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Repo list

    private func repoList(groups: [SyncStatus: [Repo]]) -> some View {
        List(selection: $selection) {
            ForEach(statusOrder, id: \.self) { status in
                let group = groups[status] ?? []
                if !group.isEmpty {
                    Section {
                        if !collapsedSections.contains(status) {
                            ForEach(group, id: \.id) { repo in
                                RepoRow(repo: repo)
                                    .tag(repo.id)
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
        // Right-click acts on the current multi-selection (or on just the
        // row under the cursor when it isn't part of the selection).
        .contextMenu(forSelectionType: RepoID.self) { ids in
            contextMenuItems(for: ids)
        }
        // Delete key on a selection = same flow as the context-menu item.
        .onDeleteCommand {
            guard !selection.isEmpty else { return }
            requestTrash(selection)
        }
        .alert(
            "Move \(pendingTrash.count) repo(s) to Trash?",
            isPresented: $showTrashConfirm
        ) {
            Button("Move to Trash", role: .destructive) {
                let ids = pendingTrash
                Task {
                    let report = await state.deleteLocalRepos(ids)
                    selection.subtract(ids)
                    trashSummary = report.summary
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Repos with uncommitted changes or unpushed commits are skipped automatically. Everything else goes to the Trash, where it can be restored.")
        }
        .alert(
            "Done",
            isPresented: Binding(
                get: { trashSummary != nil },
                set: { if !$0 { trashSummary = nil } }
            )
        ) {
            Button("OK") { trashSummary = nil }
        } message: {
            Text(trashSummary ?? "")
        }
    }

    @ViewBuilder
    private func contextMenuItems(for ids: Set<RepoID>) -> some View {
        if ids.count == 1, let id = ids.first, let repo = inventory.repos[id] {
            Button("Sync this repo") { state.syncRepo(id) }
                .disabled(state.isRunning || state.isSyncing(id))
            if state.isTrackedOnly(repoID: id) {
                if repo.isTracked {
                    Button("Untrack this repo") { state.setTracked([id], false) }
                } else {
                    Button("Track this repo") { state.setTracked([id], true) }
                }
            }
            Button("Reveal in Finder") { RepoActions.reveal(target: state.diskPath(for: repo.id)) }
            if !repo.sshURL.isEmpty {
                Button("Copy SSH URL") {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(repo.sshURL, forType: .string)
                }
            }
            Divider()
            Button("Add to skip list") {
                RepoActions.addToSkipList(repo: repo, providers: providers)
            }
            .disabled(RepoActions.isInSkipList(repo: repo, providers: providers))
            if repo.isClonedLocally {
                Button("Move to Trash…", role: .destructive) {
                    requestTrash([id])
                }
            }
        } else if !ids.isEmpty {
            let onDisk = ids.filter { inventory.repos[$0]?.isClonedLocally == true }
            // Bulk track/untrack for selections whose platforms are in
            // whitelist mode (a mixed selection just acts on the eligible ones).
            let trackable = ids.filter { state.isTrackedOnly(repoID: $0) }
            if !trackable.isEmpty {
                Button("Track \(trackable.count) repo(s)") { state.setTracked(trackable, true) }
                Button("Untrack \(trackable.count) repo(s)") { state.setTracked(trackable, false) }
                Divider()
            }
            Button("Add \(ids.count) to skip list") {
                for id in ids {
                    if let repo = inventory.repos[id],
                       !RepoActions.isInSkipList(repo: repo, providers: providers) {
                        RepoActions.addToSkipList(repo: repo, providers: providers)
                    }
                }
            }
            if !onDisk.isEmpty {
                Button("Move \(onDisk.count) to Trash…", role: .destructive) {
                    requestTrash(Set(onDisk))
                }
            }
        }
    }

    private func requestTrash(_ ids: Set<RepoID>) {
        pendingTrash = ids
        showTrashConfirm = true
    }

    // MARK: - Filtering + grouping

    // Display order: anomalies first, then unchanged/cloned, then the
    // unknowns (on-disk-unsynced, remote-only), then skipped/empty.
    private var statusOrder: [SyncStatus] {
        [
            .error, .dirty, .diverged, .branchMissing, .updatedDirty,
            .staleOnDisk, .nonGitDir, .trackedGone,
            .cloned, .updated, .upToDate,
            .notSyncedYet, .notClonedYet, .untracked, .emptyRemote, .skipped,
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
    @EnvironmentObject private var providers: ProviderStore
    let repo: Repo

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            statusPill
                .frame(width: 130, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(boldedLeafPath)
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
            // Row actions. Clicking the row itself only selects it; these
            // buttons (and the context menu) are how you act on a repo.
            HStack(spacing: 12) {
                // Track toggle — only meaningful (and shown) when this repo's
                // platform is in whitelist mode. Star = tracked.
                if state.isTrackedOnly(repoID: repo.id) {
                    Button {
                        state.setTracked([repo.id], !repo.isTracked)
                    } label: {
                        Image(systemName: repo.isTracked ? "star.fill" : "star")
                            .foregroundStyle(repo.isTracked ? Color.yellow : Color.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help(repo.isTracked ? "Tracked — click to stop syncing this repo" : "Track — keep this repo synced")
                }
                Button {
                    state.syncRepo(repo.id)
                } label: {
                    // Spin THIS repo's button while it's syncing, instead of
                    // greying everything: other repos stay clickable so you
                    // can fire off several in parallel.
                    if state.isSyncing(repo.id) {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                }
                .buttonStyle(.borderless)
                .help(syncButtonHelp)
                // Disabled only when a full run is active (individual syncs
                // are locked out then) or this exact repo is already syncing.
                .disabled(state.isRunning || state.isSyncing(repo.id))

                Button {
                    addToSkipList()
                } label: {
                    Image(systemName: "nosign")
                }
                .buttonStyle(.borderless)
                .help(isInSkipList ? "Already in skip list" : "Add to skip list")
                .disabled(isInSkipList)

                Button {
                    RepoActions.reveal(target: state.diskPath(for: repo.id))
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("Reveal in Finder")
            }
        }
        // Context menu lives on the List (forSelectionType:) so it can act
        // on multi-selections; no per-row menu here.
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

    // The full repo path with only its leaf (the repo name itself) bolded, e.g.
    // development/.../event-list/**next-event-list**. Kept as one AttributedString
    // in a single Text so lineLimit(1)/truncationMode(.middle) still apply to the
    // path as a whole.
    private var boldedLeafPath: AttributedString {
        var attributed = AttributedString(repo.id.rel)
        if let slash = repo.id.rel.lastIndex(of: "/") {
            let leafStart = repo.id.rel.index(after: slash)
            if let lower = AttributedString.Index(leafStart, within: attributed) {
                attributed[lower...].font = .system(.body, design: .monospaced).weight(.bold)
            }
        } else {
            // No slash: the whole rel is the repo name — bold all of it.
            attributed.font = .system(.body, design: .monospaced).weight(.bold)
        }
        return attributed
    }

    private var syncButtonHelp: String {
        if state.isRunning { return "A full sync is running" }
        if state.isSyncing(repo.id) { return "Syncing…" }
        return "Sync this repo"
    }

    private var isInSkipList: Bool {
        RepoActions.isInSkipList(repo: repo, providers: providers)
    }

    private func addToSkipList() {
        RepoActions.addToSkipList(repo: repo, providers: providers)
    }
}

// Shared repo actions, used by both the row buttons and the List-level
// multi-selection context menu.
@MainActor
enum RepoActions {
    // `target` is the repo's resolved on-disk path (AppState.diskPath(for:),
    // which knows each provider's folder). Reveal it, or fall back to its
    // parent so the user lands somewhere sensible if it isn't cloned yet.
    static func reveal(target: URL?) {
        guard let target else { return }
        if FileManager.default.fileExists(atPath: target.path) {
            NSWorkspace.shared.activateFileViewerSelecting([target])
        } else {
            let parent = target.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: parent.path) {
                NSWorkspace.shared.open(parent)
            }
        }
    }

    // Skip patterns are PER-PROVIDER: the engine builds its SkipMatcher from the
    // repo's parent Provider.skipPatterns (SyncEngine via SkipMatcher), so these
    // must read/write that provider — not the legacy global settings.skipPatterns,
    // which the engine no longer reads. Matching uses the platform's namespace
    // path (no "Gitlab/" prefix), mirroring SkipMatcher in PlatformDiscovery.
    static func isInSkipList(repo: Repo, providers: ProviderStore) -> Bool {
        guard let pid = UUID(uuidString: repo.id.providerID) else { return false }
        return providers.isSkipped(namespacePath: repo.id.namespacePath, providerID: pid)
    }

    static func addToSkipList(repo: Repo, providers: ProviderStore) {
        guard let pid = UUID(uuidString: repo.id.providerID) else { return }
        providers.addSkipPattern(repo.id.namespacePath, providerID: pid)
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

// MARK: - Live run activity

// Live, per-repo activity for the in-flight full run. Driven entirely by
// state.activeWorkers (populated by workerStart/workerPhase/workerFinish), so
// it shows exactly what every busy worker is doing right now: operation
// (clone/fetch), current git phase, percent, and how long it's been running.
// A wedge is visible at a glance — workers sit frozen on a phase while their
// elapsed clock climbs. (Previously lived in the now-removed Run history
// window; the persistent record moved to the unified log.)
private struct LiveActivityPanel: View {
    @EnvironmentObject private var state: AppState
    // Ticks once a second purely to refresh the elapsed-time column.
    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    // Flatten activeWorkers into a sorted list, longest-running first (the
    // most likely culprit if something is stuck).
    private var workers: [LiveWorker] {
        state.activeWorkers.flatMap { platform, repos in
            repos.map { LiveWorker(platform: platform, rel: $0.key, w: $0.value) }
        }
        .sorted { $0.w.startedAt < $1.w.startedAt }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(state.currentRun?.phaseLabel ?? "Running…")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(workers.count) active")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
                Button("Cancel") { state.cancelRun() }
                    .controlSize(.small)
            }
            if workers.isEmpty {
                Text("No workers running right now (discovering / warming / scanning).")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(workers) { item in
                            WorkerRow(item: item, now: now)
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 150)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .onReceive(tick) { now = $0 }
    }
}

// One in-flight worker, identified by (platform, rel) so the same rel under
// two platforms (e.g. a mirrored repo) doesn't collide as a SwiftUI id.
private struct LiveWorker: Identifiable {
    let platform: String
    let rel: String
    let w: WorkerView
    var id: String { platform + "\u{1F}" + rel }
}

private struct WorkerRow: View {
    let item: LiveWorker
    let now: Date

    private var elapsed: String {
        let s = max(0, Int(now.timeIntervalSince(item.w.startedAt)))
        return s >= 60 ? String(format: "%d:%02d", s / 60, s % 60) : "\(s)s"
    }
    // Anything sitting in one phase for a long time is the likely wedge.
    private var isStalled: Bool { now.timeIntervalSince(item.w.startedAt) > 60 }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: item.w.op == "clone" ? "arrow.down.circle" : "arrow.triangle.2.circlepath")
                .foregroundStyle(.secondary)
                .font(.caption)
            Text(item.rel)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1).truncationMode(.head)
            Spacer(minLength: 8)
            Text(item.w.phase + (item.w.pct.map { " \($0)%" } ?? ""))
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(1)
            Text(elapsed)
                .font(.caption.monospacedDigit())
                .foregroundStyle(isStalled ? .orange : .secondary)
                .frame(minWidth: 38, alignment: .trailing)
        }
    }
}
