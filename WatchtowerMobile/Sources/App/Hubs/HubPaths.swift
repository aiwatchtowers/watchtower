import Foundation

/// Where one hub's files live (multi-hub spec §5.1): the replica under the
/// app group (the extensions may read it), the transport store and the
/// registry under the app's own Application Support (CKSyncEngine and the
/// heartbeat write them at any moment, and a lock on an app-group file at
/// suspension kills the app: 0xdead10cc, #232), the audio under
/// `phone-recordings`. The hold stays shared across hubs.
struct HubPaths {
    /// `AppEnvironment.appGroupDirectory()` (or a test directory).
    let groupDirectory: URL
    /// `AppEnvironment.applicationSupportDirectory()` (or a test directory).
    let localDirectory: URL
    /// `PhoneRecorderController.defaultDirectory()`: `phone-recordings`.
    let recordingsBase: URL

    var registryPath: String { localDirectory.appendingPathComponent("hubs.sqlite").path }
    var holdDirectory: URL { recordingsBase.appendingPathComponent(".held", isDirectory: true) }

    func hubDirectory(_ hubID: String) -> URL {
        groupDirectory.appendingPathComponent("hubs", isDirectory: true).appendingPathComponent(hubID, isDirectory: true)
    }

    func localHubDirectory(_ hubID: String) -> URL {
        localDirectory.appendingPathComponent("hubs", isDirectory: true).appendingPathComponent(hubID, isDirectory: true)
    }

    func replicaPath(_ hubID: String) -> String { hubDirectory(hubID).appendingPathComponent("replica.sqlite").path }

    func transportStorePath(_ hubID: String) -> String {
        localHubDirectory(hubID).appendingPathComponent(AppEnvironment.transportStoreFileName).path
    }

    func recordingsDirectory(_ hubID: String) -> URL {
        recordingsBase.appendingPathComponent("hubs", isDirectory: true).appendingPathComponent(hubID, isDirectory: true)
    }

    /// Creates the hub's three directories.
    func prepare(_ hubID: String) throws {
        for directory in [hubDirectory(hubID), localHubDirectory(hubID), recordingsDirectory(hubID)] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    /// Deletes the hub's directories. Call only after its recordings were
    /// handed to the hold and its session shut down.
    func removeHubFiles(_ hubID: String) throws {
        for directory in [hubDirectory(hubID), localHubDirectory(hubID), recordingsDirectory(hubID)]
        where FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    /// Hub directories present on disk, in the group or the local tree
    /// (orphans are those without a row).
    func hubIDsOnDisk() throws -> [String] {
        var ids = Set<String>()
        for base in [groupDirectory, localDirectory] {
            let hubs = base.appendingPathComponent("hubs", isDirectory: true)
            guard FileManager.default.fileExists(atPath: hubs.path) else { continue }
            ids.formUnion(try FileManager.default.contentsOfDirectory(atPath: hubs.path).filter { !$0.hasPrefix(".") })
        }
        return ids.sorted()
    }
}
