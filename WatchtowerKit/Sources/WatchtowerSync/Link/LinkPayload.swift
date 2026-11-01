import Foundation

/// Why a scanned URL is not a usable link code (spec §2.3).
public enum LinkPayloadError: Error, Equatable, Sendable {
    /// Not a `watchtower://link` URL.
    case notALink
    /// `d` is missing, not canonical base64url (padding, `+`, `/`, other
    /// characters), not JSON, or a field has the wrong type.
    case badEncoding
    /// A required key is absent (its wire name).
    case missingField(String)
    /// Written by a newer Mac: "Update Watchtower on this iPhone".
    case newerVersion
    /// Written by an older Mac (v1, the single-hub build's fixed-name
    /// zones): "Update Watchtower on this Mac" (multi-hub spec §6.7).
    case olderVersion
    /// A code for another CloudKit container.
    case wrongContainer
    /// A v4 code's relay identity is unusable: only one of `relay_device_id`/`relay_auth_pub`, a key that is not
    /// base64url of 32 non-zero bytes, or an id that is not `RelayIDs.deviceID` of the key (R6).
    case badRelayIdentity
}

/// The QR link code a Mac shows and a phone scans (mobile POC spec §2.3):
/// `watchtower://link?d=<base64url(JSON)>`, no padding, sorted keys.
///
/// Wire: snake_case keys, Unix-second `iat`/`exp`, unescaped slashes; a nil
/// optional is an absent key. Frozen by LinkPayloadTests.
///
/// The Kit reads v3 and v4 and issues v3 (relay client Phase 3, R6). v4 is the
/// Go hub's: `container` and `owner_user` become optional (a headless host has
/// neither) and the code may carry the hub's transports and relay identity. This type only
/// encodes and decodes: the expiry check (with the phone's clock-skew grace)
/// and the single-use nonce check belong to the link flow and the hub.
public struct LinkPayload: Codable, Equatable, Sendable {
    /// 3 since the E2E build (mobile E2E spec §2.3): the code carries the hub's public keys.
    /// 2 was the multi-hub build (spec §3.4): shares of the hub's own `DataZone-<hub_id>`/`RelayZone-<hub_id>`.
    public static let currentVersion = 3
    /// The newest version this build reads: 4, the Go hub's code (relay client Phase 3).
    public static let newestReadable = 4
    /// `exp = iat + lifetime`, in seconds.
    public static let lifetime: Int64 = 600
    /// Cap on `macName`, in grapheme clusters.
    public static let maxMacNameLength = 60
    static let scheme = "watchtower"
    static let host = "link"
    static let dataParameter = "d"

    public let v: Int
    /// Required in v3; nil in a v4 code from a hub without CloudKit.
    public let container: String?
    /// The hub's UUID (spec §4.1).
    public let hubID: String
    /// At most `maxMacNameLength` grapheme clusters, clipped on init and decode.
    public let macName: String
    /// The Mac's `CKContainer.userRecordID().recordName`. Required in v3; nil in a v4 code from a hub without CloudKit.
    public let ownerUser: String?
    /// 32 random bytes, base64url, 43 characters. Single use.
    public let nonce: String
    /// Issued at, Unix seconds.
    public let iat: Int64
    /// Expires at, Unix seconds.
    public let exp: Int64
    /// `CKShare.url` of the DataZone share; nil when the Mac has none.
    public let dataShare: String?
    /// `CKShare.url` of the RelayZone share; nil when the Mac has none.
    public let relayShare: String?
    /// `hub_sig` public key, base64url of 32 bytes.
    public let hubSigningKey: String
    /// `hub_kx` public key, base64url of 32 bytes.
    public let hubAgreementKey: String
    /// v4: the hub's current transport; nil when absent or a value this build does not know.
    public let transport: TransportKind?
    /// v4: every transport the hub offers, raw wire values.
    public let transports: [String]?
    /// v4: the hub's hosted-relay device id, `RelayIDs.deviceID` of `relayAuthPub`.
    public let relayDeviceID: String?
    /// v4: the hub's `relay_auth` public key, base64url of 32 bytes.
    public let relayAuthPub: String?

