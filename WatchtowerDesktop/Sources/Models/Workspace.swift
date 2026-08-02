import GRDB

struct Workspace: FetchableRecord, Decodable, Identifiable, Equatable {
    let id: String
    let name: String
    let domain: String
    let syncedAt: String?
    // search_last_date / current_user_id moved to slack_accounts (migration
    // 00048); read the owner identity via slack_accounts (account #1).

    enum CodingKeys: String, CodingKey {
        case id, name, domain
        case syncedAt = "synced_at"
    }
}
