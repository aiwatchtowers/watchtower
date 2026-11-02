import Foundation
import WatchtowerCore

extension AppState {
    /// Settings → Mobile over `watchtower hub …` (go hub plan 3 Task 23).
    /// Task 22 passes its adoption driver's state as `adoption`.
    func makeMobileSettingsModel() -> MobileSettingsModel {
        let runner = ProcessCLIRunner.makeDefault()
        return MobileSettingsModel(
            cli: runner,
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
