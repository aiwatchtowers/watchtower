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
protocol HubAdoptRunning: Sendable {
    func run(_ args: [String], stdin: Data) async throws -> HubAdoptOutput
}

/// The live runner over the installed `watchtower` binary.
struct ProcessHubAdoptRunner: HubAdoptRunning {
    let binaryPath: String

    func run(_ args: [String], stdin: Data) async throws -> HubAdoptOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = args
        process.environment = await Constants.resolvedEnvironmentAsync()
        process.currentDirectoryURL = Constants.processWorkingDirectory()
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let stdoutRead = ProcessPipes.drain(output)
        let stderrRead = ProcessPipes.drain(errors)
        ProcessPipes.feed(input, stdin)
        let data = await stdoutRead.value
        _ = await stderrRead.value
        await ProcessPipes.offPool { process.waitUntilExit() }
        return HubAdoptOutput(stdout: data, exitCode: process.terminationStatus)
    }
}

/// Hands Mobile over from the Swift hub to the Go hub, once (go hub plan 3
/// Task 22, spec §12.1–§12.2). The state comes only from `watchtower hub
/// adopt --status --json`; Desktop never names the Swift hub's files.
///
/// Order: the v1-host restart settles (`HostRestartStep.waitUntilSettled`,
/// awaited in this driver's own task, never on the launch path) → the Swift
/// hub stops and its storage closes → Desktop's own transcription of the
/// pending phone recordings is cancelled → `hub adopt --settings-stdin` →
/// the Kit key store's hub identity → `hub adopt --keys-stdin` → on
/// `adopted` the Desktop items are deleted → `hub adopt --confirm-deleted`.
/// Each step is read back from the status at the next launch, so a kill
/// anywhere resumes there (a missing confirm deletes again). Any failure
/// ends in `.failed(reason)` with Retry; the Swift hub stays off (never two
/// hubs, no fallback).
@MainActor
@Observable
final class HubAdoptionDriver {
    struct Seams {
        /// Returns once the v1-host restart no longer needs the owner.
        var waitForHostRestart: @MainActor () async -> Void
        /// Stops the Swift hub and returns once its storage is closed.
        var stopSwiftHub: @MainActor () async -> Void
        /// Cancels Desktop's own transcription of these phone recordings and
        /// returns once none of them runs (idempotent).
        var cancelPhoneRecordings: @MainActor ([String]) async -> Void
        /// nil: no `watchtower` binary.
        var runner: (any HubAdoptRunning)?
        var keyStore: any HubKeyStore
        /// The owner's settings for the Go hub (`mobileSyncEnabled`, read once).
        var settings: @MainActor () -> HubAdoptSettings
        /// The Go hub took the settings: the Desktop's copy goes.
        var settingsDelivered: @MainActor () -> Void
    }

    static let statusArgs = ["hub", "adopt", "--status", "--json"]
    static let settingsArgs = ["hub", "adopt", "--settings-stdin", "--json"]
    static let keysArgs = ["hub", "adopt", "--keys-stdin", "--json"]
    static let confirmArgs = ["hub", "adopt", "--confirm-deleted", "--json"]
    /// Status reads per pass: each step reads the status again, so a status
    /// that never moves on cannot loop.
    static let maxRounds = 6

    private(set) var state: HubAdoptionState = .checking

    @ObservationIgnored private let seams: Seams
    @ObservationIgnored private var inFlight: Task<HubAdoptionState, Never>?
    @ObservationIgnored private var restartSettled = false
    private static let logger = Logger(subsystem: Constants.bundleID, category: "HubAdoption")

    init(seams: Seams) {
        self.seams = seams
    }

    /// The launch's pass: waits for the restart step first. A pass already
    /// running is joined, never doubled.
    func run() async -> HubAdoptionState {
        if let inFlight { return await inFlight.value }
        let task = Task { [weak self] () -> HubAdoptionState in
            guard let self else { return .checking }
            if !self.restartSettled {
                await self.seams.waitForHostRestart()
                self.restartSettled = true
            }
            return await self.pass()
        }
        inFlight = task
        let result = await task.value
        inFlight = nil
        return result
    }

    /// **Retry**: the same pass again, from the recorded step.
    func retry() async -> HubAdoptionState {
        await run()
    }

