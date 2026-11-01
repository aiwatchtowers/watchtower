import Foundation

/// A relay origin the Kit refuses: not http(s), no host, or with a path, query,
/// fragment or user info.
public enum RelayOriginError: Error, Equatable {
    case invalid
}

/// The relay server's origin as the client knows it (the Go client's `base`).
/// Signed into the register and login messages, so it must be byte-for-byte the
/// string the relay expects.
public struct RelayOrigin: Equatable, Sendable {
    /// scheme://host[:port] as configured, trailing "/" trimmed (the Go client's
    /// `base`); signed at login and register.
    public let string: String
    public let url: URL

    /// Throws `RelayOriginError.invalid` for a non-http(s) URL or one with a
    /// path, query, fragment or user info.
    public init(_ string: String) throws {
        var trimmed = Substring(string)
        while trimmed.hasSuffix("/") { trimmed = trimmed.dropLast() }
        let candidate = String(trimmed)
        guard let parts = URLComponents(string: candidate),
              let scheme = parts.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = parts.host, !host.isEmpty,
              parts.path.isEmpty, parts.query == nil, parts.fragment == nil,
              parts.user == nil, parts.password == nil,
              let url = URL(string: candidate)
        else {
            throw RelayOriginError.invalid
        }
        self.string = candidate
        self.url = url
    }
}