    /// The code can link over iCloud: v3, or v4 with a container and an owner.
    public var offersCloudKit: Bool { v < 4 || (container != nil && ownerUser != nil) }
    /// The code names a coherent relay identity for the hub.
    public var offersRelay: Bool {
        guard let relayDeviceID, let relayAuthPub else { return false }
        return Self.relayIdentityIsCoherent(deviceID: relayDeviceID, authPub: relayAuthPub)
    }

    enum CodingKeys: String, CodingKey {
        case v
        case container
        case hubID = "hub_id"
        case macName = "mac_name"
        case ownerUser = "owner_user"
        case nonce
        case iat
        case exp
        case dataShare = "data_share"
        case relayShare = "relay_share"
        case hubSigningKey = "hub_sig"
        case hubAgreementKey = "hub_kx"
        case transport
        case transports
        case relayDeviceID = "relay_device_id"
        case relayAuthPub = "relay_auth_pub"
    }

    public init(
        v: Int = Self.currentVersion,
        container: String? = WatchtowerCloud.containerID,
        hubID: String,
        macName: String,
        ownerUser: String?,
        nonce: String,
        iat: Int64,
        exp: Int64,
        dataShare: String? = nil,
        relayShare: String? = nil,
        hubSigningKey: String,
        hubAgreementKey: String,
        transport: TransportKind? = nil,
        transports: [String]? = nil,
        relayDeviceID: String? = nil,
        relayAuthPub: String? = nil
    ) {
        self.v = v
        self.container = container
        self.hubID = hubID
        self.macName = String(macName.prefix(Self.maxMacNameLength))
        self.ownerUser = ownerUser
        self.nonce = nonce
        self.iat = iat
        self.exp = exp
        self.dataShare = dataShare
        self.relayShare = relayShare
        self.hubSigningKey = hubSigningKey
        self.hubAgreementKey = hubAgreementKey
        self.transport = transport
        self.transports = transports
        self.relayDeviceID = relayDeviceID
        self.relayAuthPub = relayAuthPub
    }

