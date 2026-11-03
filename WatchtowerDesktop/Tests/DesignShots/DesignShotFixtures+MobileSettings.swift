import SwiftUI
import WatchtowerCore
@testable import WatchtowerDesktop

/// Settings → Mobile over `watchtower hub …` and its pairing sheet (go hub
/// plan 3 Task 23, mockups `docs/design/mockups/go-hub/index.html` §1–§13),
/// on fixture data (`acme`, Phone A / Phone B). The model is shown one read
/// of the hub; its own reads park, so the shot keeps that state.
@MainActor
enum MobileSettingsShotFixtures {
    enum Frame: String, CaseIterable {
        case empty, loading, error, busy, phones, narrow, off
        case swiftBesideGo = "swift-beside-go"
        case iCloud = "icloud"
        case keptRecordings = "kept-recordings"
        case keptRecordingsNarrow = "kept-recordings-narrow"
        // Go hub plan 4 Task 8 (coverage table rows 5–25, mockups §19–§21):
        // the raw value is the shot's name.
        case relayConnected = "mobileSettingsRelayConnected"
        case relayConnecting = "mobileSettingsRelayConnecting"
        case relayUnavailable = "mobileSettingsRelayUnavailable"
        case pushOff = "mobileSettingsPushOff"
        case quotaHub = "mobileSettingsQuotaHub"
        case mailboxFull = "mobileSettingsMailboxFull"
        case connectedPushOff = "mobileSettingsConnectedPushOff"
        case connectingPushOff = "mobileSettingsConnectingPushOff"
        case unavailablePushOff = "mobileSettingsUnavailablePushOff"
        case connectedQuotaHub = "mobileSettingsConnectedQuotaHub"
        case bothQuotas = "mobileSettingsBothQuotas"
        case hubAllLines = "mobileSettingsHubAllLines"
        case freePhoneOnRelay = "mobileSettingsFreePhoneOnRelay"
        case undeliveredOne = "mobileSettingsUndeliveredOne"
        case undeliveredMany = "mobileSettingsUndeliveredMany"
        case notificationsMissing = "mobileSettingsNotificationsMissing"
        case alertAccepted = "mobileSettingsAlertAccepted"
        case phoneAllLines = "mobileSettingsPhoneAllLines"
        case undeliveredNoToken = "mobileSettingsUndeliveredNoToken"
        case twoMailboxesFull = "mobileSettingsTwoMailboxesFull"
        case indicatorsNarrow = "mobileSettingsIndicatorsNarrow"

        var name: String {
            switch self {
            case .empty: "mobileSettingsEmpty"
            case .loading: "mobileSettingsLoading"
            case .error: "mobileSettingsError"
            case .busy: "mobileSettingsBusy"
            case .phones: "mobileSettingsPhones"
            case .narrow: "mobileSettingsNarrow"
            case .off: "mobileSettingsOff"
            case .swiftBesideGo: "mobileSettingsSwiftBesideGo"
            case .iCloud: "mobileSettingsICloud"
            case .keptRecordings: "mobileSettingsKeptRecordings"
            case .keptRecordingsNarrow: "mobileSettingsKeptRecordings-narrow"
            default: rawValue
            }
        }

        var size: NSSize {
            if let indicator = MobileSettingsShotFixtures.size(indicator: self) { return indicator }
            return switch self {
            case .narrow: NSSize(width: 380, height: 760)
            case .keptRecordingsNarrow: NSSize(width: 380, height: 900)
            case .loading, .error, .off, .swiftBesideGo: NSSize(width: 640, height: 140)
            case .iCloud: NSSize(width: 640, height: 520)
            case .empty: NSSize(width: 640, height: 460)
            case .keptRecordings: NSSize(width: 640, height: 740)
            case .busy, .phones: NSSize(width: 640, height: 680)
            default: NSSize(width: 640, height: 640)
            }
        }
    }

    /// Every pairing step and refusal (mockup §11–§13).
    enum Pairing: String, CaseIterable {
        case starting = "mobilePairingStarting"
        case qr = "mobilePairingQR"
        case waiting = "mobilePairingWaiting"
        case sas = "mobilePairingSAS"
        case linked = "mobilePairingLinked"
        case refused = "mobilePairingRefused"
        case expired = "mobilePairingRefused-expired"
        case unknownCode = "mobilePairingRefused-unknownCode"
        case notConfirmed = "mobilePairingRefused-notConfirmed"
        case tooMany = "mobilePairingRefused-tooMany"
        case unknownReason = "mobilePairingRefused-unknownReason"
        case failed = "mobilePairingFailed"

        var refusal: String? {
            switch self {
            case .refused: "used_code"
            case .expired: "expired_code"
            case .unknownCode: "unknown_code"
            case .notConfirmed: "not_confirmed"
            case .tooMany: "too_many_requests"
            case .unknownReason: "something_new"
            default: nil
            }
        }
    }

    /// A fixed moment, so "switched by … today" reads the same every run.
    static let now = Date(timeIntervalSince1970: 1_793_620_800)

