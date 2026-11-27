import AppKit
import Sparkle
import SwiftUI

/// Updates from GitHub Releases with Sparkle, in release builds only: scripts/release.sh puts the feed
/// (SUFeedURL) and its public key in Info.plist. A build from source has neither and never checks.
@MainActor
enum Updates {
    static let controller: SPUStandardUpdaterController? = {
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil,
            Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String != "" else { return nil }
        return SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }()
}

struct CheckForUpdatesButton: View {
    var body: some View {
        if let c = Updates.controller {
            Button("Check for Updates…") { c.checkForUpdates(nil) }
        }
    }
}
