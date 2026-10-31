#if canImport(DeviceCheck)
import DeviceCheck
#endif
import Foundation

/// The App Attest calls the relay client makes (`DCAppAttestService` in
/// production, `FakeAppAttest` in tests). Key ids are the base64 strings
/// `generateKey` returns; they are secrets of the device and never logged.
public protocol AppAttesting: Sendable {
    var isSupported: Bool { get }
    func generateKey() async throws -> String
    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data
    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data
}

/// How a DeviceCheck failure is handled (proto README, "Failure paths on the client").
public enum AppAttestFailure: Error, Equatable, Sendable {
    /// The key is unknown or unusable: discard it, generate a new one, attest again.
    case invalidKey
    /// Apple's server could not be reached: keep the key and retry with backoff.
    case serverUnavailable
    /// Anything else (`dc_<code>` or `unknown`): retry with backoff.
    case other(String)
}

extension AppAttestFailure {
    /// DCError.invalidKey → .invalidKey; DCError.serverUnavailable and any URLError → .serverUnavailable;
    /// any other DCError → .other("dc_<code>"); anything else → .other("unknown").
    public static func classify(_ error: any Error) -> AppAttestFailure {
        if let failure = error as? AppAttestFailure { return failure }
        if error is URLError { return .serverUnavailable }
        #if canImport(DeviceCheck)
        if let dcError = error as? DCError {
            switch dcError.code {
            case .invalidKey: return .invalidKey
            case .serverUnavailable: return .serverUnavailable
            default: return .other("dc_\(dcError.code.rawValue)")
            }
        }
        #endif
        return .other("unknown")
    }
}
