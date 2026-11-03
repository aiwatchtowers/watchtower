import CryptoKit
import Foundation
import Observation
import os
import WatchtowerCore
import WatchtowerSync

/// One `watchtower hub adopt …` run: its stdout and exit code. The verb
/// prints its JSON answer (with the error class) even when it exits non-zero,
/// so the driver reads stdout either way.
struct HubAdoptOutput: Sendable {
    let stdout: Data
    let exitCode: Int32
}

/// Runs `watchtower hub adopt …` with `stdin` written to the child's standard
/// input and closed: settings and keys go only there, never argv, a file or
/// another descriptor (spec §12.2). Throws only when the child cannot start.
/// A cancelled run terminates the child.
protocol HubAdoptRunning: Sendable {
    func run(_ args: [String], stdin: Data) async throws -> HubAdoptOutput
}

/// The live runner over the installed `watchtower` binary: the child in a
/// process group of its own (`CodeCLIProcess`), the whole group terminated
/// when the run is cancelled (the driver's per-step deadline).
struct ProcessHubAdoptRunner: HubAdoptRunning {
    let binaryPath: String

    func run(_ args: [String], stdin: Data) async throws -> HubAdoptOutput {
        let environment = await Constants.resolvedEnvironmentAsync()
        let child = try CodeCLIProcess.launch(executable: binaryPath, arguments: args, environment: environment)
        child.send(stdin)
        child.closeInput()
        return await withTaskCancellationHandler {
            var stdout = Data()
            for await chunk in child.output { stdout.append(chunk) }
            let exit = await child.exitStatus
            return HubAdoptOutput(stdout: stdout, exitCode: exit.signaled ? -1 : exit.status)
        } onCancel: {
            child.terminateGroup()
        }
    }
}

/// What the live driver runs on; tests pass fakes (`AppState.hubAdoptionDeps`).
struct HubAdoptionDeps {
    /// nil: no `watchtower` binary.
    var runner: (any HubAdoptRunning)?
    var keyStore: any HubKeyStore
    var stepDeadline: Duration = HubAdoptionDriver.stepDeadline
}

/// Hands Mobile over from the Swift hub to the Go hub, once (go hub plan 3
/// Task 22, spec §12.1–§12.2). The state comes only from `watchtower hub
/// adopt --status --json`; Desktop never names the Swift hub's files.
///
/// At launch the status is read first, unseen: with no Swift state nothing
/// shows at all. A Swift state waiting for adoption gets the POLICY-03 wipe
/// when `MobileSync = off`, then the driver waits for the v1-host restart
/// (`HostRestartStep.waitUntilSettled`, in this driver's own task, never on
/// the launch path, nothing shown meanwhile). Then: the Kit store's keys are
/// looked up (read only, never created) → the Swift hub stops and its
/// storage closes → Desktop's own transcription of the pending phone
/// recordings is cancelled → `hub adopt --settings-stdin` → `--keys-stdin`
/// → on `adopted` (exit 0) the Desktop items are deleted →
/// `--confirm-deleted`. Every call has a deadline. Each step is read back
/// from the status at the next launch, so a kill anywhere resumes there.
/// Any failure ends in `.failed(reason)` with Retry; the Swift hub stays off
/// (never two hubs, no fallback).
@MainActor
@Observable
final class HubAdoptionDriver {
    struct Seams {
        /// Returns once the v1-host restart no longer needs the owner.
        var waitForHostRestart: @MainActor () async -> Void
        /// `MobileSync = off` with a Swift state not adopted yet: the Swift
        /// hub is built only to remove what it published (POLICY-03).
        var policyOffWipe: @MainActor () async -> Void = {}
        /// Stops the Swift hub; true once its storage is closed.
        var stopSwiftHub: @MainActor () async -> Bool
        /// Cancels Desktop's own transcription of these phone recordings and
        /// returns once none of them runs (idempotent); their rows stay.
        var cancelPhoneRecordings: @MainActor ([String]) async -> Void
        /// The Go hub took these recordings: their rows go.
        var phoneRecordingsAdopted: @MainActor ([String]) async -> Void = { _ in }
        /// The adoption cannot take these recordings: Desktop offers them again.
        var releasePhoneRecordings: @MainActor ([String]) async -> Void = { _ in }
        var deps: HubAdoptionDeps
        /// The owner's settings for the Go hub (`mobileSyncEnabled`, read once).
        var settings: @MainActor () -> HubAdoptSettings
        /// The Go hub took the settings: the Desktop's copy goes.
        var settingsDelivered: @MainActor () -> Void
    }

