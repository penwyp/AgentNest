import Foundation
import Sparkle

@MainActor
final class UpdateController: NSObject, SPUUpdaterDelegate {
    private var controller: SPUStandardUpdaterController?

    override init() {
        super.init()
        guard let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let url = URL(string: feed),
              url.scheme == "https",
              (Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String)?.isEmpty == false else {
            return
        }
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
    }

    var isConfigured: Bool { controller != nil }
    var sessionInProgress: Bool { controller?.updater.sessionInProgress == true }
    var canCheckForUpdates: Bool { controller?.updater.canCheckForUpdates == true }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        controller?.checkForUpdates(nil)
    }
}
