import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var currentRun: RunRecord?
    @Published var lastRun: RunRecord?
    @Published var dismissedRunID: UUID?

    var isRunning: Bool { currentRun != nil }

    var anomalyCount: Int {
        (lastRun?.outcomes ?? []).filter(\.status.isAnomaly).count
    }

    var showsAttention: Bool {
        guard let lastRun, anomalyCount > 0 else { return false }
        return dismissedRunID != lastRun.id
    }

    var menuBarIconName: String {
        if isRunning { return "arrow.triangle.2.circlepath" }
        if showsAttention { return "exclamationmark.triangle" }
        return "arrow.triangle.2.circlepath"
    }

    func dismissCurrentNotification() {
        dismissedRunID = lastRun?.id
    }
}
