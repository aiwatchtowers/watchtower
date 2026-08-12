import Foundation
import GRDB
import WatchtowerCore

enum MeetingRecapQueries {
    static func fetch(_ db: Database, eventID: String) throws -> MeetingRecap? {
        try MeetingRecap
            .filter(Column("event_id") == eventID)
            .fetchOne(db)
    }
}
