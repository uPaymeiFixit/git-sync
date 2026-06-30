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

    init() {
        // startingUpdater: true begins the updater immediately (it reads
        // Info.plist's SUFeedURL / SUPublicEDKey). No custom delegate needed —
        // the standard driver covers the whole UX.
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

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
