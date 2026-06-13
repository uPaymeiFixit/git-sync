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
                Text("\(run.outcomes.count) repo(s) so far")
                    .font(.caption).foregroundStyle(.secondary)
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
    let run: RunRecord
    var isLive: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
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
                    Label("Running… \(run.outcomes.count) repo(s) so far",
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

@MainActor
private func bringWindowToFront() {
    DispatchQueue.main.async { @MainActor in
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.filter { $0.isVisible }.forEach { $0.orderFrontRegardless() }
    }
}
