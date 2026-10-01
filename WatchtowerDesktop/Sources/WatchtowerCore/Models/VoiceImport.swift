import Foundation
import GRDB

/// One imported voice-print file from a colleague (`voice_imports`,
/// migration 00080). `fileSHA256` dedups a re-import; deleting the row
/// cascades to the samples it brought.
package struct VoiceImport: Codable, FetchableRecord, MutablePersistableRecord, Equatable, Identifiable, Sendable {
    package static let databaseTableName = "voice_imports"

    package var id: Int64?
    package var senderName: String
    package var senderEmail: String
    package var fileSHA256: String
    package var peopleCount: Int
    package var sampleCount: Int
    package var modelVersion: String
    package var importedAt: String

    package init(
        id: Int64? = nil,
        senderName: String,
        senderEmail: String = "",
        fileSHA256: String,
        peopleCount: Int,
        sampleCount: Int,
        modelVersion: String,
        importedAt: String = ""
    ) {
        self.id = id
        self.senderName = senderName
        self.senderEmail = senderEmail
        self.fileSHA256 = fileSHA256
        self.peopleCount = peopleCount
        self.sampleCount = sampleCount
        self.modelVersion = modelVersion
        self.importedAt = importedAt
    }

    package enum CodingKeys: String, CodingKey {
        case id
        case senderName = "sender_name"
        case senderEmail = "sender_email"
        case fileSHA256 = "file_sha256"
        case peopleCount = "people_count"
        case sampleCount = "sample_count"
        case modelVersion = "model_version"
        case importedAt = "imported_at"
    }

    /// An empty `importedAt` is left out of the INSERT so the column default stamps it.
    package func encode(to container: inout PersistenceContainer) throws {
        container[CodingKeys.id.rawValue] = id
        container[CodingKeys.senderName.rawValue] = senderName
        container[CodingKeys.senderEmail.rawValue] = senderEmail
        container[CodingKeys.fileSHA256.rawValue] = fileSHA256
        container[CodingKeys.peopleCount.rawValue] = peopleCount
        container[CodingKeys.sampleCount.rawValue] = sampleCount
        container[CodingKeys.modelVersion.rawValue] = modelVersion
        if !importedAt.isEmpty { container[CodingKeys.importedAt.rawValue] = importedAt }
    }

    package mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
