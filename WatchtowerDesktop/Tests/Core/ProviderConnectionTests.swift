import XCTest
@testable import WatchtowerCore

@MainActor
final class ProviderConnectionTests: XCTestCase {
    private func selected(_ provider: String = "codex", model: String = "form-model") -> ProviderConnection.Selection {
        .init(provider: provider, model: model, path: "/fixture/cli", configPath: "/fixture/config")
    }
    func testMetadataNeverCallsInferenceAndPreservesEachOutcomeBothDirections() async {
        for provider in ["claude", "codex"] {
            for (metadata, state) in [(ProviderConnection.Metadata.missingCLI, ProviderFallbackPreview.State.notInstalled),
                                      (.missingSignIn, .connectionError), (.notVerified, .notVerified), (.networkError, .connectionNetworkError)] {
                var tests = 0
                let model = ProviderConnection(metadata: { _ in metadata }, test: { selection in
                    tests += 1
                    return .init(ok: true, provider: selection.provider, model: selection.model)
                })
                XCTAssertNil(model.copy)
                XCTAssertEqual(model.label(for: provider), "Not verified")
                await model.check(selected(provider), policy: .init())
                XCTAssertEqual(model.state, state)
                XCTAssertEqual(tests, 0)
                XCTAssertFalse(model.testing)
                XCTAssertTrue(model.copy?.title.contains(ProviderConnection.name(provider)) == true)
            }
        }
    }
    func testWarningAndArgumentsExerciseExactUnsavedSelectionWithoutSaveOrFallback() {
        for provider in ["claude", "codex"] {
            let value = selected(provider)
            XCTAssertEqual(ProviderConnection.arguments(value), [
                "--config", "/fixture/config", "--provider", provider,
                "ai", "test", "--model", "form-model", "--cli-path", "/fixture/cli"
            ])
        }
        XCTAssertTrue(ProviderConnection.warning.contains("one short AI request"))
        XCTAssertTrue(ProviderConnection.warning.contains("does not test the light model or enable reserve"))
    }
    func testPolicyDenialStartsNeitherMetadataNorInference() async {
        var calls = 0
        let model = ProviderConnection(metadata: { _ in calls += 1; return .notVerified }, test: { selection in
            calls += 1; return .init(ok: true, provider: selection.provider, model: selection.model)
        })
        var policy = ManagedPolicy()
        policy.allowedAIProviders = []
        await model.check(selected(), policy: policy)
        XCTAssertEqual(model.state, .policy)
        model.startTest(selected(), policy: policy)
        await Task.yield()
        XCTAssertEqual(calls, 0)
        XCTAssertFalse(model.testing)
    }
    func testExplicitResultsBothDirectionsAndMismatchedIdentityCannotSucceed() async {
        for provider in ["claude", "codex"] {
            for succeeds in [true, false] {
                let model = ProviderConnection(metadata: { _ in .notVerified }, test: { selection in
                    .init(ok: succeeds, provider: selection.provider, model: selection.model, error: succeeds ? nil : "quota")
                })
                model.startTest(selected(provider), policy: .init())
                await settle(model)
                XCTAssertEqual(model.state, succeeds ? .ready : .notVerified)
                XCTAssertFalse(model.testing)
                XCTAssertTrue(model.copy?.detail.contains(succeeds ? "form-model" : "short AI request") == true)
            }
        }
        let model = ProviderConnection(metadata: { _ in .notVerified }, test: { _ in .init(ok: true, provider: "claude", model: "other") })
        model.startTest(selected(), policy: .init())
        await settle(model)
        XCTAssertEqual(model.state, .connectionNetworkError)
        XCTAssertEqual(model.result, ProviderConnection.mismatchedResult)
    }
    func testChangedSelectionCancelsRunningTestAndRejectsLateSuccess() async {
        var finish: CheckedContinuation<ProviderConnection.Result, Error>?
        let model = ProviderConnection(metadata: { _ in .notVerified }, test: { _ in try await withCheckedThrowingContinuation { finish = $0 } })
        model.startTest(selected(), policy: .init())
        while finish == nil { await Task.yield() }
        XCTAssertTrue(model.testing)
        XCTAssertNil(model.copy?.action)
        model.invalidate()
        finish?.resume(returning: .init(ok: true, provider: "codex", model: "form-model"))
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(model.state, .empty)
        XCTAssertNil(model.selection)
        XCTAssertNil(model.result)
        XCTAssertFalse(model.testing)
    }
    func testMetadataAndTestErrorsHaveDifferentRetryDetailsAndNoFalseSuccess() async {
        let model = ProviderConnection(metadata: { _ in throw URLError(.cannotConnectToHost) },
                                       test: { _ in throw URLError(.timedOut) })
        await model.check(selected(), policy: .init())
        XCTAssertEqual(model.result, ProviderConnection.metadataFailure)
        model.startTest(selected(), policy: .init())
        await settle(model)
        XCTAssertEqual(model.result, ProviderConnection.testFailure)
        model.startTest(selected(model: ""), policy: .init())
        XCTAssertEqual(model.result, ProviderConnection.modelRequired)
        XCTAssertFalse(model.testing)
    }
    /// A CLI message that names its own next step (codex ignoring the probe's
    /// system prompt: update the CLI or its config, then test again) is never
    /// prefixed with "retry the test", which would contradict it; a bare
    /// classification keeps the retry advice.
    func testAFailureThatNamesItsOwnNextStepIsNotToldToRetry() async {
        let ownStep = "Codex answered but ignored Watchtower's instructions. Update the Codex CLI, or check its config, "
            + "and test again."
        for (code, error, expected) in [
            ("invalid_output", ownStep, "Connection test failed. " + ownStep),
            ("unknown", "Provider request failed (unknown).",
             ProviderConnection.testFailure + " Provider request failed (unknown)."),
            ("invalid_output", nil, ProviderConnection.testFailure)
        ] as [(String, String?, String)] {
            let model = ProviderConnection(metadata: { _ in .notVerified }, test: { selection in
                .init(ok: false, provider: selection.provider, model: selection.model, error: error, errorCode: code)
            })
            model.startTest(selected("codex"), policy: .none)
            await settle(model)
            XCTAssertEqual(model.result, expected, code)
            XCTAssertEqual(model.state, .notVerified)
        }
    }
    func testTypedAuthPolicyAndTransportFailureStatesBothDirections() async {
        for provider in ["claude", "codex"] {
            for (code, state) in [("auth", ProviderFallbackPreview.State.connectionError),
                                  ("transport", .connectionNetworkError), ("policy", .policy), ("unknown", .notVerified)] {
                let model = ProviderConnection(metadata: { _ in .notVerified }, test: { selection in
                    .init(ok: false, provider: selection.provider, model: selection.model, errorCode: code)
                })
                model.startTest(selected(provider), policy: .none)
                await settle(model)
                XCTAssertEqual(model.state, state)
                XCTAssertTrue(model.copy?.title.contains(ProviderConnection.name(provider)) == true)
                XCTAssertFalse(model.copy?.detail.contains("still your preferred") == true)
            }
        }
        let local = ProviderConnection()
        await local.check(.init(provider: "ollama", model: "fixture", path: "", configPath: "unused"), policy: .none)
        XCTAssertEqual(local.copy?.title, "Local connection isn't verified")
        XCTAssertTrue(local.copy?.detail.contains("per distinct light and strong model") == true)
    }
    func testQuitCancellationAwaitsRunningOperationAndCannotRestoreSuccess() async {
        var stopped = false
        let model = ProviderConnection(metadata: { _ in .notVerified }, test: { _ in
            do { try await Task.sleep(for: .seconds(30)) } catch { stopped = true; throw error }
            return .init(ok: true, provider: "codex", model: "form-model")
        })
        model.startTest(selected(), policy: .none)
        await Task.yield()
        await model.cancelAndWait()
        XCTAssertTrue(stopped)
        XCTAssertNil(model.copy)
        XCTAssertFalse(model.testing)
    }

