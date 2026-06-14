import SwiftUI

struct HistoryWindow: View {
    @EnvironmentObject private var history: HistoryStore
    @EnvironmentObject private var state: AppState
    @State private var selected: RunRecord.ID?

    // The in-progress full run (if any) shown live at the top, plus the
    // recorded history. A run is added to history only when it finishes, so
    // without this the running entry wouldn't appear until it completed.
    private var displayRuns: [RunRecord] {
        guard let live = state.currentRun else { return history.runs }
        // currentRun is finalized into history at the end, so once it lands
        // there we'd have a duplicate id — filter it out of the recorded list.
        return [live] + history.runs.filter { $0.id != live.id }
    }

    var body: some View {
        let runs = displayRuns
        NavigationSplitView {
            List(runs, selection: $selected) { run in
                RunRow(run: run, isLive: run.id == state.currentRun?.id).tag(run.id)
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            if let id = selected, let run = runs.first(where: { $0.id == id }) {
                RunDetail(run: run, isLive: run.id == state.currentRun?.id)
            } else if runs.isEmpty {
                ContentUnavailableView(
                    "No runs yet",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("History appears here when a sync starts."))
            } else {
                ContentUnavailableView(
                    "Select a run",
                    systemImage: "arrow.left",
                    description: Text("Pick a run from the list to see its outcomes and logs."))
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        .onAppear {
            if selected == nil { selected = runs.first?.id }
            bringWindowToFront()
        }
        // When a run starts, jump the selection to the live entry.
        .onChange(of: state.currentRun?.id) { _, liveID in
            if let liveID { selected = liveID }
        }
    }
}

private struct RunRow: View {
    let run: RunRecord
    var isLive: Bool = false
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if isLive {
                    ProgressView().controlSize(.small)
                }
                Text(isLive ? "Running…" : run.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.headline)
            }
            if isLive {
                Text(run.phaseLabel ?? "Starting…")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1)
                if run.outcomes.count > 0 {
                    Text("\(run.outcomes.count) repo(s) done")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            } else if let dur = duration {
                Label(dur, systemImage: "clock")
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var duration: String? {
        guard let end = run.endedAt else { return nil }
        let seconds = Int(end.timeIntervalSince(run.startedAt))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

// Run history is deliberately just a log viewer now. Per-repo state
// lives in the Repositories inventory; this window exists for "what did
// the script actually print during that run" debugging. Header (date +
// per-platform exit codes) + full-height scrollable log.
private struct RunDetail: View {
    @EnvironmentObject private var state: AppState
    let run: RunRecord
    var isLive: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if isLive {
                Divider()
                LiveActivityPanel()
            }
            Divider()
            logSection
        }
        .padding()
    }

    @ViewBuilder
    private var logSection: some View {
        if run.logLines.isEmpty {
            ContentUnavailableView(
                "No log output",
                systemImage: "text.alignleft",
                description: Text("This run produced no log lines."))
        } else {
            ScrollView {
                Text(run.logLines.joined(separator: "\n"))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(run.startedAt.formatted(date: .complete, time: .shortened))
                    .font(.headline)
                if isLive {
                    Label(run.phaseLabel ?? "Starting…",
                          systemImage: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.secondary).font(.caption)
                } else if let end = run.endedAt {
                    Text("Ended \(end.formatted(date: .omitted, time: .shortened))")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }
            Spacer()
            ForEach(Array(run.exitCodes.keys.sorted()), id: \.self) { platform in
                Label("\(platform): \(run.exitCodes[platform] ?? 0)",
                      systemImage: (run.exitCodes[platform] ?? -1) == 0 ? "checkmark.circle" : "minus.circle")
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// Live, per-repo activity for the in-flight run. Driven entirely by
// state.activeWorkers (populated by workerStart/workerPhase/workerFinish), so
// it shows exactly what every busy worker is doing right now: operation
// (clone/fetch), current git phase, percent, and how long it's been running.
// A wedge is now visible at a glance — workers sit frozen on a phase while
// their elapsed clock climbs.
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
                Text("Active workers")
                    .font(.subheadline.weight(.semibold))
                Text("\(workers.count)")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
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
                .frame(maxHeight: 180)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
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

@MainActor
private func bringWindowToFront() {
    DispatchQueue.main.async { @MainActor in
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.filter { $0.isVisible }.forEach { $0.orderFrontRegardless() }
    }
}
