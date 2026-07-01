import Foundation
import Sparkle

// In-app auto-update, backed by Sparkle. Replaces the old UpdateChecker, which
// could only open the release page in a browser. Sparkle downloads, verifies
// (EdDSA signature against SUPublicEDKey in Info.plist), swaps the bundle, and
// relaunches — all in-app.
//
// We use the EdDSA signature as the trust anchor, NOT Apple notarization: the
// app is self-signed, and every release zip is signed with the private key
// whose public half is baked into Info.plist. An update that isn't signed by
// that key is refused. That's what makes auto-update safe without a Developer
// ID / notarization (see Tools/sparkle-sign.sh + the appcast).
//
// SPUStandardUpdaterController owns the SPUUpdater + the standard user-facing
// UI driver (the "Update available" window, progress, "you're up to date"
// alert). We wrap it in an ObservableObject so SwiftUI menu items can drive a
// check and disable themselves while one is in flight.
@MainActor
final class SparkleUpdater: ObservableObject {
    private let controller: SPUStandardUpdaterController

    // canCheckForUpdates is KVO-observed by Sparkle; mirror it into a @Published
    // so the menu item can disable while a check/download is running.
    @Published private(set) var canCheck = true
    private var observation: NSKeyValueObservation?

    // Whether Sparkle checks for updates on its own schedule (background). This
    // is Sparkle's OWN persisted preference (app UserDefaults, SUEnableAutomaticChecks
    // key) — we don't store it ourselves; we just mirror it into a @Published so
    // a SwiftUI Toggle can bind to it. Info.plist ships SUEnableAutomaticChecks=false,
    // so the default is off; flipping this Toggle is what turns background checks on.
    @Published var automaticallyChecks: Bool {
        didSet {
            // Also fires when we mirror Sparkle→us in init; the guard keeps that
            // from being a redundant write (harmless, but avoids churn).
            if controller.updater.automaticallyChecksForUpdates != automaticallyChecks {
                controller.updater.automaticallyChecksForUpdates = automaticallyChecks
            }
        }
    }

    init() {
        // startingUpdater: true begins the updater immediately (it reads
        // Info.plist's SUFeedURL / SUPublicEDKey). No custom delegate needed —
        // the standard driver covers the whole UX.
        let controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        // Seed from Sparkle's current (persisted) preference before any @Published
        // observers run, so the Toggle opens showing the real state.
        self.automaticallyChecks = controller.updater.automaticallyChecksForUpdates

        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) {
            [weak self] updater, _ in
            // KVO can fire off the main thread; hop back for the @Published.
            Task { @MainActor in self?.canCheck = updater.canCheckForUpdates }
        }
    }

    // The menu's "Check for updates…" — shows Sparkle's standard UI (progress,
    // the update sheet, or "You're up to date").
    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }
}
