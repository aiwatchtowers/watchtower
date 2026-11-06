import Foundation
import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

@MainActor
final class RouteStashTests: XCTestCase {
    /// Board #1496: a hub's two route stores sit in one folder, and each route's fetched-asset stash is its own
    /// folder, so the sweep of a wipe (a CloudKit catch-up too) in one store never reaches the other's files.
    func testAWipeOfOneRoutesStoreLeavesTheOtherRoutesStashedFiles() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("stash-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        let paths = HubPaths(
            groupDirectory: base.appendingPathComponent("group", isDirectory: true),
            localDirectory: base.appendingPathComponent("local", isDirectory: true),
            recordingsBase: base.appendingPathComponent("phone-recordings", isDirectory: true)
        )
        let hubID = "E2E00000-0000-4000-8000-000000000001"
        try paths.prepare(hubID)
        let cloudKit = try AppEnvironment.liveTransportStore(
            path: paths.transportStorePath(hubID, route: .cloudKit(.private)))
        let relay = try AppEnvironment.liveTransportStore(
            path: paths.transportStorePath(hubID, route: .hostedRelay(macDeviceID: "mac-a")))
        defer { try? cloudKit.close(); try? relay.close() }
        let cloudStash = try XCTUnwrap(cloudKit.stashDirectory)
        let relayStash = try XCTUnwrap(relay.stashDirectory)
        XCTAssertNotEqual(cloudStash.standardizedFileURL, relayStash.standardizedFileURL)
        let cloudFile = cloudStash.appendingPathComponent("cloud-asset")
        let relayFile = relayStash.appendingPathComponent("relay-asset")
        try FileManager.default.createDirectory(at: cloudStash, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: relayStash, withIntermediateDirectories: true)
        try Data("c".utf8).write(to: cloudFile)
        try Data("r".utf8).write(to: relayFile)

        try relay.wipe()
        XCTAssertTrue(FileManager.default.fileExists(atPath: cloudFile.path), "the relay store's wipe left the CloudKit stash")
        XCTAssertFalse(FileManager.default.fileExists(atPath: relayFile.path), "the wipe still sweeps its own stash")

        try Data("r".utf8).write(to: relayFile)
        try cloudKit.wipe()
        XCTAssertTrue(FileManager.default.fileExists(atPath: relayFile.path), "the CloudKit store's wipe left the relay stash")
        XCTAssertFalse(FileManager.default.fileExists(atPath: cloudFile.path))
    }
}