    func testDefaultMetadataNeverExecutesFakeCLIOrFollowsSymlinkOrProtectedPath() async throws {
        // Foundation intentionally shortens /private/var back to the /var alias;
        // keep this owned fixture under a literal, symlink-free macOS temp root.
        let directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("fake-cli").path
        let marker = directory.appendingPathComponent("started").path
        try "#!/bin/sh\ntouch '\(marker)'\n".write(toFile: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable)
        let model = ProviderConnection()
        await model.check(.init(provider: "claude", model: "fixture", path: executable, configPath: "unused"), policy: .none)
        XCTAssertEqual(model.state, .notVerified)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker))
        let home = directory.path
        XCTAssertEqual(try ProviderExecutableMetadata.check(path: home + "/Documents/not-read", home: home), .notVerified)
        let link = directory.appendingPathComponent("linked-cli").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: home + "/Documents/not-read")
        XCTAssertEqual(try ProviderExecutableMetadata.check(path: link, home: home), .notVerified)
        XCTAssertEqual(try ProviderExecutableMetadata.check(path: home + "/missing", home: home), .missingCLI)
    }

    func testMetadataRetryAfterExplicitTestNeverSendsInference() async {
        for provider in ["claude", "codex"] {
            for metadata in [ProviderConnection.Metadata.missingCLI, .missingSignIn, .networkError] {
                var metadataCalls = 0
                var inferenceCalls = 0
                let model = ProviderConnection(metadata: { _ in metadataCalls += 1; return metadata }, test: { selection in
                    inferenceCalls += 1
                    return .init(ok: true, provider: selection.provider, model: selection.model)
                })
                model.startTest(selected(provider), policy: .none)
                await settle(model)
                await model.check(selected(provider), policy: .none)
                XCTAssertEqual(model.copy?.action, "Retry connection check")
                await model.performAction(policy: .none)
                await settle(model)
                XCTAssertEqual(metadataCalls, 2)
                XCTAssertEqual(inferenceCalls, 1)
                XCTAssertNotEqual(model.state, .ready)
                await model.cancelAndWait()
            }
        }
    }

    func testInvalidatedProbeIsJoinedByEveryQuitCaller() async {
        var cleanup: CheckedContinuation<ProviderConnection.Result, Never>?
        let model = ProviderConnection(metadata: { _ in .notVerified }, test: { _ in
            await withCheckedContinuation { cleanup = $0 }
        })
        model.startTest(selected(), policy: .none)
        while cleanup == nil { await Task.yield() }
        model.invalidate()
        var started = 0
        var finished = 0
        let first = Task { started += 1; await model.cancelAndWait(); finished += 1 }
        let second = Task { started += 1; await model.cancelAndWait(); finished += 1 }
        while started < 2 { await Task.yield() }
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(finished, 0, "both quit callers must await canceled subprocess cleanup")
        cleanup?.resume(returning: .init(ok: true, provider: "codex", model: "form-model"))
        await first.value
        await second.value
        XCTAssertEqual(finished, 2)
        XCTAssertNil(model.copy)
        XCTAssertNil(model.result)
        XCTAssertFalse(model.testing)
    }

    func testReplacementQuitWaitsForBothOldAndCurrentCleanup() async {
        var cleanups: [String: CheckedContinuation<ProviderConnection.Result, Never>] = [:]
        let model = ProviderConnection(metadata: { _ in .notVerified }, test: { selection in
            await withCheckedContinuation { cleanups[selection.model] = $0 }
        })
        model.startTest(selected(model: "old-model"), policy: .none)
        while cleanups["old-model"] == nil { await Task.yield() }
        model.startTest(selected(model: "new-model"), policy: .none)
        while cleanups["new-model"] == nil { await Task.yield() }
        var started = false
        var finished = false
        let quit = Task { started = true; await model.cancelAndWait(); finished = true }
        while !started { await Task.yield() }
        cleanups["new-model"]?.resume(returning: .init(ok: true, provider: "codex", model: "new-model"))
        for _ in 0..<100 { await Task.yield() }
        XCTAssertFalse(finished, "finishing the current child must not forget the canceled old child")
        XCTAssertNil(model.copy)
        cleanups["old-model"]?.resume(returning: .init(ok: true, provider: "codex", model: "old-model"))
        await quit.value
        XCTAssertTrue(finished)
        XCTAssertNil(model.result)
        XCTAssertFalse(model.testing)
    }

    private func settle(_ model: ProviderConnection) async {
        for _ in 0..<100 where model.testing { await Task.yield() }
        XCTAssertFalse(model.testing)
    }
}
