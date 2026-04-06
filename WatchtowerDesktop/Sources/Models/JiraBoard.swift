import GRDB

struct JiraBoard: Codable, FetchableRecord, TableRecord {
    static let databaseTableName = "jira_boards"
    let id: Int
    var name: String
    var projectKey: String
    var boardType: String        // "scrum" | "kanban" | "simple"
    var isSelected: Bool
    var issueCount: Int
    var syncedAt: String
    // Phase 0b — profile columns
    var rawColumnsJSON: String
    var rawConfigJSON: String
    var llmProfileJSON: String
    var workflowSummary: String
    var userOverridesJSON: String
    var configHash: String
    var profileGeneratedAt: String

    enum CodingKeys: String, CodingKey {
        case id, name
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

struct BoardProfileDisplay: Codable {
    let workflowStages: [WorkflowStageDisplay]
    let estimationApproach: EstimationApproachDisplay
    let iterationInfo: IterationInfoDisplay
    let workflowSummary: String
    let staleThresholds: [String: Int]
    let healthSignals: [String]
}

struct WorkflowStageDisplay: Codable, Identifiable {
    var id: String { name }
    let name: String
    let originalStatuses: [String]
    let phase: String   // "backlog"|"active_work"|"review"|"testing"|"done"|"other"
    let isTerminal: Bool
    let typicalDurationSignal: String
}

struct EstimationApproachDisplay: Codable {
    let type: String
    let field: String?
}

struct IterationInfoDisplay: Codable {
    let hasIterations: Bool
    let typicalLengthDays: Int
    let avgThroughput: Int
}