    static func screen(_ frame: Frame) -> AnyView {
        let defaults = UserDefaults(suiteName: "WatchtowerDesktopShots.mobileSettings") ?? .standard
        let clock: () -> Date = { now }
        let model = MobileSettingsModel(cli: ParkedHubCLI(), defaults: defaults, now: clock)
        switch frame {
        case .loading:
            break
        case .error:
            model.present(failure: "The hub state dir is locked and no hub answers on its control socket.")
        case .off:
            model.present(status: MobileHubCLI.Status(state: "off", reason: "policy_off"), phones: [], jobs: nil)
        case .swiftBesideGo:
            model.present(status: MobileHubCLI.Status(state: "off", reason: "swift_beside_go"), phones: [], jobs: nil)
        case .iCloud:
            // Today's iCloud lines: an unsigned build, the account's sentence, CloudKit slowing sync down.
            let cloud = MobileHubCLI.Status.CloudKit(account: "no_account", throttledSince: now.addingTimeInterval(-120), signed: false)
            var status = running()
            status = MobileHubCLI.Status(
                state: status.state, transport: status.transport, recordings: status.recordings, name: status.name,
                switchedAt: status.switchedAt, switchedBy: status.switchedBy, cloudKit: cloud
            )
            model.present(status: status, phones: [], jobs: nil)
        case .empty:
            model.present(status: running(), phones: [], jobs: nil)
        case .phones, .narrow:
            model.present(status: running(), phones: phones, jobs: nil)
        case .busy:
            model.present(status: running(recordings: "off"), phones: phones, jobs: nil)
            model.busy = [.recordings, .phone(phones[0].deviceID)]
        case .keptRecordings, .keptRecordingsNarrow:
            let kept = MobileHubCLI.Status.Kept(count: 3, removeAt: now.addingTimeInterval(12 * 86_400), dir: "/tmp/acme/recordings")
            let jobs = MobileHubCLI.RecordingJobs(ready: true, jobs: [
                .init(uploadID: "u-1", status: "failed", errorClass: "not_audio"),
                .init(uploadID: "u-2", status: "failed", errorClass: "transcription_failed")
            ])
            model.present(status: running(kept: kept), phones: [phones[0]], jobs: jobs)
        default:
            let (status, phones) = indicators(frame)
            model.present(status: status, phones: phones, jobs: nil)
        }
        return AnyView(MobileSettingsView(model: model)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .detailBackground())
    }

    static func pairing(_ shot: Pairing) -> AnyView {
        let model = MobilePairingModel(streamer: nil, now: { now }, sleep: { _ in withUnsafeCurrentTask { $0?.cancel() } })
        let expires = ISO8601DateFormatter().string(from: now.addingTimeInterval(581))
        let qr = #"{"event":"qr","url":"watchtower://link?d=eyJ2IjoxLCJob3N0IjoiYWNtZSJ9","expires_at":"\#(expires)"}"#
        let sas = #"{"event":"sas","device_id":"AAAA0001","name":"Phone A","code":"4827"}"#
        switch shot {
        case .starting:
            break
        case .qr:
            model.receive(qr)
            model.tick()
        case .waiting:
            model.receive(qr)
            model.receive(#"{"event":"waiting"}"#)
            model.tick()
        case .sas:
            model.receive(sas)
        case .linked:
            model.receive(sas)
            model.receive(#"{"event":"linked","device_id":"AAAA0001"}"#)
        case .failed:
            model.streamEnded("The hub is not running.")
        case .refused, .expired, .unknownCode, .notConfirmed, .tooMany, .unknownReason:
            model.receive(#"{"event":"refused","reason":"\#(shot.refusal ?? "")"}"#)
        }
        return AnyView(MobilePairingSheet(model: model) {}
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Surface.window))
    }

    /// A running Relay hub; its Relay row says connected unless `relay` says otherwise (phase 4 Task 8).
    static func running(
        recordings: String = "on", kept: MobileHubCLI.Status.Kept? = nil, relay: MobileHubCLI.RelayHealth? = connectedRelay
    ) -> MobileHubCLI.Status {
        MobileHubCLI.Status(
            state: "running", transport: "relay", recordings: recordings, name: "Work Mac",
            switchedAt: now.addingTimeInterval(-480), switchedBy: "AAAA0001", keptRecordings: kept, relay: relay
        )
    }

    static let connectedRelay = MobileHubCLI.RelayHealth(
        state: "connected", since: now.addingTimeInterval(-3600), lastSavedAt: now.addingTimeInterval(-120)
    )

    private static let phones = [
        MobileHubCLI.Phone(
            deviceID: "AAAA0001", name: "Phone A", scope: "shared", linkedAt: now.addingTimeInterval(-21 * 86_400),
            typingAllowed: true, typingRequested: false, permissionsAllowed: true, permissionsRequested: false,
            startSessionsAllowed: true, startSessionsGranted: true, transport: "relay"
        ),
        MobileHubCLI.Phone(
            deviceID: "BBBB0002", name: "Phone B", scope: "private", linkedAt: now.addingTimeInterval(-30 * 86_400),
            typingAllowed: false, typingRequested: true, permissionsAllowed: false, permissionsRequested: false,
            startSessionsAllowed: false, startSessionsGranted: false, transport: "cloudkit"
        )
    ]
}

/// A CLI whose every call waits until it is cancelled: the shot keeps the
/// read it was shown.
private struct ParkedHubCLI: CLIRunnerProtocol {
    func run(args: [String]) async throws -> Data {
        try await Task.sleep(for: .seconds(3600))
        throw CancellationError()
    }
}
