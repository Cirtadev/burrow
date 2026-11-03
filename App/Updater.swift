import AppKit
import Sparkle

/// Sparkle 2. The feed is SUFeedURL in Info.plist (BURROW_FEED_URL in project.yml); every update must be signed
/// with the EdDSA key whose public half is SUPublicEDKey.
@MainActor
final class Updater {
    private let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil,
                                                          userDriverDelegate: nil)

    func checkForUpdates() {
        // A menu-bar app: come forward so Sparkle's window isn't hidden behind others.
        NSApp.activate()
        controller.checkForUpdates(nil)
    }
}
