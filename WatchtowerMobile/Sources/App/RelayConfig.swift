import Foundation
import WatchtowerHostedRelay

/// The hosted relay's origin, read from the `WTRelayOrigin` Info.plist key (`$(WATCHTOWER_RELAY_ORIGIN)`).
///
/// Every committed build setting leaves the origin empty, so a Release build is "not configured" and ships dark:
/// no relay object, Keychain item, DeviceCheck call or relay connection exists (relay client Phase 3, global
/// constraints). A developer sets an origin only in the gitignored Signing.xcconfig.
struct RelayConfig: Equatable, Sendable {
    /// nil = not configured.
    let origin: RelayOrigin?

    static let infoPlistKey = "WTRelayOrigin"

    static func from(bundle: Bundle) -> Self {
        parse(bundle.object(forInfoDictionaryKey: infoPlistKey) as? String)
    }

    /// Empty or whitespace, a value still holding an unexpanded `$(`, an invalid origin, or plain `http` to a host
    /// that is neither loopback nor a private LAN address → not configured. `RelayOrigin` trims a trailing `/`.
    static func parse(_ raw: String?) -> Self {
        let notConfigured = Self(origin: nil)
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty, !value.contains("$("),
              let origin = try? RelayOrigin(value)
        else { return notConfigured }
        if origin.url.scheme?.lowercased() == "http" {
            guard let host = origin.url.host, isLoopbackOrLAN(host) else { return notConfigured }
        }
        return Self(origin: origin)
    }

    /// Plain `http` is for a phone talking to a stand on the developer's Mac: loopback, or a private IPv4 LAN
    /// address (10/8, 172.16/12, 192.168/16).
    private static func isLoopbackOrLAN(_ host: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" || host == "::1" { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        let octets = parts.compactMap { part -> Int? in
            guard !part.isEmpty, part.count <= 3, part.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(part),
                  (0...255).contains(value)
            else { return nil }
            return value
        }
        guard octets.count == 4 else { return false }
        switch (octets[0], octets[1]) {
        case (127, _), (10, _), (192, 168): return true
        case (172, 16...31): return true
        default: return false
        }
    }
}
