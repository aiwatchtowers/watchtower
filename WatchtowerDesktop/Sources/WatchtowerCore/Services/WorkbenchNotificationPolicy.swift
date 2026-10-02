import Foundation

package enum WorkbenchNoticeKind: String, Codable, Sendable {
    case agentAsks
    case documentReady
    case commentsAnswered
    case targetDone
}

package struct WorkbenchNotice: Equatable, Sendable {
    package let kind: WorkbenchNoticeKind
    package let projectID: Int64
    package let title: String
    package let body: String
    package let route: WorkbenchRoute
    /// Stable per event, so a re-post replaces instead of stacking.
    package let identifier: String
}

/// Which project events become owner notifications (spec §6.5). Pure: the
/// center feeds it the previous and current snapshot of each project; no
/// clock, no I/O.
package enum WorkbenchNotificationPolicy {
    package static let coalesceThreshold = 3

    package struct Question: Codable, Equatable, Sendable {
        package let id: Int64
        package let targetID: Int64
        package let targetTitle: String
        package let body: String

        package init(id: Int64, targetID: Int64, targetTitle: String, body: String) {
            self.id = id
            self.targetID = targetID
            self.targetTitle = targetTitle
            self.body = body
        }
    }

    package struct DocumentState: Codable, Equatable, Sendable {
        package let title: String
        package let updatedAt: String
        package let openOwnerComments: Int
        /// Not attached by the agent (`origin` import or owner): never "ready
        /// for review". The name predates owner attaches; kept for persisted snapshots.
        package let imported: Bool
        /// The agent put its target `in_review` (`WorkbenchDocumentListItem.awaitingReview`,
        /// minus a review the owner started themselves).
        package let awaitingReview: Bool
        /// False for a snapshot persisted before `awaitingReview` existed: its
        /// review state is unknown, so no "entered review" edge is read from it.
        /// Not encoded — every snapshot written now knows.
        package let reviewKnown: Bool

        package init(
            title: String,
            updatedAt: String,
            openOwnerComments: Int,
            imported: Bool = false,
            awaitingReview: Bool = false,
            reviewKnown: Bool = true
        ) {
            self.title = title
            self.updatedAt = updatedAt
            self.openOwnerComments = openOwnerComments
            self.imported = imported
            self.awaitingReview = awaitingReview
            self.reviewKnown = reviewKnown
        }

        private enum CodingKeys: String, CodingKey {
            case title, updatedAt, openOwnerComments, imported, awaitingReview
        }

        package init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            title = try c.decode(String.self, forKey: .title)
            updatedAt = try c.decode(String.self, forKey: .updatedAt)
            openOwnerComments = try c.decode(Int.self, forKey: .openOwnerComments)
            // A snapshot persisted before the key existed held no imports.
            imported = try c.decodeIfPresent(Bool.self, forKey: .imported) ?? false
            let review = try c.decodeIfPresent(Bool.self, forKey: .awaitingReview)
            awaitingReview = review ?? false
            reviewKnown = review != nil
        }
    }

    package struct TargetState: Codable, Equatable, Sendable {
        package let title: String
        package let status: String

        package init(title: String, status: String) {
            self.title = title
            self.status = status
        }
    }

    /// One project's state at a poll. `questions` holds only the agent root
    /// comments past the previous watermark; `ownerTouched` what the owner
    /// changed since the previous poll. Both are transient (`persisted`).
    package struct Snapshot: Codable, Equatable, Sendable {
        package var projectID: Int64
        package var projectName: String
        package var lastAgentCommentID: Int64
        package var questions: [Question]
        package var documents: [Int64: DocumentState]
        package var targets: [Int64: TargetState]
        package var ownerTouched: Set<WorkbenchSubject>

        package init(
            projectID: Int64,
            projectName: String,
            lastAgentCommentID: Int64,
            questions: [Question],
            documents: [Int64: DocumentState],
            targets: [Int64: TargetState],
            ownerTouched: Set<WorkbenchSubject>
        ) {
            self.projectID = projectID
            self.projectName = projectName
            self.lastAgentCommentID = lastAgentCommentID
            self.questions = questions
            self.documents = documents
            self.targets = targets
            self.ownerTouched = ownerTouched
        }

        /// The baseline of a project just created in-app: everything after it counts.
        package static func empty(projectID: Int64, projectName: String) -> Self {
            Self(projectID: projectID, projectName: projectName, lastAgentCommentID: 0,
                 questions: [], documents: [:], targets: [:], ownerTouched: [])
        }

        package var persisted: Self {
            var copy = self
            copy.questions = []
            copy.ownerTouched = []
            return copy
        }
    }

    package static func decide(previous: Snapshot, current: Snapshot) -> [WorkbenchNotice] {
        [
            coalesce(questions(previous, current), kind: .agentAsks, in: current),
            coalesce(readyDocuments(previous, current), kind: .documentReady, in: current),
            coalesce(answeredDocuments(previous, current), kind: .commentsAnswered, in: current),
            coalesce(doneTargets(previous, current), kind: .targetDone, in: current)
        ].flatMap { $0 }
    }

    // MARK: - Events

    private static func questions(_ previous: Snapshot, _ current: Snapshot) -> [WorkbenchNotice] {
        current.questions.filter { $0.id > previous.lastAgentCommentID }.map { question in
            notice(.agentAsks, current,
                   title: "Agent asks on \(question.targetTitle)",
                   body: "\(current.projectName): \(question.body.prefix(200))",
                   route: WorkbenchRoute(projectID: current.projectID, pane: .board, subjectID: question.targetID),
                   key: "\(question.id)")
        }
    }

    /// A revised agent document, or one whose target the agent just put in
    /// review (#105) — one notice either way, keyed by the revision, so
    /// attaching and marking the review in one go never notifies twice. A
    /// revision of a document already in review is titled as awaiting review.
    private static func readyDocuments(_ previous: Snapshot, _ current: Snapshot) -> [WorkbenchNotice] {
        current.documents.sorted { $0.key < $1.key }.compactMap { id, doc in
            guard !doc.imported else { return nil }
            let before = previous.documents[id]
            let revised = before?.updatedAt != doc.updatedAt
            let awaiting = doc.awaitingReview
            // A previous state of unknown review is no edge: an upgrade must
            // not re-announce reviews that were already running.
            let enteredReview = awaiting && before.map { $0.reviewKnown && !$0.awaitingReview } ?? true
            guard revised || enteredReview else { return nil }
            return notice(.documentReady, current,
                          title: awaiting ? "\(doc.title) awaits your review" : "\(doc.title) ready for review",
                          body: current.projectName,
                          route: WorkbenchRoute(projectID: current.projectID, pane: .documents, subjectID: id),
                          key: "\(id)-\(doc.updatedAt)")
        }
    }

    private static func answeredDocuments(_ previous: Snapshot, _ current: Snapshot) -> [WorkbenchNotice] {
        current.documents.sorted { $0.key < $1.key }.compactMap { id, doc in
            guard let before = previous.documents[id], before.openOwnerComments > 0, doc.openOwnerComments == 0,
                  !current.ownerTouched.contains(.document(id)) else { return nil }
            return notice(.commentsAnswered, current,
                          title: "All comments on \(doc.title) answered", body: current.projectName,
                          route: WorkbenchRoute(projectID: current.projectID, pane: .documents, subjectID: id),
                          key: "\(id)-\(doc.updatedAt)")
        }
    }

    private static func doneTargets(_ previous: Snapshot, _ current: Snapshot) -> [WorkbenchNotice] {
        current.targets.sorted { $0.key < $1.key }.compactMap { id, target in
            guard target.status == "done", let before = previous.targets[id], before.status != "done",
                  !current.ownerTouched.contains(.target(id)) else { return nil }
            return notice(.targetDone, current,
                          title: "\(target.title) done", body: current.projectName,
                          route: WorkbenchRoute(projectID: current.projectID, pane: .board, subjectID: id),
                          key: "\(id)")
        }
    }

    // MARK: - Shaping

    private static func coalesce(_ notices: [WorkbenchNotice], kind: WorkbenchNoticeKind, in snapshot: Snapshot) -> [WorkbenchNotice] {
        guard notices.count >= coalesceThreshold else { return notices }
        let pane: WorkbenchPane = kind == .agentAsks || kind == .targetDone ? .board : .documents
        return [notice(kind, snapshot,
                       title: summaryTitle(kind, count: notices.count), body: snapshot.projectName,
                       route: WorkbenchRoute(projectID: snapshot.projectID, pane: pane),
                       key: "summary-" + notices.map(\.identifier).joined(separator: ",").hashValueString)]
    }

    private static func summaryTitle(_ kind: WorkbenchNoticeKind, count: Int) -> String {
        switch kind {
        case .agentAsks: "\(count) agent questions"
        case .documentReady: "\(count) documents ready for review"
        case .commentsAnswered: "All comments answered on \(count) documents"
        case .targetDone: "\(count) targets done"
        }
    }

    private static func notice(
        _ kind: WorkbenchNoticeKind, _ snapshot: Snapshot, title: String, body: String, route: WorkbenchRoute, key: String
    ) -> WorkbenchNotice {
        WorkbenchNotice(kind: kind, projectID: snapshot.projectID, title: title, body: body, route: route,
                        identifier: "project-\(snapshot.projectID)-\(kind.rawValue)-\(key)")
    }
}

private extension String {
    /// A short, stable (FNV-1a) digest — Swift's `hashValue` is seeded per
    /// process and would give every relaunch a new identifier.
    var hashValueString: String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}