    /// Throws `DecodingError.dataCorrupted` for a hub key that is not base64url of exactly 32 bytes, or is all zero (a small-order point).
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let signingKey = try values.decode(String.self, forKey: .hubSigningKey)
        let agreementKey = try values.decode(String.self, forKey: .hubAgreementKey)
        for (key, value) in [(CodingKeys.hubSigningKey, signingKey), (.hubAgreementKey, agreementKey)]
        where Self.decodeBase64URL(value).map({ $0.count != 32 || $0.allSatisfy { $0 == 0 } }) ?? true {
            throw DecodingError.dataCorruptedError(
                forKey: key, in: values, debugDescription: "hub key is not 32 non-zero bytes of base64url")
        }
        let version = try values.decode(Int.self, forKey: .v)
        // v3 requires the iCloud keys; v4 makes them optional (a headless host has neither).
        func cloudKey(_ key: CodingKeys) throws -> String? {
            version < 4 ? try values.decode(String.self, forKey: key) : try values.decodeIfPresent(String.self, forKey: key)
        }
        self.init(
            v: version,
            container: try cloudKey(.container),
            hubID: try values.decode(String.self, forKey: .hubID),
            macName: try values.decode(String.self, forKey: .macName),
            ownerUser: try cloudKey(.ownerUser),
            nonce: try values.decode(String.self, forKey: .nonce),
            iat: try values.decode(Int64.self, forKey: .iat),
            exp: try values.decode(Int64.self, forKey: .exp),
            dataShare: try values.decodeIfPresent(String.self, forKey: .dataShare),
            relayShare: try values.decodeIfPresent(String.self, forKey: .relayShare),
            hubSigningKey: signingKey,
            hubAgreementKey: agreementKey,
            transport: try values.decodeIfPresent(String.self, forKey: .transport).flatMap(TransportKind.init(rawValue:)),
            transports: try values.decodeIfPresent([String].self, forKey: .transports),
            relayDeviceID: try values.decodeIfPresent(String.self, forKey: .relayDeviceID),
            relayAuthPub: try values.decodeIfPresent(String.self, forKey: .relayAuthPub)
        )
    }

    /// Whether `authPub` is base64url of 32 non-zero bytes and `deviceID` is `RelayIDs.deviceID` of it.
    static func relayIdentityIsCoherent(deviceID: String, authPub: String) -> Bool {
        guard let key = decodeBase64URL(authPub), key.count == 32, !key.allSatisfy({ $0 == 0 }) else { return false }
        return RelayIDs.deviceID(publicKey: key) == deviceID
    }

    /// A fresh code issued `now`: new nonce, `exp = iat + lifetime`.
    public static func issue(
        hubID: String,
        macName: String,
        ownerUser: String,
        dataShare: String?,
        relayShare: String?,
        hubSigningKey: String,
        hubAgreementKey: String,
        now: Date
    ) -> Self {
        let iat = Int64(now.timeIntervalSince1970)
        return Self(
            hubID: hubID,
            macName: macName,
            ownerUser: ownerUser,
            nonce: makeNonce(),
            iat: iat,
            exp: iat + lifetime,
            dataShare: dataShare,
            relayShare: relayShare,
            hubSigningKey: hubSigningKey,
            hubAgreementKey: hubAgreementKey
        )
    }

    /// 32 random bytes as 43 base64url characters.
    /// `SystemRandomNumberGenerator` is cryptographically secure on Apple
    /// platforms.
    public static func makeNonce() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return encodeBase64URL(Data(bytes))
    }

    // MARK: - URL

    /// `watchtower://link?d=<base64url(JSON)>`.
    public func url() -> URL {
        let json: Data
        do {
            json = try Self.makeEncoder().encode(self)
        } catch {
            preconditionFailure("LinkPayload encodes only strings and integers: \(error)")
        }
        let string = "\(Self.scheme)://\(Self.host)?\(Self.dataParameter)=\(Self.encodeBase64URL(json))"
        guard let url = URL(string: string) else {
            preconditionFailure("base64url is URL-safe: \(string)")
        }
        return url
    }

    /// Decodes a scanned URL: v3 or v4. `v` is checked before any other key, so a
    /// newer code reads as `.newerVersion` and an older one as
    /// `.olderVersion` whatever its shape.
    public static func parse(_ url: URL) -> Result<Self, LinkPayloadError> {
        guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == host,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return .failure(.notALink) }
        guard let encoded = components.percentEncodedQueryItems?.first(where: { $0.name == dataParameter })?.value,
              let json = decodeBase64URL(encoded)
        else { return .failure(.badEncoding) }

        let decoder = JSONDecoder()
        guard let probe = try? decoder.decode(VersionProbe.self, from: json) else {
            return .failure(.badEncoding)
        }
        guard let version = probe.v else { return .failure(.missingField(CodingKeys.v.stringValue)) }
        if version > newestReadable { return .failure(.newerVersion) }
        if version < currentVersion { return .failure(.olderVersion) }

        let payload: Self
        do {
            payload = try decoder.decode(Self.self, from: json)
        } catch DecodingError.keyNotFound(let key, _) {
            return .failure(.missingField(key.stringValue))
        } catch DecodingError.valueNotFound(_, let context) {
            return .failure(.missingField(context.codingPath.last?.stringValue ?? ""))
        } catch {
            return .failure(.badEncoding)
        }
        if let container = payload.container, container != WatchtowerCloud.containerID {
            return .failure(.wrongContainer)
        }
        // Half a relay identity, or a pair that does not match: the phone would vouch for or address the wrong device.
        if payload.relayDeviceID != nil || payload.relayAuthPub != nil, !payload.offersRelay {
            return .failure(.badRelayIdentity)
        }
        return .success(payload)
    }

    // MARK: - Wire helpers

    /// Sorted keys, unescaped slashes (share URLs stay short).
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    /// base64url without padding (RFC 4648 §5); see `WireBytes.base64URL`.
    static func encodeBase64URL(_ data: Data) -> String {
        WireBytes.base64URL(data)
    }

    /// Canonical unpadded base64url only; see `WireBytes.fromBase64URL`.
    static func decodeBase64URL(_ string: String) -> Data? {
        WireBytes.fromBase64URL(string)
    }

    private struct VersionProbe: Decodable {
        let v: Int?
    }
}
