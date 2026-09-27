import AppKit
import Sparkle

/// Sparkle wrapper. The feed lives at the SUFeedURL in Info.plist and points
/// at DMGs attached to GitHub Releases; scripts/release.sh regenerates it.
@MainActor
final class Updater {
    static let shared = Updater()

    private let controller: SPUStandardUpdaterController

    private init() {
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    var updater: SPUUpdater { controller.updater }

    var automaticallyChecks: Bool {
        get { updater.automaticallyChecksForUpdates }
        set { updater.automaticallyChecksForUpdates = newValue }
    }

    var automaticallyDownloads: Bool {
        get { updater.automaticallyDownloadsUpdates }
        set { updater.automaticallyDownloadsUpdates = newValue }
    }

    var lastCheck: Date? { updater.lastUpdateCheckDate }

    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }
}