    static let statusArgs = ["hub", "adopt", "--status", "--json"]
    static let settingsArgs = ["hub", "adopt", "--settings-stdin", "--json"]
    static let keysArgs = ["hub", "adopt", "--keys-stdin", "--json"]
    static let confirmArgs = ["hub", "adopt", "--confirm-deleted", "--json"]
    static let setAsideArgs = ["hub", "adopt", "--set-aside", "--json"]
    /// Each `hub adopt` call's deadline; past it the child's group is terminated.
    nonisolated static let stepDeadline: Duration = .seconds(120)
    /// Status reads per pass: each step reads the status again, so a status
    /// that never moves on cannot loop.
    static let maxRounds = 6
    /// Adoption failures the Go hub will not get past by itself: the phone
    /// recordings cancelled for it are Desktop's again.
    static let permanentClasses: Set<String> = ["swift_schema", "swift_corrupt", "swift_hub_id"]

    private(set) var state: HubAdoptionState = .idle
    /// A Swift state waits for adoption (the POLICY-03 wipe may build the
    /// Swift hub for it, and for nothing else).
    @ObservationIgnored private(set) var swiftStatePending = false

    @ObservationIgnored private let seams: Seams
    @ObservationIgnored private var inFlight: Task<HubAdoptionState, Never>?
    @ObservationIgnored private var restartSettled = false
    private static let logger = Logger(subsystem: Constants.bundleID, category: "HubAdoption")

    init(seams: Seams) {
        self.seams = seams
    }

    /// The launch's pass. A pass already running is joined, never doubled.
    func run() async -> HubAdoptionState {
        await joined { [weak self] in await self?.launchPass() ?? .idle }
    }

    /// **Retry**: a fresh pass from the recorded step.
    func retry() async -> HubAdoptionState {
        await joined { [weak self] in
            guard let self else { return .idle }
            return self.restartSettled ? await self.pass() : await self.launchPass()
        }
    }

    /// **Set up Mobile again** after `no_keys`, once the owner confirmed that
    /// the phones must be linked again: the Go hub sets the Swift state aside
    /// (nothing imported), then a fresh pass finds nothing to hand over.
    func setUpAgain() async -> HubAdoptionState {
        await joined { [weak self] in
            guard let self else { return .idle }
            guard let runner = self.seams.deps.runner else { return self.fail("no_cli") }
            self.state = .inProgress(step: "copy")
            do {
                let out = try await self.call(runner, Self.setAsideArgs, Data())
                let answer = try? JSONDecoder().decode(HubAdoptSetAsideAnswer.self, from: out.stdout)
                guard out.exitCode == 0, answer?.setAside == "done" else {
                    return self.fail(answer.map { $0.setAside.isEmpty ? "failed" : $0.setAside } ?? "failed")
                }
            } catch {
                return self.fail(Self.reason(error))
            }
            return await self.pass()
        }
    }

    private func joined(_ work: @escaping @MainActor () async -> HubAdoptionState) async -> HubAdoptionState {
        if let inFlight { return await inFlight.value }
        let task = Task { await work() }
        inFlight = task
        let result = await task.value
        inFlight = nil
        return result
    }

    /// Reads the status unseen, wipes for POLICY-03 when it applies, waits
    /// for the restart step, then runs the pass.
    private func launchPass() async -> HubAdoptionState {
        guard let runner = seams.deps.runner else { return fail("no_cli") }
        let status: HubAdoptStatus
        do {
            status = try await readStatus(runner)
        } catch {
            return fail(Self.reason(error))
        }
        switch status.next {
        case .nothing: return finish(.notNeeded)
        case .finished:
            seams.settingsDelivered()
            return finish(.done)
        case .adoptState:
            swiftStatePending = true
            await seams.policyOffWipe()
        case .handOverKeys, .deleteDesktopKeys:
            break
        }
        await seams.waitForHostRestart()
        restartSettled = true
        return await pass()
    }

