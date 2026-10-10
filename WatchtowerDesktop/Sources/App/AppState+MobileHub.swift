import AppKit
import GRDB

/// Settings → Mobile drives the toggle and reads the hub through these.
extension AppState: MobileSettingsHost {}

extension AppState {
    /// A phone start with "Bring the window forward" (mobile POC spec §6.5):
    /// the workbench's page on the main window, the app in front — before
    /// the start, so its Work on it placement lands on that page.
    func bringWorkbenchForward(projectID: Int64) {
        selectedDestination = .workbench
        workbenchesViewModel?.drill(into: projectID)
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

    /// The last step of `buildMobileHub`: the link center (when the storage
    /// has a share service), the relay processor that hands it the phones'
    /// `device` records, and the hub it hangs on.
    func assembleMobileHub(
        storage: MobileHubStorage,
        dbPool: DatabasePool,
        dispatcher: MobileHubCommandDispatcher,
        publisher: SlicePublisher,
        companions: [any HubCompanion],
        recordingUploads: RelayProcessor.RecordingUploads
    ) throws -> MobileHubService {
        let hostInfo = HubHostInfo.live(dbPool: dbPool, ownerUser: storage.ownerUser)
        let linkCenter = MobileLinkCenter.forHub(storage: storage, macName: hostInfo.macName, publisher: publisher)
        let processor = RelayProcessor(
            transport: storage.transport, sidecar: storage.sidecar, dispatcher: dispatcher,
            hubID: try storage.sidecar.ensureHubID(), recordingUploads: recordingUploads,
            deviceRecords: linkCenter?.relayRoute
        )
        let hub = MobileHubService(
            transport: storage.transport, publisher: publisher, processor: processor, sidecar: storage.sidecar,
            hostInfo: hostInfo, companions: companions
        ) { [weak self] in self?.isMobileSyncEnabled ?? false }
        linkCenter?.attach(to: hub)
        return hub
    }
}
