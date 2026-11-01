import Foundation
@testable import WatchtowerHostedRelay
import WatchtowerHostedRelayTesting
import WatchtowerRelayProto
import WatchtowerSync
import XCTest

/// `HostedRelayTransport.saveDirectly`: the phone's kept farewell (#143) on a relay route, saved
/// through the shared client into the phone's mailbox with its Mac, outside any transport.
final class HostedRelayDirectSaveTests: HostedRelayScenarioCase {
    private static let stamp = Date(timeIntervalSince1970: 1_700_000_000)

    private func record(_ name: String, zone: CloudZoneID = .relay, asset: URL? = nil) -> CloudRecord {
        CloudRecord(
            recordName: name, zone: zone, kind: WireKind.envelope, modifiedAt: Self.stamp,
            payload: Data("sealed-\(name)".utf8), assetFileURL: asset)
    }

    func testSaveDirectlyWritesThePhonesMailboxWithItsMac() async throws {
        let (mac, phone) = try await hub(mac: 60, phone: 61)
        try await HostedRelayTransport.saveDirectly(record("farewell"), client: phone, macDeviceID: mac.deviceID)

        let mailbox = HostedRelayZones.mailbox(mac: mac.deviceID, phone: phone.deviceID)
        guard case .changes(let page) = try await mac.perform(Self.changesOp(mailbox)).result else {
            return XCTFail("the Mac reads its mailbox with the phone")
        }
        XCTAssertEqual(page.changed.map(\.name), ["farewell"])
        XCTAssertEqual(page.changed.first?.envelope, Data("sealed-farewell".utf8))
        XCTAssertEqual(page.changed.first?.clientModifiedAtMs, 1_700_000_000_000)
    }

    func testOnlyAMailboxRecordWithoutAnAssetIsSavedAndNothingIsSentOtherwise() async throws {
        let (mac, phone) = try await hub(mac: 62, phone: 63)
        let ops = backend.opLog.count
        let asset = FileManager.default.temporaryDirectory.appendingPathComponent("unused-asset")
        for refused in [record("data", zone: .data), record("with-asset", asset: asset)] {
            do {
                try await HostedRelayTransport.saveDirectly(refused, client: phone, macDeviceID: mac.deviceID)
                XCTFail("\(refused.recordName) must be refused")
            } catch {
                XCTAssertEqual(error as? HostedRelayTransport.DirectSaveError, .notAMailboxRecord)
            }
        }
        XCTAssertEqual(backend.opLog.count, ops, "no request")
    }
}
