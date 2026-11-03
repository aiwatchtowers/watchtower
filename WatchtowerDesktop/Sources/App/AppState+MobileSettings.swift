import Foundation
import GRDB
import WatchtowerCore

extension AppState {
    /// Settings → Mobile over `watchtower hub …` (go hub plan 3 Task 23),
    /// with the hand-over to the Go hub (Task 22) read through the app.
    func makeMobileSettingsModel() -> MobileSettingsModel {
        let runner = ProcessCLIRunner.makeDefault()
        return MobileSettingsModel(
            cli: runner,
            adoption: self,
            retryRecording: { [weak self] in self?.phoneRecordingQueue?.recordingQueued($0) },
            pairStreamer: runner.map { HubPairCLIStreamer(binaryPath: $0.binaryPath) },
            showsCorpNotice: Self.isCorpBuild(),
            defaults: mobileSyncDefaults
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

    /// The driver runs it in its own task (`retryHubAdoption`); the tab
    /// reads again as its state moves (`MobileSettingsTab`'s onChange).
    func retryHandOver() async {
        retryHubAdoption()
    }

    func setUpHandOverAgain() async {
        setUpMobileAgain()
    }
}

extension AppState {
    /// The keep-awake over the hub center's heartbeats, the owner's switch
    /// and the live board sessions (`KeepAwakePolicy`, ask #614).
    func makeHubKeepAwake(_ center: HubCenter, dbPool: DatabasePool) -> HubKeepAwake {
        let defaults = mobileSyncDefaults
        return HubKeepAwake(inputs: .init(
            enabled: { defaults.object(forKey: Constants.mobileKeepAwakeKey) as? Bool ?? true },
            hubRunning: { [weak center] in center?.status?.state == "running" },
            liveBoardSessions: { [weak self, weak dbPool] in
                HubKeepAwake.liveBoardSessions(dbPool, liveIDs: self?.terminalCenter.liveIDs ?? [])
            },
            lastPhoneContact: { [weak center] in center?.lastPhoneContact }
        ))
    }
}

extension AppState {
    /// The hub center, its phone recording queue and the keep-awake, rebuilt
    /// with the workbenches (the previous ones stopped).
    func replaceHubCenter(
        dbPool: DatabasePool,
        cliRunner: (any CLIRunnerProtocol)?,
        workbenches vm: WorkbenchesViewModel,
        agentStates: SessionAgentStateCenter
    ) {
        hubCenter?.stop()
        hubCenter = makeHubCenter(cliRunner)
        phoneRecordingQueue = replacePhoneRecordingQueue(phoneRecordingQueue, hub: hubCenter, dbPool: dbPool, cliRunner: cliRunner)
        hubCenter?.follow(workbenches: vm, agentStates: agentStates)
        hubCenter?.onTypingRequest = { [weak self] in self?.hubTypingRequested(deviceID: $0, name: $1) }
        hubCenter?.onBringForward = { [weak self] workbench, session in
            Task { await self?.bringWorkbenchForward(projectID: workbench, sessionID: session) }
        }
        hubCenter?.start()
        hubKeepAwake?.stop()
        hubKeepAwake = hubCenter.map { makeHubKeepAwake($0, dbPool: dbPool) }
        hubKeepAwake?.start()
    }

    /// The app quits: no more heartbeats, so the hub's view goes stale.
    func stopHubCenterForQuit() {
        hubCenter?.stop()
        phoneRecordingQueue?.stop()
        hubKeepAwake?.stop()
    }
}
