import GRDB

package enum UserQueries {
    package static func fetchAll(_ db: Database, activeOnly: Bool = true) throws -> [User] {
        if activeOnly {
            return try User.fetchAll(db, sql: "SELECT * FROM users WHERE is_deleted = 0 ORDER BY display_name ASC")
        }
        return try User.fetchAll(db, sql: "SELECT * FROM users ORDER BY display_name ASC")
    }

    package static func fetchByID(_ db: Database, id: String) throws -> User? {
        try User.fetchOne(db, sql: "SELECT * FROM users WHERE id = ?", arguments: [id])
    }

    package static func fetchByName(_ db: Database, name: String) throws -> User? {
        try User.fetchOne(db, sql: "SELECT * FROM users WHERE name = ?", arguments: [name])
    }

    package static func fetchDisplayName(_ db: Database, forID id: String) throws -> String {
        let user = try fetchByID(db, id: id)
        return user?.bestName ?? id
    }
}
