#if canImport(DeviceCheck)
import DeviceCheck
import Foundation

/// `DCAppAttestService.shared` behind `AppAttesting`. Every thrown error goes
/// through `AppAttestFailure.classify`, so callers only see `AppAttestFailure`.
public struct DeviceCheckAppAttest: AppAttesting {
    public init() {}

    public var isSupported: Bool {
        DCAppAttestService.shared.isSupported
    }

    public func generateKey() async throws -> String {
        do {
            return try await DCAppAttestService.shared.generateKey()
        } catch {
            throw AppAttestFailure.classify(error)
        }
    }

    public func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data {
        do {
            return try await DCAppAttestService.shared.attestKey(keyID, clientDataHash: clientDataHash)
        } catch {
            throw AppAttestFailure.classify(error)
        }
    }

    public func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data {
        do {
            return try await DCAppAttestService.shared.generateAssertion(keyID, clientDataHash: clientDataHash)
        } catch {
            throw AppAttestFailure.classify(error)
        }
    }
}
#endif
