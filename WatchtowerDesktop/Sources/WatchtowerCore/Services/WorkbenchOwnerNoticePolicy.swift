import Foundation

/// Whether a target change is the owner's own and so never announced. A phone
/// board edit reaches the database through the Go hub, which writes it as
/// `db.ActorOwner` and never calls the Desktop's in-process `onOwnerWrite`;
/// the newest `target_status_history` row's actor tells it apart from an
/// agent's or a rollup's change. `onOwnerWrite` stays for the Desktop's own
/// edits (same effect, one poll earlier).
package enum WorkbenchOwnerNoticePolicy {
    /// Go `db.ActorOwner` (internal/db/target_status_history.go), pinned by
    /// `internal/db/testdata/actors.json`.
    package static let ownerActor = "owner"

    /// `newestActor` = the actor of the target's newest history row; nil (no
    /// row) leaves the decision to the other rules.
    package static func shouldAnnounce(newestActor: String?) -> Bool {
        newestActor != ownerActor
    }

    /// The targets whose newest history row the owner wrote, as the subjects
    /// `WorkbenchNotificationPolicy.Snapshot.ownerTouched` keeps quiet.
    package static func ownerWritten(newestActors: [Int64: String]) -> Set<WorkbenchSubject> {
        Set(newestActors.compactMap { id, actor in shouldAnnounce(newestActor: actor) ? nil : .target(id) })
    }
}
