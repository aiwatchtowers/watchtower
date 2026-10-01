import CommonCrypto
import CryptoKit
import Foundation

/// The `.wtvoices` file contents (design spec §5): embeddings only — never
/// audio, transcript text, meeting titles, dates or recording ids. Encoded as
/// JSON, then sealed whole by `VoiceExportCodec` — nothing here is ever
/// written to disk unencrypted.
package struct VoiceExportPayload: Codable, Equatable, Sendable {
    /// File format, independent of `modelVersion`. Bumped only if the file
    /// layout itself changes.
    package let formatVersion: Int
    /// `VoiceRegistryPolicy.embeddingModelVersion` at export time — the
    /// recipient rejects a file from a different embedding model rather than
    /// mixing incompatible vectors (design spec §5, "model-version mismatch").
    package let modelVersion: String
    package let sender: Sender
    package let people: [Person]

    package struct Sender: Codable, Equatable, Sendable {
        package let name: String
        package let email: String

        package init(name: String, email: String) {
            self.name = name
            self.email = email
        }
    }

    package struct Person: Codable, Equatable, Sendable {
        package let personKey: String
        package let displayName: String
        package let samples: [Sample]

        package init(personKey: String, displayName: String, samples: [Sample]) {
            self.personKey = personKey
            self.displayName = displayName
            self.samples = samples
        }

        package enum CodingKeys: String, CodingKey {
            case personKey = "person_key"
            case displayName = "display_name"
            case samples
        }
    }

    package struct Sample: Codable, Equatable, Sendable {
        package let embedding: [Float]
        package let channel: VoiceChannel
        package let speechSec: Double

        package init(embedding: [Float], channel: VoiceChannel, speechSec: Double) {
            self.embedding = embedding
            self.channel = channel
            self.speechSec = speechSec
        }

        package enum CodingKeys: String, CodingKey {
            case embedding, channel
            case speechSec = "speech_sec"
        }
    }

    package init(formatVersion: Int, modelVersion: String, sender: Sender, people: [Person]) {
        self.formatVersion = formatVersion
        self.modelVersion = modelVersion
        self.sender = sender
        self.people = people
    }

    package enum CodingKeys: String, CodingKey {
        case formatVersion = "format_version"
        case modelVersion = "model_version"
        case sender, people
    }
}

/// Encrypts/decrypts a `.wtvoices` file: AES-GCM whole-file encryption with a
/// PBKDF2-derived key (design spec §5, owner-chosen baseline 2026-09-28) — no
/// unencrypted export path exists. Layout: `magic ‖ salt(16) ‖
/// AES.GCM.SealedBox.combined` (the combined form is nonce ‖ ciphertext ‖ tag,
/// so GCM's own authentication tag is what turns a flipped byte or the wrong
/// password into `wrongPasswordOrCorrupt` — there is no separate checksum).
package enum VoiceExportCodec {
    package static let magic = Data("WTVOICES1".utf8)
    static let iterations: UInt32 = 200_000
    private static let saltLength = 16
    private static let keyLength = 32

    package enum CodecError: Error, Equatable {
        case badMagic
        case wrongPasswordOrCorrupt
        case unsupportedFormat
        case emptyPassword
    }

    package static func seal(_ payload: VoiceExportPayload, password: String) throws -> Data {
        guard !password.isEmpty else { throw CodecError.emptyPassword }
        var salt = Data(count: saltLength)
        let status = salt.withUnsafeMutableBytes { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, saltLength, base)
        }
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed with status \(status)")
        let key = try deriveKey(password: password, salt: salt)
        let body = try JSONEncoder().encode(payload)
        guard let combined = try AES.GCM.seal(body, using: key).combined else {
            throw CodecError.wrongPasswordOrCorrupt
        }
        return magic + salt + combined
    }

    package static func open(_ data: Data, password: String) throws -> VoiceExportPayload {
        guard !password.isEmpty else { throw CodecError.emptyPassword }
        guard data.count > magic.count + saltLength, data.prefix(magic.count) == magic else {
            throw CodecError.badMagic
        }
        let salt = data.subdata(in: magic.count..<(magic.count + saltLength))
        let key = try deriveKey(password: password, salt: salt)
        do {
            let box = try AES.GCM.SealedBox(combined: data.suffix(from: magic.count + saltLength))
            let opened = try AES.GCM.open(box, using: key)
            let payload = try JSONDecoder().decode(VoiceExportPayload.self, from: opened)
            guard payload.formatVersion == 1 else { throw CodecError.unsupportedFormat }
            return payload
        } catch let error as CodecError {
            throw error
        } catch {
            // A wrong password, or ANY corruption (GCM auth-tag failure,
            // truncated file, malformed JSON) surfaces identically — no
            // oracle that would let an attacker distinguish "wrong password"
            // from "tampered ciphertext".
            throw CodecError.wrongPasswordOrCorrupt
        }
    }

    private static func deriveKey(password: String, salt: Data) throws -> SymmetricKey {
        var key = Data(count: keyLength)
        let pw = Array(password.utf8)
        let rc = key.withUnsafeMutableBytes { keyBytes in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    pw.map { Int8(bitPattern: $0) }, pw.count,
                    saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations,
                    keyBytes.bindMemory(to: UInt8.self).baseAddress, keyLength)
            }
        }
        guard rc == kCCSuccess else { throw CodecError.wrongPasswordOrCorrupt }
        return SymmetricKey(data: key)
    }
}
