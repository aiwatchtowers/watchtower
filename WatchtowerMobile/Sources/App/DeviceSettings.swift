import Foundation
import Observation
import os
import WatchtowerSync

/// This phone's identity once it is linked to a Mac: everything its
/// `device` record (spec §5.1) carries besides the Settings choices. The
/// link flow (Task 12) creates it; the demo transport uses `DemoSeed.device`.
struct LinkedDevice: Equatable, Sendable {
    let deviceID: String
    let name: String
    let model: String
    let appVersion: String
    let scope: DeviceScope
    let userRecordName: String
}

/// The phone-side Settings choices (spec §10, §13 A4):
/// - "Type into sessions from this phone" (`typing_requested`, default off),
/// - "Start sessions from this phone" (`start_sessions`, default on),
/// - "New asks" alerts (default on; the notification code reads it).
///
/// The two Workbench choices are requests to the Mac: each change rewrites
/// the phone's `device` record while it is linked. Before linking, the
/// choice is only kept, and the link flow sends it with the link record.
/// Every choice is persisted in `UserDefaults`, so it survives a relaunch.
@MainActor
@Observable
final class DeviceSettings {
    private(set) var typingRequested: Bool
    private(set) var startSessions: Bool
    var newAskAlerts: Bool {
        didSet { defaults.set(newAskAlerts, forKey: Keys.newAskAlerts) }
    }

    /// Why the last device-record write failed; nil after a success.
    private(set) var lastError: String?

    /// Set by the environment when the phone links or unlinks.
    var linkedDevice: LinkedDevice?

    @ObservationIgnored private let transport: any CloudSyncTransport
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: @Sendable () -> Date
    /// The last queued device-record write. Writes run one at a time, in
    /// toggle order, and each sends the choices current when it runs, so the
    /// Mac always ends on the latest state.
    @ObservationIgnored private var lastWrite: Task<Void, Never>?
    private static let logger = Logger(subsystem: "WatchtowerMobile", category: "DeviceSettings")

    private enum Keys {
        static let typingRequested = "device.typingRequested"
        static let startSessions = "device.startSessions"
        static let newAskAlerts = "notifications.newAsks"
    }

    init(
        transport: any CloudSyncTransport,
        defaults: UserDefaults,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.transport = transport
        self.defaults = defaults
        self.now = now
        typingRequested = defaults.object(forKey: Keys.typingRequested) as? Bool ?? false
        startSessions = defaults.object(forKey: Keys.startSessions) as? Bool ?? true
        newAskAlerts = defaults.object(forKey: Keys.newAskAlerts) as? Bool ?? true
    }

    func setTypingRequested(_ value: Bool) async {
        guard value != typingRequested else { return }
        let previous = typingRequested
        typingRequested = value
        await serializedWrite { [weak self] saved in
            guard let self else { return }
            if saved {
                defaults.set(value, forKey: Keys.typingRequested)
            } else if typingRequested == value {
                // Revert only our own change: a later toggle owns the value now.
                typingRequested = previous
            }
        }
    }

    func setStartSessions(_ value: Bool) async {
        guard value != startSessions else { return }
        let previous = startSessions
        startSessions = value
        await serializedWrite { [weak self] saved in
            guard let self else { return }
            if saved {
                defaults.set(value, forKey: Keys.startSessions)
            } else if startSessions == value {
                startSessions = previous
            }
        }
    }

    /// The `device` record for the current choices, or nil while unlinked.
    func devicePayload() -> DevicePayload? {
        guard let device = linkedDevice else { return nil }
        return DevicePayload(
            deviceID: device.deviceID,
            name: device.name,
            model: device.model,
            appVersion: device.appVersion,
            scope: device.scope,
            userRecordName: device.userRecordName,
            typingRequested: typingRequested,
            startSessions: startSessions,
            updatedAt: now()
        )
    }

    /// Queues one device-record write behind the previous one. `completion`
    /// runs before the next write starts, so a revert after a failed write
    /// is already in the choices the next write sends.
    private func serializedWrite(completion: @escaping @MainActor (_ saved: Bool) -> Void) async {
        let prior = lastWrite
        let write = Task { [weak self] in
            await prior?.value
            guard let self else { return }
            completion(await self.writeDeviceRecord())
        }
        lastWrite = write
        await write.value
    }

    /// Saves the device record for the current choices. Returns false (and
    /// sets `lastError`) when the save failed; true when it succeeded or
    /// there is no link to write to yet.
    private func writeDeviceRecord() async -> Bool {
        guard let payload = devicePayload() else { return true }
        do {
            try await transport.save([try CloudRecordFactory.record(for: payload, modifiedAt: payload.updatedAt)])
            lastError = nil
            return true
        } catch {
            Self.logger.error("device record write failed: \(error.localizedDescription, privacy: .public)")
            lastError = "Couldn't update your Mac: \(error.localizedDescription)"
            return false
        }
    }
}
