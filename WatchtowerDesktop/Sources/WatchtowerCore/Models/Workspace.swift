import GRDB

package struct Workspace: FetchableRecord, Decodable, Identifiable, Equatable {
    package let id: String
    package let name: String
    package let domain: String
    package let syncedAt: String?
    // search_last_date / current_user_id moved to slack_accounts (migration
    // 00048); read the owner identity via slack_accounts (account #1).

    package enum CodingKeys: String, CodingKey {
        case id, name, domain
        case syncedAt = "synced_at"
    }
}
