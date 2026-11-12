import Foundation
@testable import WatchtowerHostedRelay
import WatchtowerHostedRelayTesting
import WatchtowerRelayProto
@testable import WatchtowerSync
import XCTest

/// The attachments a pull meets (#1469): the phone's own uploads are never downloaded, and an
/// attachment gone between the page read and its download leaves the pull whole.
extension HostedRelayTransportTests {
    /// The phone uploaded the attachment itself (a recording, up to 90 MB): its pull buffers the
    /// record without a file and never asks for the blob, also after a relaunch (a new transport on
    /// the same store, resyncing from 0). A record of the same name the Mac saves with its own
    /// attachment is downloaded as before.
    func testAPullNeverDownloadsTheDevicesOwnAttachment() async throws {
        var http: InterceptingRelayHTTP?
        let (mac, phone) = try await hub { base in
            let intercepting = InterceptingRelayHTTP(base)
            http = intercepting
            return intercepting
        }
        let intercepting = try XCTUnwrap(http)
        let asset = try directory().appendingPathComponent("sealed-audio")
        try Data(repeating: 3, count: 4096).write(to: asset)
        let store = try TransportStore(path: try storePath())
        let (transport, _) = try await makeTransport(phone, mac: mac, store: store)
        try await transport.save([mailboxRecord("upload-1", asset: asset)])
        await transport.sendNow()
        XCTAssertFalse(try store.isPending(recordName: "upload-1", zone: .relay))

        try await transport.pull()
        XCTAssertFalse(try opNames().contains("getDownload"), "the phone's own attachment is not downloaded")
        XCTAssertEqual(intercepting.gets, [])
        let event = try XCTUnwrap(try buffered(store, .relay).changed.last)
        XCTAssertEqual(event.recordName, "upload-1")
        XCTAssertNil(event.assetFileURL)
        XCTAssertGreaterThan(try store.relayCursor(zone: .relay), 0)
        await transport.stop()

        // A relaunch: a new transport on the same store, the mailbox read again from 0.
        try store.beginRelayResync(.relay)
        let (relaunched, _) = try await makeTransport(phone, mac: mac, store: store)
        try await relaunched.pull()
        XCTAssertFalse(try opNames().contains("getDownload"), "the ledger outlives the transport")

        // The Mac's own attachment under that name is the Mac's: downloaded.
        let bytes = Data(repeating: 9, count: 512)
        let macAttachment = try await macUpload(mac, mailbox(mac, phone), bytes)
        try await macSave(mac, mailbox(mac, phone), "upload-1", attachmentID: macAttachment)
        try await relaunched.pull()
        let rewritten = try XCTUnwrap(try buffered(store, .relay).changed.last)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(rewritten.assetFileURL)), bytes)
    }

    /// The Mac rewrites a record without its attachment between the phone's page read and its
    /// `get_download` (`NOT_FOUND`): the record is buffered without a file and the pull ends with
    /// the cursor past the page.
    func testAnAttachmentGoneBeforeItsDownloadLeavesThePullWhole() async throws {
        var http: InterceptingRelayHTTP?
        let (mac, phone) = try await hub { base in
            let intercepting = InterceptingRelayHTTP(base)
            http = intercepting
            return intercepting
        }
        let intercepting = try XCTUnwrap(http)
        let attachment = try await macUpload(mac, dataZone(mac), Data(repeating: 7, count: 100))
        try await macSave(mac, dataZone(mac), "report", attachmentID: attachment)
        let pageEnd = try await macSave(mac, dataZone(mac), "other")
        let store = try TransportStore(path: try storePath())
        let (transport, _) = try await makeTransport(phone, mac: mac, store: store)

        intercepting.holdNext { request in
            if case .getDownload = request.op { return true }
            return false
        }
        let pull = Task { try await transport.pull() }
        await eventually { intercepting.holding }
        let rewrite = try await macSave(mac, dataZone(mac), "report")
        intercepting.release()
        try await pull.value

        let first = try buffered(store, .data)
        XCTAssertEqual(first.changed.map(\.recordName), ["report", "other"])
        XCTAssertNil(first.changed.first?.assetFileURL)
        XCTAssertEqual(try store.relayCursor(zone: .data), pageEnd, "the cursor moved past the page")

        // The next pull reads the rewrite.
        try await transport.pull()
        XCTAssertEqual(try store.relayCursor(zone: .data), rewrite)
        let second = try buffered(store, .data, since: first.newToken)
        XCTAssertEqual(second.changed.map(\.recordName), ["report"], "the second pull buffers the rewrite")
        let latest = try XCTUnwrap(second.changed.first)
        XCTAssertEqual(latest.recordSeq, rewrite)
        XCTAssertNil(latest.assetFileURL)
    }

    /// The blob is gone by the time of the GET (404) and `get_download` then answers `NOT_FOUND`:
    /// the record is buffered without a file and the cursor moves past the page. Any other non-2xx
    /// still fails the page (`testDownloadCappedAndRedirectsChecked`).
    func testABlobGoneAtItsGetLeavesThePullWhole() async throws {
        var http: InterceptingRelayHTTP?
        let (mac, phone) = try await hub { base in
            let intercepting = InterceptingRelayHTTP(base)
            http = intercepting
            return intercepting
        }
        let intercepting = try XCTUnwrap(http)
        let attachment = try await macUpload(mac, dataZone(mac), Data(repeating: 7, count: 100))
        let seq = try await macSave(mac, dataZone(mac), "report", attachmentID: attachment)
        let path = try storePath()
        let stash = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("transport-assets")
        let store = try TransportStore(path: path)
        let (transport, _) = try await makeTransport(phone, mac: mac, store: store)

        // The blob GET finds nothing; the Mac rewrites the record without its attachment before
        // the transport asks `get_download` again, so the relay agrees it is gone.
        intercepting.download { _ in
            intercepting.holdNext { request in
                if case .getDownload = request.op { return true }
                return false
            }
            return 404
        }
        let pull = Task { try await transport.pull() }
        await eventually { intercepting.holding }
        try await macSave(mac, dataZone(mac), "report")
        intercepting.release()
        try await pull.value
        let event = try XCTUnwrap(try buffered(store, .data).changed.first)
        XCTAssertEqual(event.recordName, "report")
        XCTAssertNil(event.assetFileURL)
        XCTAssertEqual(try store.relayCursor(zone: .data), seq)
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: stash.path)) ?? [], [], "no file left")
    }

    /// A blob GET 404 while `get_download` still serves the attachment is not "gone": the page
    /// fails and the cursor stays.
    func testABlobMissingUnderALiveAttachmentFailsThePage() async throws {
        var http: InterceptingRelayHTTP?
        let (mac, phone) = try await hub { base in
            let intercepting = InterceptingRelayHTTP(base)
            http = intercepting
            return intercepting
        }
        let intercepting = try XCTUnwrap(http)
        let attachment = try await macUpload(mac, dataZone(mac), Data(repeating: 7, count: 100))
        try await macSave(mac, dataZone(mac), "report", attachmentID: attachment)
        let store = try TransportStore(path: try storePath())
        let (transport, _) = try await makeTransport(phone, mac: mac, store: store)

        intercepting.download { _ in 404 }
        do {
            try await transport.pull()
            XCTFail("a 404 under a live attachment was taken for a gone one")
        } catch HostedRelayError.undecodable(status: 404) {}
        XCTAssertEqual(backend.opLog.filter { if case .getDownload = $0 { return true }; return false }.count, 2)
        XCTAssertEqual(try store.relayCursor(zone: .data), 0)
        XCTAssertEqual(try buffered(store, .data).changed, [])
    }

    /// Only `NOT_FOUND` means gone: another refusal of `get_download` still fails the page.
    func testAnotherDownloadRefusalStillFailsThePage() async throws {
        var http: InterceptingRelayHTTP?
        let (mac, phone) = try await hub { base in
            let intercepting = InterceptingRelayHTTP(base)
            http = intercepting
            return intercepting
        }
        let intercepting = try XCTUnwrap(http)
        let attachment = try await macUpload(mac, dataZone(mac), Data(repeating: 7, count: 100))
        try await macSave(mac, dataZone(mac), "report", attachmentID: attachment)
        let store = try TransportStore(path: try storePath())
        let (transport, _) = try await makeTransport(phone, mac: mac, store: store)

        intercepting.answer { request in
            guard case .getDownload = request.op else { return nil }
            var refused = Relay_V1_Error()
            refused.code = .forbidden
            var response = Relay_V1_Response()
            response.error = refused
            return response
        }
        do {
            try await transport.pull()
            XCTFail("a forbidden download was taken for a gone one")
        } catch HostedRelayError.server(code: .forbidden, _) {}
        XCTAssertEqual(try store.relayCursor(zone: .data), 0)
        XCTAssertEqual(try buffered(store, .data).changed, [])
    }
}
