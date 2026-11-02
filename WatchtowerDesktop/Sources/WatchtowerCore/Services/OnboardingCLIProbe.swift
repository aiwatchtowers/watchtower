import Foundation

/// The Goals step's AI CLI check with the Codex fallback: a fresh install
/// has no `ai.provider`, so `ai test` tries Claude Code — an owner who has
/// only Codex would never get past the step. When the provider is unset,
/// no Claude Code binary is installed and the configured test fails, Codex
/// is tried; if it answers, it becomes the provider. An explicitly
/// configured provider, an unreadable config or an installed Claude Code
/// (a transient or sign-in failure) never switches.
package enum OnboardingCLIProbe {
    package static let fallbackProvider = "codex"

    /// What the check knows about the config before testing.
    package struct Inputs: Sendable {
        /// The config's `ai.provider` (nil or blank = unset, the Claude default).
        package var configuredProvider: String?
        /// config.yaml exists but could not be read or parsed: the provider
        /// is unknown, so nothing is switched.
        package var configUnreadable: Bool
        /// A Claude Code binary was found (`claude_path` or the usual places).
        package var claudeInstalled: Bool

        package init(configuredProvider: String?, configUnreadable: Bool, claudeInstalled: Bool) {
            self.configuredProvider = configuredProvider
            self.configUnreadable = configUnreadable
            self.claudeInstalled = claudeInstalled
        }

        var mayFallBack: Bool {
            let configured = configuredProvider?.trimmingCharacters(in: .whitespaces) ?? ""
            return configured.isEmpty && !configUnreadable && !claudeInstalled
        }
    }

    /// - Parameters:
    ///   - test: runs `ai test`, with `--provider <p>` when `p` is non-nil;
    ///     returns the provider the test answered for.
    ///   - switchProvider: writes `p` as the AI provider (and whatever goes
    ///     with it, such as the Workbench default agent).
    package static func check(
        _ inputs: Inputs,
        test: (String?) async throws -> String,
        switchProvider: (String) async throws -> Void
    ) async -> OnboardingCLICheck {
        let firstError: Error
        do {
            return .ready(provider: try await test(nil))
        } catch {
            firstError = error
        }
        guard inputs.mayFallBack else { return .failed(firstError.localizedDescription) }
        do {
            _ = try await test(fallbackProvider)
        } catch {
            return .failed(
                "Claude Code: \(firstError.localizedDescription)\nCodex CLI: \(error.localizedDescription)"
            )
        }
        do {
            try await switchProvider(fallbackProvider)
        } catch {
            return .failed("Codex CLI works, but it could not be set as the AI provider: \(error.localizedDescription)")
        }
        return .ready(provider: fallbackProvider, switched: true)
    }
}
