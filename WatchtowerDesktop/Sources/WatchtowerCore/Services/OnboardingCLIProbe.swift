import Foundation

/// The Goals step's AI CLI check with the Codex fallback: a fresh install
/// has no `ai.provider`, so `ai test` tries Claude Code — an owner who has
/// only Codex would never get past the step. When the provider is unset
/// and the configured test fails, Codex is tried; if it answers, it becomes
/// the provider. An explicitly configured provider is never switched.
package enum OnboardingCLIProbe {
    package static let fallbackProvider = "codex"

    /// - Parameters:
    ///   - configuredProvider: the config's `ai.provider` (nil or empty =
    ///     unset, the Claude default).
    ///   - test: runs `ai test`, with `--provider <p>` when `p` is non-nil;
    ///     returns the provider the test answered for.
    ///   - setProvider: `config set ai.provider <p>`.
    package static func check(
        configuredProvider: String?,
        test: (String?) async throws -> String,
        setProvider: (String) async throws -> Void
    ) async -> OnboardingCLICheck {
        let firstError: Error
        do {
            return .ready(provider: try await test(nil))
        } catch {
            firstError = error
        }
        let configured = configuredProvider?.trimmingCharacters(in: .whitespaces) ?? ""
        guard configured.isEmpty else { return .failed(firstError.localizedDescription) }
        do {
            _ = try await test(fallbackProvider)
        } catch {
            // Neither works: the configured (Claude) failure is the one the
            // install box explains.
            return .failed(firstError.localizedDescription)
        }
        do {
            try await setProvider(fallbackProvider)
        } catch {
            return .failed("Codex CLI works, but it could not be set as the AI provider: \(error.localizedDescription)")
        }
        return .ready(provider: fallbackProvider)
    }
}