    private func pass() async -> HubAdoptionState {
        state = .checking
        guard let runner = seams.deps.runner else { return fail("no_cli") }
        var stopped = false
        for _ in 0..<Self.maxRounds {
            let status: HubAdoptStatus
            do {
                status = try await readStatus(runner)
            } catch {
                return fail(Self.reason(error))
            }
            switch status.next {
            case .nothing:
                swiftStatePending = false
                return finish(.notNeeded)
            case .finished:
                return finish(.done)
            case .adoptState:
                state = .inProgress(step: status.step.isEmpty ? "copy" : status.step)
                // The keys first, read only: without them nothing is imported.
                if let failure = await probeKeys(hubID: status.hubID) { return fail(failure) }
                if !stopped {
                    // Never two hubs: hub adopt needs the Swift files closed,
                    // and cannot see an idle open handle itself.
                    guard await seams.stopSwiftHub() else { return fail("swift_busy") }
                    stopped = true
                }
                let names = status.pendingRecordings.map(\.audioName)
                await seams.cancelPhoneRecordings(names)
                if let failure = await adoptState(runner) {
                    if Self.permanentClasses.contains(failure) { await seams.releasePhoneRecordings(names) }
                    return fail(failure)
                }
                swiftStatePending = false
                await seams.phoneRecordingsAdopted(names)
            case .handOverKeys:
                seams.settingsDelivered() // a kill after the state adoption, before the read
                state = .inProgress(step: "keys")
                if let failure = await handOverKeys(runner, hubID: status.hubID) { return fail(failure) }
                return finish(.done) // adopted, deleted and confirmed
            case .deleteDesktopKeys:
                state = .inProgress(step: "cleanup")
                if let failure = await deleteAndConfirm(runner, hubID: status.hubID) { return fail(failure) }
                return finish(.done)
            }
        }
        return fail("failed")
    }

