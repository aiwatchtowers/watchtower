import XCTest
@testable import WatchtowerDesktop

/// Settings → Features' cascade dialog says that disabling only Slack
/// Digests stops Tracks and People Cards too (#575).
@MainActor
final class FeatureCascadeMessageTests: XCTestCase {
    func testDisablingDigestsNamesWhatStopsRunning() {
        let dependents = [
            FeatureDependents.Dependent(id: "tracks", title: "Tracks"),
            FeatureDependents.Dependent(id: "people-cards", title: "People Cards"),
            FeatureDependents.Dependent(id: "ideas", title: "Ideas & Decisions")
        ]
        XCTAssertEqual(
            FeatureManagerSection.cascadeMessage(featureID: "slack-digests", dependents: dependents),
            "This also affects: Tracks, People Cards, Ideas & Decisions\n"
                + "Tracks and People Cards stop running too while Slack Digests is off.")
        XCTAssertEqual(
            FeatureManagerSection.cascadeMessage(featureID: "slack-digests", dependents: [dependents[2]]),
            "This also affects: Ideas & Decisions")
        XCTAssertEqual(
            FeatureManagerSection.cascadeMessage(featureID: "memory", dependents: dependents),
            "This also affects: Tracks, People Cards, Ideas & Decisions")
    }
}
