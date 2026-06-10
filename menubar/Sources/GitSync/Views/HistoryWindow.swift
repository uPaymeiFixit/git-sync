import SwiftUI

struct HistoryWindow: View {
    @EnvironmentObject private var history: HistoryStore
    @State private var selected: RunRecord.ID?

    var body: some View {
        NavigationSplitView {
            List(history.runs, selection: $selected) { run in
                RunRow(run: run).tag(run.id)
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            if let id = selected, let run = history.runs.first(where: { $0.id == id }) {
                RunDetail(run: run)
            } else if history.runs.isEmpty {
                ContentUnavailableView(
                    "No runs yet",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("History appears here after the first sync completes."))
            } else {
                ContentUnavailableView(
                    "Select a run",
                    systemImage: "arrow.left",
                    description: Text("Pick a run from the list to see its outcomes and logs."))
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        .onAppear {
            // Auto-select the newest run so opening the window goes straight
            // to useful content instead of the "Select a run" placeholder.
            if selected == nil { selected = history.runs.first?.id }
            bringWindowToFront()
        }
    }
}

private struct RunRow: View {
    let run: RunRecord
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(run.startedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.headline)
            HStack(spacing: 8) {
                if let dur = duration {
                    Label(dur, systemImage: "clock")
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if anomalyCount > 0 {
                    Label("\(anomalyCount)", systemImage: "exclamationmark.triangle")
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var anomalyCount: Int { run.outcomes.filter(\.status.isAnomaly).count }

    private var duration: String? {
        guard let end = run.endedAt else { return nil }
        let seconds = Int(end.timeIntervalSince(run.startedAt))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

// Stable layout: header at top, outcomes table (or placeholder) in the
// middle, log pinned to the bottom with its own reserved height. Avoids
// the prior DisclosureGroup-in-VStack trap where the placeholder
// ContentUnavailableView swallowed all the spare vertical space and the
// disclosure had nowhere to expand into.
private struct RunDetail: View {
    let run: RunRecord
    @State private var showLog: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Divider()
            outcomesSection
            if !run.logLines.isEmpty {
                Divider()
                logSection
            }
        }
        .padding()
    }

    @ViewBuilder
    private var outcomesSection: some View {
        if run.outcomes.isEmpty {
            VStack(alignment: .center, spacing: 8) {
                Image(systemName: "tray")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("No outcomes recorded").font(.headline)
                Text("This run didn't produce any outcome events. Look at the log below for the script's output.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 24)
        } else {
            Table(run.outcomes) {
                TableColumn("Status") { o in
                    Label(o.status.displayName, systemImage: o.status.sfSymbol)
                        .foregroundStyle(o.status.isAnomaly ? .orange : .primary)
                }
                .width(min: 130, ideal: 150)
                TableColumn("Repo") { o in Text(o.rel).font(.system(.body, design: .monospaced)) }
                TableColumn("Detail") { o in Text(o.detail).foregroundStyle(.secondary) }
            }
        }
    }

    @ViewBuilder
    private var logSection: some View {
        HStack {
            Button {
                showLog.toggle()
            } label: {
                Label(
                    "Log (\(run.logLines.count) lines)",
                    systemImage: showLog ? "chevron.down" : "chevron.right"
                )
            }
            .buttonStyle(.plain)
            Spacer()
        }
        if showLog {
            ScrollView {
                Text(run.logLines.joined(separator: "\n"))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            }
            .frame(minHeight: 120, maxHeight: 220)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(run.startedAt.formatted(date: .complete, time: .shortened))
                    .font(.headline)
                if let end = run.endedAt {
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