    private func pass() async -> HubAdoptionState {
        state = .checking
        guard let runner = seams.runner else { return fail("no_cli") }
        var stopped = false
        for _ in 0..<Self.maxRounds {
            let status: HubAdoptStatus
            do {
                status = try await readStatus(runner)
            } catch {
                return fail(error)
            }
            switch status.next {
            case .nothing:
                return finish(.notNeeded)
            case .finished:
                return finish(.done)
            case .adoptState:
                state = .inProgress(step: status.step.isEmpty ? "copy" : status.step)
                if !stopped {
                    // Never two hubs: hub adopt needs the Swift files closed,
                    // and cannot see an idle open handle itself.
                    await seams.stopSwiftHub()
                    stopped = true
                }
                await seams.cancelPhoneRecordings(status.pendingRecordings.map(\.audioName))
                if let failure = await adoptState(runner) { return fail(failure) }
            case .handOverKeys:
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

    private func readStatus(_ runner: any HubAdoptRunning) async throws -> HubAdoptStatus {
        let out = try await runner.run(Self.statusArgs, stdin: Data())
        do {
            return try JSONDecoder().decode(HubAdoptStatus.self, from: out.stdout)
        } catch {
            throw AdoptFailure(reason: "failed")
        }
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
            let out = try await runner.run(Self.settingsArgs, stdin: settings)
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
            return Self.launchFailure(error)
        }
    }

    /// The Kit key store's identity to `hub adopt --keys-stdin`, then the
    /// Desktop items deleted and the deletion confirmed. A freshly created
    /// identity means this Mac had no keys: it is deleted again and never
    /// handed over.
    private func handOverKeys(_ runner: any HubAdoptRunning, hubID: String) async -> String? {
        guard !hubID.isEmpty else { return "no_hub_id" }
        let store = seams.keyStore
        let loaded: (keys: HubIdentityKeys, created: Bool)
        do {
            loaded = try await Task.detached { try store.hubIdentity(hubID: hubID) }.value
        } catch {
            Self.logger.error("hub adoption: the Keychain identity could not be read")
            return "keychain_unavailable"
        }
        if loaded.created {
            do {
                try await Task.detached { try store.deleteHubIdentity(hubID: hubID) }.value
            } catch {
                Self.logger.error("hub adoption: the freshly created identity could not be deleted")
            }
            return "no_keys"
        }
        var payload = Self.keysPayload(loaded.keys)
        defer { payload.resetBytes(in: 0..<payload.count) }
        let identity: String
        do {
            let out = try await runner.run(Self.keysArgs, stdin: payload)
            identity = (try? JSONDecoder().decode(HubAdoptIdentityAnswer.self, from: out.stdout))?.identity ?? "failed"
        } catch {
            return Self.launchFailure(error)
        }
        guard identity == "adopted" else { return identity.isEmpty ? "failed" : identity }
        return await deleteAndConfirm(runner, hubID: hubID)
    }

    /// The Desktop's items go only after the Go hub adopted the identity; a
    /// confirm that never lands is retried with the delete at the next pass.
    private func deleteAndConfirm(_ runner: any HubAdoptRunning, hubID: String) async -> String? {
        state = .inProgress(step: "cleanup")
        let store = seams.keyStore
        if !hubID.isEmpty {
            do {
                try await Task.detached { try store.deleteHubIdentity(hubID: hubID) }.value
            } catch {
                Self.logger.error("hub adoption: the Desktop's hub identity could not be deleted")
                return "keychain_unavailable"
            }
        }
        do {
            let out = try await runner.run(Self.confirmArgs, stdin: Data())
            let identity = (try? JSONDecoder().decode(HubAdoptIdentityAnswer.self, from: out.stdout))?.identity ?? "failed"
            return identity == "confirmed" ? nil : (identity.isEmpty ? "failed" : identity)
        } catch {
            return Self.launchFailure(error)
        }
    }

    /// `{hub_sig, hub_kx, wrap}` in standard base64 (Go's `[]byte` JSON).
    nonisolated static func keysPayload(_ keys: HubIdentityKeys) -> Data {
        let wrap = keys.wrapKey.withUnsafeBytes { Data($0) }
        let fields = [
            "hub_sig": keys.signing.rawRepresentation.base64EncodedString(),
            "hub_kx": keys.agreement.rawRepresentation.base64EncodedString(),
            "wrap": wrap.base64EncodedString()
        ]
        return (try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])) ?? Data()
    }

    private struct AdoptFailure: Error { let reason: String }

    private static func launchFailure(_ error: any Error) -> String {
        (error as? AdoptFailure)?.reason ?? "no_cli"
    }

    private func fail(_ error: any Error) -> HubAdoptionState {
        fail(Self.launchFailure(error))
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
