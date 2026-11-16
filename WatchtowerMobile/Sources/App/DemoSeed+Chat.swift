import Foundation
import WatchtowerKit
import WatchtowerSync

// MARK: - AI chat (iPhone chat spec §6, mockups 1a–1j)

extension DemoSeed {
    /// The demo Mac's chats: the `chat_list` record the primary hub publishes (mockup 1a), and the lists and search
    /// the screenshot tour shows for the other states. Neutral samples only.
    enum Chat {
        static let projectID: Int64 = 7
        static let projectName = "acme-platform"
        static let searchQuery = "billing"

        /// The heartbeat's capabilities on a hub that hosts chat.
        static let capabilities = HeartbeatCapabilities(chat: "on")

        /// Older than the 7-day window: folded under "▸ 23 older".
        static let olderTitles = [
            "Vendor contracts", "Hiring plan for Q4", "Incident review: search outage", "Pricing page copy",
            "Onboarding checklist", "Release notes 1.3", "Board deck outline", "Support macros", "Data retention policy",
            "Offsite agenda", "API deprecation notice", "Customer interview notes", "Security questionnaire",
            "Team charter", "Roadmap themes", "Sprint retro", "Partner email", "Budget follow-up", "Analytics events",
            "Mobile beta feedback", "Docs migration", "Weekly update", "Holiday coverage"
        ]

        /// The list of mockup 1a: a pinned chat waiting for an approval, one answering, one unread in a project,
        /// two read, and the older ones.
        static func listPayload(now: Date) -> [String: Any] {
            let ago: (TimeInterval) -> Int = { JSON.stamp(now.addingTimeInterval(-$0)) }
            let project: [String: Any] = ["id": projectID, "name": projectName]
            var conversations: [[String: Any]] = [
                ["id": 1, "title": "Release checklist", "pinned": true, "updated_at": ago(120), "state": "waiting",
                 "last_line": "Ready to post the checklist."],
                ["id": 2, "title": "Q3 roadmap summary", "updated_at": ago(10), "state": "answering", "lease_owner": "hub"],
                ["id": 3, "title": "Who owns the billing API?", "updated_at": ago(14 * 60), "state": "unread", "project": project,
                 "last_line": "Colleague B leads it since March."],
                ["id": 4, "title": "Draft reply to the vendor", "updated_at": ago(3_600), "state": "read", "last_line": "Email draft ready"],
                ["id": 5, "title": "Meeting prep for Thursday", "updated_at": ago(4 * 86_400), "state": "read",
                 "last_line": "You: and the open risks?"]
            ]
            for (offset, title) in olderTitles.enumerated() {
                conversations.append([
                    "id": 100 + offset, "title": title, "updated_at": ago(Double(9 + offset * 3) * 86_400), "state": "read",
                    "last_line": "Done"
                ])
            }
            return [
                "conversations": conversations,
                "projects": [project],
                "models": [["provider": "claude", "model": "", "display_name": "Claude", "images": true, "pdf": true]]
            ]
        }

        static func records(now: Date) throws -> [CloudRecord] {
            let payload = try JSONSerialization.data(withJSONObject: listPayload(now: now), options: [.sortedKeys])
            return [CloudRecordFactory.record(for: SliceRecord(kind: .chatList, id: ChatList.recordID, modifiedAt: now, payload: payload))]
        }

        /// Mockup 1a's list as the phone decodes it.
        static func list(now: Date) throws -> ChatList {
            try ChatList.decode(payload: try JSONSerialization.data(withJSONObject: listPayload(now: now)))
        }

        /// The last list the phone holds while the Mac sleeps (mockup 1d).
        static func asleepList(now: Date) -> ChatList {
            ChatList(conversations: [
                .init(id: 2, title: "Q3 roadmap summary", updatedAt: now.addingTimeInterval(-3 * 3_600), state: .read, lastLine: "Done"),
                .init(
                    id: 3, title: "Who owns the billing API?", updatedAt: now.addingTimeInterval(-5 * 3_600),
                    project: .init(id: projectID, name: projectName), state: .read
                )
            ])
        }

        /// The Mac's hits for "billing" (mockup 1i), the matches between the hub's markers.
        static func search(now: Date, calendar: Calendar = .current) -> ChatSearch {
            let mark = { (text: String) in ChatSearch.markStart + text + ChatSearch.markEnd }
            let tuesday = calendar.nextDate(
                after: now.addingTimeInterval(-6 * 86_400), matching: DateComponents(weekday: 3), matchingPolicy: .nextTime
            ) ?? now.addingTimeInterval(-2 * 86_400)
            return ChatSearch(query: searchQuery, hits: [
                .init(conversationID: 3, title: "Who owns the billing API?", snippet: "Who owns the \(mark("billing")) API?", date: now),
                .init(
                    conversationID: 2, title: "Q3 roadmap summary", snippet: "…\(mark("Billing")) v2 is on track for August…",
                    messageID: 21, date: tuesday
                ),
                .init(
                    conversationID: 100, title: "Vendor contracts", snippet: "…the \(mark("billing")) clause renews in May…",
                    messageID: 1_004, date: now.addingTimeInterval(-44 * 86_400)
                )
            ])
        }
    }
}
