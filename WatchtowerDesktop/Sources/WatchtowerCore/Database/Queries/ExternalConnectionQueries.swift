import GRDB

package enum ExternalConnectionQueries {
    package static func fetchAll(_ db: Database) throws -> [ExternalConnection] {
        try ExternalConnection.fetchAll(
            db,
            sql: "SELECT * FROM external_connections ORDER BY id ASC"
        )
    }
}
