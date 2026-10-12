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
}

/// The QR link code a Mac shows and a phone scans (mobile POC spec §2.3):
/// `watchtower://link?d=<base64url(JSON)>`, no padding, sorted keys.
///
/// Wire: snake_case keys, Unix-second `iat`/`exp`, unescaped slashes; a nil
/// share URL is an absent key. Frozen by LinkPayloadTests. This type only
/// encodes and decodes: the expiry check (with the phone's clock-skew grace)
/// and the single-use nonce check belong to the link flow and the hub.
public struct LinkPayload: Codable, Equatable, Sendable {
    /// 3 since the E2E build (mobile E2E spec §2.3): the code carries the hub's public keys.
    /// 2 was the multi-hub build (spec §3.4): shares of the hub's own `DataZone-<hub_id>`/`RelayZone-<hub_id>`.
    public static let currentVersion = 3
    /// `exp = iat + lifetime`, in seconds.
    public static let lifetime: Int64 = 600
    /// Cap on `macName`, in grapheme clusters.
    public static let maxMacNameLength = 60
    static let scheme = "watchtower"
    static let host = "link"
    static let dataParameter = "d"

    public let v: Int
    public let container: String
    /// The hub's UUID (spec §4.1).
    public let hubID: String
    /// At most `maxMacNameLength` grapheme clusters, clipped on init and decode.
    public let macName: String
    /// The Mac's `CKContainer.userRecordID().recordName`.
    public let ownerUser: String
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
    }

    public init(
        v: Int = Self.currentVersion,
        container: String = WatchtowerCloud.containerID,
        hubID: String,
        macName: String,
        ownerUser: String,
        nonce: String,
        iat: Int64,
        exp: Int64,
        dataShare: String? = nil,
        relayShare: String? = nil,
        hubSigningKey: String,
        hubAgreementKey: String
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
        self.init(
            v: try values.decode(Int.self, forKey: .v),
            container: try values.decode(String.self, forKey: .container),
            hubID: try values.decode(String.self, forKey: .hubID),
            macName: try values.decode(String.self, forKey: .macName),
            ownerUser: try values.decode(String.self, forKey: .ownerUser),
            nonce: try values.decode(String.self, forKey: .nonce),
            iat: try values.decode(Int64.self, forKey: .iat),
            exp: try values.decode(Int64.self, forKey: .exp),
            dataShare: try values.decodeIfPresent(String.self, forKey: .dataShare),
            relayShare: try values.decodeIfPresent(String.self, forKey: .relayShare),
            hubSigningKey: signingKey,
            hubAgreementKey: agreementKey
        )
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

    /// Decodes a scanned URL. `v` is checked before any other key, so a
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
        if version > currentVersion { return .failure(.newerVersion) }
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
        guard payload.container == WatchtowerCloud.containerID else { return .failure(.wrongContainer) }
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
