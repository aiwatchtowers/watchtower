import AuthenticationServices
import SwiftUI
import WatchtowerCore

/// Constants for the OAuth redirect.
/// The HTTPS redirect URI must be registered in the Slack app settings.
enum OAuthConstants {
    static let redirectHost = "127.0.0.1"
    static let redirectPort = 18491
    static let callbackPath = "/callback"
    static let redirectURI = "https://127.0.0.1:18491/callback"
}

/// Presentation context provider for ASWebAuthenticationSession.
/// Held as a static to ensure the reference from the session stays alive.
final class OAuthPresentationContext: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = OAuthPresentationContext()

    @MainActor
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
    }
}

/// OAuth session manager for Slack authentication.
/// Uses ASWebAuthenticationSession to open auth in a separate window
/// that automatically closes and returns focus when done.
final class SlackOAuthManager {
    typealias AuthCompletion = (Result<String, Error>) -> Void

    enum OAuthError: LocalizedError {
        case invalidAuthURL
        case invalidCallbackURL
        case cancelled
        case cliNotFound
        /// A CLI step failed: what it was doing and its stderr (or launch error).
        case cliFailed(step: String, detail: String)

        var errorDescription: String? {
            switch self {
            case .invalidAuthURL:
                "Could not build Slack authorization URL"
            case .invalidCallbackURL:
                "Invalid OAuth callback URL"
            case .cancelled:
                "Authorization was cancelled"
            case .cliNotFound:
                "Watchtower CLI not found"
            case let .cliFailed(step, detail):
                detail.isEmpty ? "Could not \(step)" : "Could not \(step): \(detail)"
            }
        }
    }

    static let shared = SlackOAuthManager()

    /// Initiate OAuth flow in a separate window. Returns authorization code on success.
    func authenticate(cliPath: String, completion: @escaping AuthCompletion) {
        Task.detached {
            do {
                let authURL = try await Self.obtainAuthURL(cliPath: cliPath)
                let session = Self.createAuthSession(
                    url: authURL,
                    completion: completion
                )
                await MainActor.run {
                    session.presentationContextProvider = OAuthPresentationContext.shared
                    session.prefersEphemeralWebBrowserSession = false
                    if !session.start() {
                        completion(.failure(OAuthError.cancelled))
                    }
                }
            } catch {
                completion(.failure(error))
            }
        }
    }

    static func obtainAuthURL(cliPath: String) async throws -> URL {
        let trustArgs = ["auth", "trust-cert"]
        let trustResult = await runCLI(path: cliPath, arguments: trustArgs)
        try checkStep(trustResult, args: trustArgs, step: "trust the local certificate")

        let urlArgs = ["auth", "url"]
        let urlResult = await runCLI(path: cliPath, arguments: urlArgs)
        try checkStep(urlResult, args: urlArgs, step: "get the Slack authorization URL")

        guard let authURL = URL(
            string: urlResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        ) else {
            throw OAuthError.invalidAuthURL
        }
        guard URL(string: OAuthConstants.redirectURI) != nil else {
            throw OAuthError.invalidCallbackURL
        }
        return authURL
    }

    /// A failed step is logged and thrown with its stderr (or launch error).
    private static func checkStep(
        _ result: (stdout: String, stderr: String, exitCode: Int32), args: [String], step: String
    ) throws {
        guard result.exitCode != 0 else { return }
        CLILog.failure(args: args, exitCode: result.exitCode, stderr: result.stderr)
        throw OAuthError.cliFailed(step: step, detail: CLILog.detail(result.stderr))
    }

    private static func createAuthSession(
        url: URL,
        completion: @escaping AuthCompletion
    ) -> ASWebAuthenticationSession {
        ASWebAuthenticationSession(
            url: url,
            callbackURLScheme: "https"
        ) { callbackURL, error in
            if let error = error {
                let desc = error.localizedDescription.lowercased()
                if desc.contains("cancel") || desc.contains("user") {
                    completion(.failure(OAuthError.cancelled))
                } else {
                    completion(.failure(error))
                }
                return
            }
            guard let callbackURL = callbackURL else {
                completion(.failure(OAuthError.invalidCallbackURL))
                return
            }
            if let components = URLComponents(
                url: callbackURL,
                resolvingAgainstBaseURL: false
            ),
               let code = components.queryItems?.first(
                where: { $0.name == "code" }
               )?.value {
                completion(.success(code))
            } else {
                completion(.failure(OAuthError.invalidCallbackURL))
            }
        }
    }

    private static func runCLI(path: String, arguments: [String]) async -> (stdout: String, stderr: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        // Both streams drained while it runs, off the concurrency pool; a
        // launch failure is exit -1 with its error (ProcessPipes).
        let output = await ProcessPipes.run(process)
        return (output.stdout, output.stderr, output.exitCode)
    }
}
