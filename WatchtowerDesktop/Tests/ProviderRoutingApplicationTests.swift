import Foundation
import XCTest
import WatchtowerCore

@MainActor
final class ProviderRoutingApplicationTests: XCTestCase {
    private func status(
        _ saved: String,
        ack: String?,
        version: String = "file-new",
        ackVersion: String = "file-new",
        identity: String = "run-one",
        error: String? = nil
    ) throws -> ChatRoutingStatus {
        var value: [String: Any] = ["revision": saved, "saved_version": version,
                                    "preferred_provider": "codex", "enabled": true, "providers": []]
        if let ack {
            var application: [String: Any] = ["revision": ack, "saved_version": ackVersion,
                                              "identity": identity, "preferred_provider": "codex"]
            if let error { application["error"] = error }
            value["application"] = application
        }
        return try ChatRoutingStatus.parse(JSONSerialization.data(withJSONObject: value))
    }

    func testWaitsForActualAckAndRetriesLatestSavedRevision() async throws {
        var current = try status("new", ack: "old")
        var reads = 0
        let model = ProviderRoutingApplication(attempts: 1, read: { reads += 1; return current }, pause: {})
        model.saved()
        XCTAssertEqual(model.phase, .applying)
        XCTAssertNil(model.copy?.action)
        await model.applyLatest()
        XCTAssertEqual(model.phase, .failed)
        XCTAssertEqual(model.savedRevision, "new")
        XCTAssertEqual(model.confirmed?.revision, "old")
        XCTAssertEqual(model.copy?.title, ProviderFallbackPreview(preferred: .claude, state: .applyError).copy.title)
        XCTAssertFalse(model.copy?.detail.contains("still uses its previous") ?? true)
        current = try status("newest", ack: "newest", version: "latest", ackVersion: "latest")
        await model.applyLatest()
        XCTAssertEqual(model.phase, .applied)
        XCTAssertEqual(model.savedRevision, "newest")
        XCTAssertEqual(reads, 2)
    }

    func testABAFileVersionDaemonLossAndPublishErrorNeverClaimApplied() async throws {
        var current = try status("A", ack: "A", ackVersion: "old-file")
        let model = ProviderRoutingApplication(attempts: 1, read: { current }, pause: {})
        await model.applyLatest()
        XCTAssertEqual(model.phase, .failed)
        current = try status("A", ack: "A", error: "Acknowledgement is not confirmed")
        await model.applyLatest()
        XCTAssertEqual(model.phase, .failed)
        XCTAssertEqual(model.diagnostic, "Acknowledgement is not confirmed")
        current = try status("A", ack: nil)
        await model.applyLatest()
        XCTAssertEqual(model.phase, .failed)
        XCTAssertNil(model.confirmed)
        current = try status("A", ack: "A", identity: "replacement-run")
        await model.applyLatest()
        XCTAssertEqual(model.phase, .applied)
        XCTAssertEqual(model.confirmed?.identity, "replacement-run")
    }

    func testNewSaveWinsAgainstDelayedOldResponse() async throws {
        var pending: CheckedContinuation<ChatRoutingStatus, Never>?
        var first = true
        let latest = try status("latest", ack: "latest")
        let old = try status("old", ack: "old")
        let model = ProviderRoutingApplication(attempts: 1, read: {
            if first {
                first = false
                return await withCheckedContinuation { pending = $0 }
            }
            return latest
        }, pause: {})
        let task = Task { await model.applyLatest() }
        while pending == nil { await Task.yield() }
        model.saved()
        await model.applyLatest()
        XCTAssertEqual(model.phase, .applied)
        pending?.resume(returning: old)
        await task.value
        XCTAssertEqual(model.savedRevision, "latest")
        XCTAssertEqual(model.confirmed?.revision, "latest")
    }

    func testMetadataReadFailureIsOwnerVisibleAndRetryRecovers() async throws {
        var fail = true
        let good = try status("new", ack: "new")
        let model = ProviderRoutingApplication(attempts: 1, read: {
            if fail { throw NSError(domain: "Fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot read acknowledgement"]) }
            return good
        }, pause: {})
        await model.applyLatest()
        XCTAssertEqual(model.phase, .failed)
        XCTAssertEqual(model.diagnostic, "Cannot read acknowledgement")
        fail = false
        await model.applyLatest()
        XCTAssertEqual(model.phase, .applied)
        XCTAssertNil(model.diagnostic)
    }
}

extension ProviderRoutingApplicationTests {
    func testDaemonLossRevokesAppliedConfirmationAndRetryConfirmsReplacement() async throws {
        var current = try status("saved", ack: "saved")
        let model = ProviderRoutingApplication(attempts: 1, read: { current }, pause: {})
        await model.applyLatest()
        XCTAssertEqual(model.phase, .applied)
        model.daemonUnavailable()
        XCTAssertEqual(model.phase, .failed)
        XCTAssertEqual(model.savedRevision, "saved")
        XCTAssertNil(model.confirmed)
        XCTAssertNotNil(model.diagnostic)
        current = try status("saved", ack: "saved", identity: "replacement")
        await model.applyLatest()
        XCTAssertEqual(model.phase, .applied)
        XCTAssertEqual(model.confirmed?.identity, "replacement")
    }

    func testLocalAckDiagnosticDecodesAndIsVisible() async throws {
        let data = Data("""
            {"preferred_provider":"codex","enabled":false,"revision":"saved","providers":[],
             "application_error":"The background configuration acknowledgement is corrupt"}
            """.utf8)
        let model = ProviderRoutingApplication(attempts: 1, read: { try ChatRoutingStatus.parse(data) }, pause: {})
        await model.applyLatest()
        XCTAssertEqual(model.phase, .failed)
        XCTAssertEqual(model.diagnostic, "The background configuration acknowledgement is corrupt")
    }
}

extension ProviderRoutingApplicationTests {
    func testLossAndWorkspaceSwitchRejectDelayedPreviousScopeAck() async throws {
        for workspaceChanged in [false, true] {
            let old = try status("old", ack: "old")
            var pending: CheckedContinuation<ChatRoutingStatus, Never>?
            let model = ProviderRoutingApplication(attempts: 1, read: {
                await withCheckedContinuation { pending = $0 }
            }, pause: {})
            let task = Task { await model.applyLatest() }
            while pending == nil { await Task.yield() }
            if workspaceChanged { model.configurationReloaded() } else { model.daemonUnavailable() }
            pending?.resume(returning: old)
            await task.value
            XCTAssertEqual(model.phase, .failed)
            XCTAssertNil(model.confirmed)
            XCTAssertNotNil(model.diagnostic)
        }
    }
}
