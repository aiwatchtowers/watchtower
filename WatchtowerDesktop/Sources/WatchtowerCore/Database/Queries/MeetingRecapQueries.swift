import Foundation
import GRDB

package enum MeetingRecapQueries {
    package static func fetch(_ db: Database, eventID: String) throws -> MeetingRecap? {
        try MeetingRecap
            .filter(Column("event_id") == eventID)
            .fetchOne(db)
    }
}
