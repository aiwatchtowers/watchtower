/// Where the device's App Attest key id lives. The phone's store is
/// `KeychainRelayIdentity` (R2); `InMemoryAppAttestKeyStore` stays for tests.
public protocol AppAttestKeyStore: Sendable {
    func keyID() async -> String?
    func setKeyID(_ id: String?) async
}

public actor InMemoryAppAttestKeyStore: AppAttestKeyStore {
    private var stored: String?

    public init(keyID: String? = nil) {
        stored = keyID
    }

    public func keyID() -> String? {
        stored
    }

    public func setKeyID(_ id: String?) {
        stored = id
    }
}
