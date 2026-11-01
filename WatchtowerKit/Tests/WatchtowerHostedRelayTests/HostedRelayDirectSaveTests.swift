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

        guard case .changes(let page) = try await mac.perform(Self.changesOp(mailbox(mac, phone))).result else {
            return XCTFail("the Mac reads its mailbox with the phone")
        }
        XCTAssertEqual(page.changed.map(\.name), ["farewell"])
        XCTAssertEqual(page.changed.first?.envelope, Data("sealed-farewell".utf8))
        XCTAssertEqual(page.changed.first?.clientModifiedAtMs, 1_700_000_000_000)
    }

    private func mailbox(_ mac: HostedRelayClient, _ phone: HostedRelayClient) -> String {
        HostedRelayZones.mailbox(mac: mac.deviceID, phone: phone.deviceID)
    }

    /// The mailbox's live copy of `name`, as the Mac reads it.
    private func current(_ name: String, mac: HostedRelayClient, phone: HostedRelayClient) async throws -> Relay_V1_Record? {
        guard case .changes(let page) = try await mac.perform(Self.changesOp(mailbox(mac, phone))).result else { return nil }
        return page.changed.last { $0.name == name }
    }

    /// A new link's `device-a`, written over the old copy unconditionally.
    private static func relinkOp(_ zone: String) -> Relay_V1_Request.OneOf_Op {
        var item = Relay_V1_SaveItem()
        item.record.zone = zone
        item.record.name = "device-a"
        item.record.envelope = Data("relink".utf8)
        var save = Relay_V1_Save()
        save.items = [item]
        return .save(save)
    }

    private func saveCount(after ops: Int) -> Int {
        backend.opLog.dropFirst(ops).filter { if case .save = $0 { true } else { false } }.count
    }

    /// The copy the first try was refused for is replaced by the second, conditioned on its seq.
    func testAnExistingCopyIsReplacedOnTheSecondTry() async throws {
        let (mac, phone) = try await hub(mac: 64, phone: 65)
        _ = try await phone.perform(Self.saveOp(mailbox(mac, phone), "device-a"))
        let ops = backend.opLog.count
        try await HostedRelayTransport.saveDirectly(record("device-a"), client: phone, macDeviceID: mac.deviceID)
        let copy = try await current("device-a", mac: mac, phone: phone)
        XCTAssertEqual(copy?.envelope, Data("sealed-device-a".utf8))
        XCTAssertEqual(saveCount(after: ops), 2, "must-not-exist, then the copy's seq")
    }

    /// A relink's write that lands between the refused first try and the retry is never replaced (#261).
    func testARelinkWriteBetweenTheReadAndTheRetryRefusesTheFarewell() async throws {
        let (mac, phone) = try await hub(mac: 66, phone: 67)
        let zone = mailbox(mac, phone)
        _ = try await phone.perform(Self.saveOp(zone, "device-a"))
        do {
            try await HostedRelayTransport.saveDirectly(record("device-a"), client: phone, macDeviceID: mac.deviceID) {
                _ = try await phone.perform(Self.relinkOp(zone))
            }
            XCTFail("the farewell must be refused")
        } catch {
            XCTAssertEqual(error as? HostedRelayTransport.DirectSaveError, .refused)
        }
        let copy = try await current("device-a", mac: mac, phone: phone)
        XCTAssertEqual(copy?.envelope, Data("relink".utf8), "the relink's copy stays")
    }

    /// A save cancelled while the first try ran never tries again: the copy may already be a new link's.
    func testACancelledSaveNeverRetries() async throws {
        let (mac, phone) = try await hub(mac: 68, phone: 69)
        _ = try await phone.perform(Self.saveOp(mailbox(mac, phone), "device-a"))
        let ops = backend.opLog.count
        do {
            try await HostedRelayTransport.saveDirectly(record("device-a"), client: phone, macDeviceID: mac.deviceID) {
                withUnsafeCurrentTask { $0?.cancel() }
            }
            XCTFail("a cancelled save must not retry")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(saveCount(after: ops), 1, "the first try only")
        let copy = try await current("device-a", mac: mac, phone: phone)
        XCTAssertEqual(copy?.envelope, Data("device-a".utf8))
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
