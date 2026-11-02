import Foundation
import WatchtowerCore

extension AppState {
    /// Settings → Mobile over `watchtower hub …` (go hub plan 3 Task 23),
    /// with the hand-over to the Go hub (Task 22) read through the app.
    func makeMobileSettingsModel() -> MobileSettingsModel {
        let runner = ProcessCLIRunner.makeDefault()
        return MobileSettingsModel(
            cli: runner,
            adoption: self,
            pairStreamer: runner.map { HubPairCLIStreamer(binaryPath: $0.binaryPath) },
            showsCorpNotice: Self.isCorpBuild()
        )
    }

    /// A corporate build (`WTBuildFlavor` stamped by build-app.sh, anything
    /// but absent or `dev`): Settings → Mobile says where work data goes.
    nonisolated static func isCorpBuild(_ flavor: String? = Bundle.main.object(forInfoDictionaryKey: "WTBuildFlavor") as? String) -> Bool {
        let flavor = flavor ?? ""
        return !flavor.isEmpty && flavor != "dev"
    }
}

/// The hand-over of Mobile to the Go hub as Settings → Mobile reads it: the
/// driver's state (none started: nothing to show) and its Retry.
extension AppState: MobileAdoptionSource {
    var adoptionState: HubAdoptionState { hubAdoption?.state ?? .notNeeded }

    func retryAdoption() async {
        _ = await hubAdoption?.retry()
    }
}
