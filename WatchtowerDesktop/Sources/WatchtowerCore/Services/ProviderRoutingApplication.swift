import Foundation
import Observation

/// Saved configuration and the last confirmed daemon configuration are distinct.
/// This model only reads metadata: Retry never saves a captured Settings draft.
@MainActor
@Observable
package final class ProviderRoutingApplication {
    package enum Phase: Equatable { case idle, applying, applied, failed }
    package private(set) var phase: Phase = .idle
    package private(set) var savedRevision: String?
    package private(set) var confirmed: ChatRoutingStatus.Application?
    package private(set) var diagnostic: String?
    private var operation = 0
    private let read: () async throws -> ChatRoutingStatus
    private let pause: () async throws -> Void
    private let attempts: Int

    package init(
        attempts: Int = 20,
        read: @escaping () async throws -> ChatRoutingStatus,
        pause: @escaping () async throws -> Void = { try await Task.sleep(for: .milliseconds(500)) }
    ) {
        self.attempts = attempts
        self.read = read
        self.pause = pause
    }

    /// A Save supersedes any older in-flight apply result immediately.
    package func saved() {
        operation += 1
        phase = .applying
        diagnostic = nil
    }

    /// Existing daemon-status observations revoke confirmation immediately.
    /// A later Retry confirms the current run identity through Go metadata.
    package func configurationReloaded() {
        operation += 1
        confirmed = nil
        savedRevision = nil
        guard phase != .idle else { return }
        phase = .failed
        diagnostic = "The saved settings were reloaded. Confirm the current background configuration."
    }

    package func daemonUnavailable() {
        guard phase != .idle else { return }
        operation += 1
        phase = .failed
        confirmed = nil
        diagnostic = "The background service is not running."
    }

    package func applyLatest() async {
        operation += 1
        let current = operation
        phase = .applying
        diagnostic = nil
        do {
            for index in 0..<attempts {
                let status = try await read()
                guard current == operation else { return }
                savedRevision = status.revision
                confirmed = status.application
                if let ack = status.application, ack.error == nil,
                   ack.revision == status.revision, ack.savedVersion == status.savedVersion {
                    diagnostic = nil
                    phase = .applied
                    return
                }
                diagnostic = status.applicationError ?? status.application?.error
                if index + 1 < attempts { try await pause() }
                guard current == operation else { return }
            }
            phase = .failed
        } catch {
            guard current == operation else { return }
            diagnostic = error.localizedDescription
            phase = .failed
        }
    }

    package var copy: ProviderFallbackPreview.Copy? {
        switch phase {
        case .idle: return nil
        case .applied:
            return .init(title: "Settings saved and applied", detail: "New background tasks use the saved AI settings.",
                         action: nil, emphasis: .success)
        case .applying:
            let approved = ProviderFallbackPreview(preferred: .claude, state: .applying).copy
            return .init(title: approved.title,
                         detail: "Waiting for the background service to confirm the saved settings. "
                            + "Active tasks and Workbench sessions keep running.",
                         action: nil, emphasis: approved.emphasis, busy: true)
        case .failed:
            let approved = ProviderFallbackPreview(preferred: .claude, state: .applyError).copy
            return .init(title: approved.title,
                         detail: "The current background configuration is not confirmed. Retry to apply the latest saved settings.",
                         action: approved.action, emphasis: approved.emphasis)
        }
    }

    package var confirmationText: String? {
        guard phase == .failed, let confirmed else { return nil }
        return "Last confirmed provider: \(confirmed.preferredProvider) · revision \(confirmed.revision.prefix(8))"
    }
}
