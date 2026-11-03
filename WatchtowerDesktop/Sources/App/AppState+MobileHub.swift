import AppKit
import WatchtowerCore
import WatchtowerSync

extension AppState {
    /// Starts the one-time hand-over of Mobile to the Go hub (go hub plan 3
    /// Task 22), once per app run, in its own task: it first waits for the
    /// v1-host restart, and neither the launch nor the UI waits for it.
    /// Under XCTest nothing starts unless the test injected
    /// `hubAdoptionDeps`: a unit test never runs the live CLI, Keychain or
    /// data root (as `startHostRestart` does nothing under XCTest).
    func startHubAdoption() {
        guard hubAdoption == nil else { return }
        guard hubAdoptionDeps != nil || !Self.runsUnderXCTest else { return }
        let driver = liveHubAdoptionDriver()
        hubAdoption = driver
        Task { _ = await driver.run() }
    }

    /// This process is a test run (`startHostRestart`'s check, plus XCTest
    /// being loaded, as the retired Swift hub's gate had it).
    nonisolated static var runsUnderXCTest: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil || NSClassFromString("XCTestCase") != nil
    }

    /// A phone asks to type into sessions (PROJ-16, spec §10, OD-2): Settings
    /// → Mobile shows the request, and while the app is in the background a
    /// macOS notice asks the owner. The hub sends one event per request.
    func hubTypingRequested(deviceID: String, name: String) {
        guard !appIsActive() else { return }
        postTypingRequestNotice(deviceID, name)
    }

    /// A phone start with "Bring the window forward" (mobile POC spec §6.5):
    /// the workbench's page on the main window, the app in front, and the
    /// session the phone started shown there as Work on it shows one, the
    /// board kept (`showPhoneStartedSession`).
    func bringWorkbenchForward(projectID: Int64, sessionID: Int64) async {
        selectedDestination = .workbench
        workbenchesViewModel?.drill(into: projectID)
        frontMainWindow(self)
        await workbenchesViewModel?.showPhoneStartedSession(sessionID, projectID: projectID)
    }

    /// The app in front with its main window shown (the live `frontMainWindow`).
    func frontLiveMainWindow() {
        (NSApp.delegate as? TrayAppDelegate)?.endLoginLaunchClosing()
        ActivationPolicyDecision.becomeRegularAndActivate()
        let shown = NSApp.windows.first { TrayAppDelegate.isMainWindow($0) && ($0.isVisible || $0.isMiniaturized) }
        if let shown {
            if shown.isMiniaturized { shown.deminiaturize(nil) }
            shown.makeKeyAndOrderFront(nil)
        } else {
            openMainWindow?()
        }
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
