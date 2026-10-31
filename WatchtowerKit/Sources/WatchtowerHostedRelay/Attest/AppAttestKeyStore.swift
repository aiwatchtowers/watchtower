/// Where the device's App Attest key id lives. Phase 2 keeps it in memory
/// only; Phase 3 adds the Keychain store (R2).
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
