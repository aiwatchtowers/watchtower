import XCTest
@testable import WatchtowerCore

@MainActor
final class ProviderSettingsHealthTests: XCTestCase {
    private func status(_ provider: String, state: String, reserve: String = "quota_wait", allowed: Bool = true) throws -> ChatRoutingStatus {
        try ChatRoutingStatus.parse(Data("""
        {"preferred_provider":"\(provider)","enabled":true,"revision":"saved-revision","providers":[
        {"provider":"\(provider)","state":"\(state)","manual_allowed":\(allowed),"next_probe_at":"2020-01-01T03:21:00Z"},
        {"provider":"\(provider == "codex" ? "claude" : "codex")","state":"\(reserve)"}]}
        """.utf8))
    }
    func testPastResetCannotDeclareRecoveredAndBothDirectionsUseRealTime() async throws {
        for provider in ["claude", "codex"] {
            let model = ProviderSettingsHealth()
            XCTAssertNil(model.copy)
            await model.refresh { try status(provider, state: "quota_wait") }
            XCTAssertEqual(model.copy?.title, "AI is waiting for limits to reset")
            XCTAssertTrue(model.copy?.detail.contains("2020") == true)
            XCTAssertFalse(model.copy?.detail.contains("14:30") == true)
            XCTAssertEqual(model.copy?.action, "Check again")
            await model.refresh { try status(provider, state: "quota_wait", reserve: "available") }
            XCTAssertEqual(model.copy?.title, "\(ProviderConnection.name(provider)) reached its limit")
            XCTAssertFalse(model.copy?.title.contains("Using") == true)
            await model.refresh { try status(provider, state: "probe_leased") }
            XCTAssertTrue(model.copy?.busy == true)
            XCTAssertNil(model.copy?.action)
            XCTAssertFalse(model.copy?.detail.contains("continue with") == true)
            await model.refresh { try status(provider, state: "available") }
            XCTAssertTrue(model.copy?.title.contains(ProviderConnection.name(provider == "codex" ? "claude" : "codex")) == true)
            XCTAssertFalse(model.copy?.title.contains("No saved") == true)
        }
    }
    func testRateLimitAndErrorsAreHonestAndRetryOnlyReadsMetadata() async throws {
        let model = ProviderSettingsHealth()
        await model.refresh { try status("codex", state: "quota_wait", allowed: false) }
        XCTAssertEqual(model.copy?.title, "Limits checked recently")
        await model.refresh { throw URLError(.cannotOpenFile) }
        XCTAssertTrue(model.failed)
        XCTAssertNil(model.status)
        XCTAssertEqual(model.copy?.action, ProviderSettingsHealth.retry)
        await model.refresh { try status("claude", state: "available", reserve: "available") }
        XCTAssertFalse(model.failed)
        XCTAssertEqual(model.copy?.title, "No saved quota block")
        XCTAssertTrue(model.copy?.detail.contains("not a connection test") == true)
    }
    func testReloadInvalidatesHeldMetadataAndBusyCopy() async throws {
        let model = ProviderSettingsHealth()
        var finish: CheckedContinuation<ChatRoutingStatus, Error>?
        let task = Task { await model.refresh { try await withCheckedThrowingContinuation { finish = $0 } } }
        while finish == nil { await Task.yield() }
        XCTAssertTrue(model.busy)
        XCTAssertTrue(model.copy?.busy == true)
        model.invalidate()
        finish?.resume(returning: try status("claude", state: "available"))
        await task.value
        XCTAssertNil(model.status)
        XCTAssertNil(model.copy)
        XCTAssertFalse(model.busy)
    }
}
