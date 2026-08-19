import Foundation
import GRDB

package struct PipelineRun: Decodable, FetchableRecord, Identifiable {
    package let id: Int64
    package let pipeline: String
    package let source: String
    package let model: String
    package let status: String
    package let errorMsg: String
    package let itemsFound: Int
    package let inputTokens: Int
    package let outputTokens: Int
    package let costUsd: Double
    package let totalApiTokens: Int
    package let periodFrom: Double?
    package let periodTo: Double?
    package let startedAt: String
    package let finishedAt: String?
    package let durationSeconds: Double
    package let stepCount: Int

    /// Number of actual AI API calls (steps if available, otherwise 1 per run).
    package var aiCallCount: Int { max(1, stepCount) }

    package enum CodingKeys: String, CodingKey {
        case id, pipeline, source, model, status
        case errorMsg = "error_msg"
        case itemsFound = "items_found"
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case costUsd = "cost_usd"
        case totalApiTokens = "total_api_tokens"
        case periodFrom = "period_from"
        case periodTo = "period_to"
        case startedAt = "started_at"
        case finishedAt = "finished_at"
        case durationSeconds = "duration_seconds"
        case stepCount = "step_count"
    }

    package var pipelineTitle: String {
        switch pipeline {
        case "slack-sync": return "Slack Sync"
        case "digests": return "Digests"
        case "tracks": return "Tracks"
        case "people": return "People Cards"
        default: return pipeline.capitalized
        }
    }

    package var pipelineIcon: String {
        switch pipeline {
        case "slack-sync": return "arrow.triangle.2.circlepath"
        case "digests": return "doc.text.magnifyingglass"
        case "tracks": return "checklist"
        case "people": return "person.2.circle"
        default: return "gearshape"
        }
    }

    package var startedDate: Date? {
        ISO8601DateFormatter().date(from: startedAt)
    }
}

package struct PipelineStepRecord: Decodable, FetchableRecord, Identifiable {
    package let id: Int64
    package let runId: Int64
    package let step: Int
    package let total: Int
    package let status: String
    package let channelId: String
    package let channelName: String
    package let inputTokens: Int
    package let outputTokens: Int
    package let costUsd: Double
    package let totalApiTokens: Int
    package let messageCount: Int
    package let periodFrom: Double?
    package let periodTo: Double?
    package let durationSeconds: Double
    package let createdAt: String

    package enum CodingKeys: String, CodingKey {
        case id
        case runId = "run_id"
        case step, total, status
        case channelId = "channel_id"
        case channelName = "channel_name"
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case costUsd = "cost_usd"
        case totalApiTokens = "total_api_tokens"
        case messageCount = "message_count"
        case periodFrom = "period_from"
        case periodTo = "period_to"
        case durationSeconds = "duration_seconds"
        case createdAt = "created_at"
    }
}
