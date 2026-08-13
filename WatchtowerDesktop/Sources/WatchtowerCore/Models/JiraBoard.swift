import CryptoKit
import Foundation
import GRDB

package struct JiraBoard: Codable, FetchableRecord, TableRecord, Hashable {
    package static let databaseTableName = "jira_boards"
    /// Owning Atlassian site (`jira_accounts.id`, migration 00049). Raw board
    /// ids collide across sites, so this is half of the row's identity — and
    /// what per-board CLI calls pass as `--account`.
    package var accountID: Int64
    package let id: Int
    package var name: String
    package var projectKey: String
    package var boardType: String        // "scrum" | "kanban" | "simple"
    package var isSelected: Bool
    package var issueCount: Int
    package var syncedAt: String
    // Phase 0b — profile columns
    package var rawColumnsJSON: String
    package var rawConfigJSON: String
    package var llmProfileJSON: String
    package var workflowSummary: String
    package var userOverridesJSON: String
    package var configHash: String
    package var profileGeneratedAt: String

    /// Stable SwiftUI list identity: a bare board id is only unique within its
    /// site, so lists keyed on `id` alone would collide across accounts.
    package var rowID: String { "\(accountID):\(id)" }

    package enum CodingKeys: String, CodingKey {
        case id, name
        case accountID = "account_id"
        case projectKey = "project_key"
        case boardType = "board_type"
        case isSelected = "is_selected"
        case issueCount = "issue_count"
        case syncedAt = "synced_at"
        case rawColumnsJSON = "raw_columns_json"
        case rawConfigJSON = "raw_config_json"
        case llmProfileJSON = "llm_profile_json"
        case workflowSummary = "workflow_summary"
        case userOverridesJSON = "user_overrides_json"
        case configHash = "config_hash"
        case profileGeneratedAt = "profile_generated_at"
    }
}

// MARK: - Board Profile Display Models

package struct BoardProfileDisplay: Codable {
    package let workflowStages: [WorkflowStageDisplay]
    package let estimationApproach: EstimationApproachDisplay
    package let iterationInfo: IterationInfoDisplay
    package let workflowSummary: String
    package let staleThresholds: [String: Int]
    package let healthSignals: [String]
    package let customFields: [CustomFieldDisplay]

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workflowStages = (try? container.decode([WorkflowStageDisplay].self, forKey: .workflowStages)) ?? []
        estimationApproach = try container.decode(EstimationApproachDisplay.self, forKey: .estimationApproach)
        iterationInfo = try container.decode(IterationInfoDisplay.self, forKey: .iterationInfo)
        workflowSummary = (try? container.decode(String.self, forKey: .workflowSummary)) ?? ""
        staleThresholds = (try? container.decode([String: Int].self, forKey: .staleThresholds)) ?? [:]
        healthSignals = (try? container.decode([String].self, forKey: .healthSignals)) ?? []
        customFields = (try? container.decode([CustomFieldDisplay].self, forKey: .customFields)) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case workflowStages, estimationApproach, iterationInfo
        case workflowSummary, staleThresholds, healthSignals, customFields
    }
}

package struct CustomFieldDisplay: Codable, Identifiable {
    package var id: String { fieldId }
    package let fieldId: String
    package let name: String
    package let role: String
    package let type: String
}

package struct WorkflowStageDisplay: Codable, Identifiable {
    package var id: String { name }
    package let name: String
    package let originalStatuses: [String]
    package let phase: String   // "backlog"|"active_work"|"review"|"testing"|"done"|"other"
    package let isTerminal: Bool
    package let typicalDurationSignal: String
}

package struct EstimationApproachDisplay: Codable {
    package let type: String
    package let field: String?
}

package struct IterationInfoDisplay: Codable {
    package let hasIterations: Bool
    package let typicalLengthDays: Int
    package let avgThroughput: Int
}

// MARK: - Config Change Detection

extension JiraBoard {
    /// Whether the board's raw configuration has changed since the last analysis.
    /// Mirrors Go's `ComputeConfigHash` algorithm: canonical columns + estimation → SHA256.
    package var isConfigChanged: Bool {
        // No profile yet — not a "changed config" case.
        guard !configHash.isEmpty, !llmProfileJSON.isEmpty else {
            return false
        }
        let computed = Self.computeConfigHash(
            rawColumnsJSON: rawColumnsJSON,
            rawConfigJSON: rawConfigJSON
        )
        return !computed.isEmpty && computed != configHash
    }

    /// Compute SHA256 hash of board config, matching Go's ComputeConfigHash.
    /// Input: raw_columns_json = JSON array of {name, statuses: [{name, ...}]}
    ///        raw_config_json  = JSON object with {columns, estimation: {field_id}}
    package static func computeConfigHash(
        rawColumnsJSON: String,
        rawConfigJSON: String
    ) -> String {
        guard let colData = rawColumnsJSON.data(using: .utf8),
              let columns = try? JSONDecoder().decode(
                  [RawBoardColumn].self, from: colData
              ) else {
            return ""
        }

        var parts: [String] = []

        // Canonicalize columns — sort status names within each column.
        for col in columns {
            let sortedStatuses = col.statuses
                .map(\.name)
                .sorted()
                .joined(separator: ",")
            parts.append("\(col.name):\(sortedStatuses)")
        }

        // Add estimation field from config.
        if let cfgData = rawConfigJSON.data(using: .utf8),
           let config = try? JSONDecoder().decode(
               RawBoardConfig.self, from: cfgData
           ),
           let est = config.estimation {
            parts.append("est:\(est.fieldID)")
        }

        let data = parts.joined(separator: "|")
        let hash = SHA256.hash(data: Data(data.utf8))
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Raw config models for hash computation

private struct RawBoardColumn: Codable {
    package let name: String
    package let statuses: [RawBoardColumnStatus]
}

private struct RawBoardColumnStatus: Codable {
    package let name: String
}

private struct RawBoardConfig: Codable {
    package let estimation: RawEstimation?
}

private struct RawEstimation: Codable {
    package let fieldID: String

    package enum CodingKeys: String, CodingKey {
        case fieldID = "field_id"
    }
}
