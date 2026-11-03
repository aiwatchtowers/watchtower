import Foundation
import WatchtowerCore
import WatchtowerSync

extension AppState {
    /// Starts the one-time hand-over of Mobile to the Go hub (go hub plan 3
    /// Task 22), once per app run, in its own task: it first waits for the
    /// v1-host restart, and neither the launch nor the UI waits for it.
    func startHubAdoption() {
        guard hubAdoption == nil else { return }
        let driver = liveHubAdoptionDriver()
        hubAdoption = driver
        Task { _ = await driver.run() }
    }

    /// Settings → Mobile's **Retry** after a failed hand-over.
    func retryHubAdoption() {
        guard let driver = hubAdoption else { return }
        Task { _ = await driver.retry() }
    }

    /// Settings → Mobile's **Set up Mobile again**, once the owner confirmed.
    func setUpMobileAgain() {
        guard let driver = hubAdoption else { return }
        Task { _ = await driver.setUpAgain() }
    }

    private func liveHubAdoptionDriver() -> HubAdoptionDriver {
        let deps = hubAdoptionDeps ?? HubAdoptionDeps(
            runner: Constants.findCLIPath().map { ProcessHubAdoptRunner(binaryPath: $0) },
            keyStore: KeychainHubKeyStore(backend: SecItemKeychainBackend())
        )
        let recorder = meetingRecorderCenter
        return HubAdoptionDriver(seams: .init(
            waitForHostRestart: { [weak self] in await self?.hostRestart?.waitUntilSettled() },
            cancelPhoneRecordings: { await recorder.cancelPhoneRecordingJobs(audioNames: $0) },
            phoneRecordingsAdopted: { await recorder.forgetPhoneRecordings(audioNames: $0) },
            releasePhoneRecordings: { await recorder.releasePhoneRecordings(audioNames: $0) },
            deps: deps,
            settings: { [weak self] in
                self?.hubAdoptSettings() ?? HubAdoptSettings(enabled: false, startSessionAllows: [:])
            },
            settingsDelivered: { [weak self] in
                self?.mobileSyncDefaults.removeObject(forKey: Constants.mobileSyncEnabledKey)
            }
        ))
    }

    /// The owner's settings the Go hub takes at the hand-over: the stored
    /// toggle as the owner left it (the Go hub applies `MobileSync` itself),
    /// read once. The phones' start-sessions grants live in the Swift hub's
    /// own state, which the Go hub copies, so Desktop adds none.
    func hubAdoptSettings() -> HubAdoptSettings {
        HubAdoptSettings(enabled: mobileSyncDefaults.bool(forKey: Constants.mobileSyncEnabledKey), startSessionAllows: [:])
    }
}