    /// One `hub adopt` call under the step deadline: past it the call is
    /// cancelled (the live runner terminates the child's group) and the step
    /// fails with `timeout`.
    private func call(_ runner: any HubAdoptRunning, _ args: [String], _ stdin: Data) async throws -> HubAdoptOutput {
        let deadline = seams.deps.stepDeadline
        return try await withThrowingTaskGroup(of: HubAdoptOutput?.self) { group in
            group.addTask { try await runner.run(args, stdin: stdin) }
            group.addTask {
                try? await Task.sleep(for: deadline)
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next(), let out = first else {
                Self.logger.error("hub adoption: a hub adopt call passed its deadline; its process group was terminated")
                throw AdoptFailure(reason: "timeout")
            }
            return out
        }
    }

    private func readStatus(_ runner: any HubAdoptRunning) async throws -> HubAdoptStatus {
        let out = try await call(runner, Self.statusArgs, Data())
        guard let status = try? JSONDecoder().decode(HubAdoptStatus.self, from: out.stdout) else {
            throw AdoptFailure(reason: "failed")
        }
        return status
    }

    /// `hub adopt --settings-stdin`; nil when the state adoption reached `done`.
    private func adoptState(_ runner: any HubAdoptRunning) async -> String? {
        let settings: Data
        do {
            settings = try JSONEncoder().encode(seams.settings())
        } catch {
            return "failed"
        }
        do {
            let out = try await call(runner, Self.settingsArgs, settings)
            guard let answer = try? JSONDecoder().decode(HubAdoptRunAnswer.self, from: out.stdout) else { return "failed" }
            switch answer.error {
            case "" where out.exitCode == 0, "already_adopted": // already: a kill after `done`, before the read
                seams.settingsDelivered()
                return nil
            case "no_swift_state":
                return nil // nothing left to adopt: the next status read says what is
            case "":
                return "failed"
            default:
                return answer.error
            }
        } catch {
            return Self.reason(error)
        }
    }

    /// The Kit store's identity, looked up without creating anything: nil
    /// when all three items are there.
    private func probeKeys(hubID: String) async -> String? {
        guard !hubID.isEmpty else { return "no_hub_id" }
        switch await lookUpKeys(hubID: hubID) {
        case .success(.some): return nil
        case .success(.none): return "no_keys"
        case let .failure(failure): return failure.reason
        }
    }

    private struct KeyFailure: Error { let reason: String }

    private func lookUpKeys(hubID: String) async -> Result<HubIdentityKeys?, KeyFailure> {
        let store = seams.deps.keyStore
        do {
            return .success(try await Task.detached { try store.existingHubIdentity(hubID: hubID) }.value)
        } catch KeyStoreError.corrupt(let detail) {
            Self.logger.error("hub adoption: the Keychain identity is partial (\(detail, privacy: .public))")
            return .failure(KeyFailure(reason: "keys_partial"))
        } catch {
            Self.logger.error("hub adoption: the Keychain identity could not be read")
            return .failure(KeyFailure(reason: "keychain_unavailable"))
        }
    }

    /// The Kit store's identity to `hub adopt --keys-stdin`, then the Desktop
    /// items deleted and the deletion confirmed. Nothing is ever created.
    private func handOverKeys(_ runner: any HubAdoptRunning, hubID: String) async -> String? {
        guard !hubID.isEmpty else { return "no_hub_id" }
        let keys: HubIdentityKeys
        switch await lookUpKeys(hubID: hubID) {
        case let .success(found?): keys = found
        case .success(.none): return "no_keys"
        case let .failure(failure): return failure.reason
        }
        var payload: Data
        do {
            payload = try Self.keysPayload(keys)
        } catch {
            return "bad_keys"
        }
        defer { payload.resetBytes(in: 0..<payload.count) }
        do {
            let out = try await call(runner, Self.keysArgs, payload)
            let identity = (try? JSONDecoder().decode(HubAdoptIdentityAnswer.self, from: out.stdout))?.identity ?? ""
            guard out.exitCode == 0, identity == "adopted" else { return Self.refusal(identity, success: "adopted") }
        } catch {
            return Self.reason(error)
        }
        return await deleteAndConfirm(runner, hubID: hubID)
    }

    /// The Desktop's items go only after the Go hub adopted the identity; a
    /// confirm that never lands is retried with the delete at the next pass.
    private func deleteAndConfirm(_ runner: any HubAdoptRunning, hubID: String) async -> String? {
        guard !hubID.isEmpty else { return "no_hub_id" }
        state = .inProgress(step: "cleanup")
        let store = seams.deps.keyStore
        do {
            try await Task.detached { try store.deleteHubIdentity(hubID: hubID) }.value
        } catch {
            Self.logger.error("hub adoption: the Desktop's hub identity could not be deleted")
            return "keychain_unavailable"
        }
        do {
            let out = try await call(runner, Self.confirmArgs, Data())
            let identity = (try? JSONDecoder().decode(HubAdoptIdentityAnswer.self, from: out.stdout))?.identity ?? ""
            guard out.exitCode == 0, identity == "confirmed" else { return Self.refusal(identity, success: "confirmed") }
            return nil
        } catch {
            return Self.reason(error)
        }
    }

    enum PayloadError: Error { case keyBytes }

    /// `{"hub_sig","hub_kx","wrap"}` in standard base64 (Go's `[]byte`
    /// JSON). Zeroed: the wrap key's copy and each base64 buffer here, and
    /// the payload by the caller. Not zeroed: the `rawRepresentation` values
    /// (they may share CryptoKit's own storage) and CryptoKit's copies.
    nonisolated static func keysPayload(_ keys: HubIdentityKeys) throws -> Data {
        let sig = keys.signing.rawRepresentation
        let kx = keys.agreement.rawRepresentation
        var wrap = keys.wrapKey.withUnsafeBytes { Data($0) }
        defer { wrap.resetBytes(in: 0..<wrap.count) }
        guard sig.count == 32, kx.count == 32, wrap.count == 32 else { throw PayloadError.keyBytes }
        var payload = Data(capacity: 256) // one buffer: no grown copy left behind
        for (index, (name, bytes)) in [("hub_sig", sig), ("hub_kx", kx), ("wrap", wrap)].enumerated() {
            var encoded = bytes.base64EncodedData()
            defer { encoded.resetBytes(in: 0..<encoded.count) }
            payload.append(contentsOf: Array((index == 0 ? "{\"" : ",\"").utf8) + Array(name.utf8) + Array("\":\"".utf8))
            payload.append(encoded)
            payload.append(UInt8(ascii: "\""))
        }
        payload.append(UInt8(ascii: "}"))
        return payload
    }

    private struct AdoptFailure: Error { let reason: String }

    /// The class of a refused answer: its own, or `failed` for none or for
    /// the success word with a non-zero exit.
    private static func refusal(_ answer: String, success: String) -> String {
        answer.isEmpty || answer == success ? "failed" : answer
    }

    private static func reason(_ error: any Error) -> String {
        (error as? AdoptFailure)?.reason ?? "no_cli"
    }

    private func fail(_ reason: String) -> HubAdoptionState {
        Self.logger.error("hub adoption stopped (\(reason, privacy: .public)); Mobile stays off until Retry")
        return finish(.failed(reason: reason))
    }

    private func finish(_ next: HubAdoptionState) -> HubAdoptionState {
        state = next
        return next
    }
}
