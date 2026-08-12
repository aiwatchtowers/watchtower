import GRDB
import Foundation

package struct PeriodSummary: FetchableRecord, Decodable, Identifiable, Equatable {
    package let id: Int
    package let periodFrom: Double
    package let periodTo: Double
    package let summary: String
    package let attention: String
    package let model: String
    package let inputTokens: Int?
    package let outputTokens: Int?
    package let costUSD: Double?
    package let createdAt: String

    package enum CodingKeys: String, CodingKey {
        case id, summary, model, attention
        case periodFrom = "period_from"
        case periodTo = "period_to"
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case costUSD = "cost_usd"
        case createdAt = "created_at"
    }

    private static let decoder = JSONDecoder()

    package var parsedAttention: [String] {
        guard let data = attention.data(using: .utf8) else { return [] }
        return (try? Self.decoder.decode([String].self, from: data)) ?? []
    }

    package var periodFromDate: Date {
        Date(timeIntervalSince1970: periodFrom)
    }

    package var periodToDate: Date {
        Date(timeIntervalSince1970: periodTo)
    }
}
