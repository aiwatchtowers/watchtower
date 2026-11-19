import ChatWire
import Foundation
import WatchtowerChatText
import WatchtowerKit

// MARK: - AI chat conversations (iPhone chat spec §6.2, mockups 2a–2i, 3a–3c)

extension DemoSeed.Chat {
    /// The conversations the screenshot tour opens, one feed per mockup. Neutral samples only.
    enum Feeds {
        static let roadmap: Int64 = 2
        static let release: Int64 = 1
        static let billing: Int64 = 3
        static let vendor: Int64 = 4
        static let meeting: Int64 = 5

        static let roadmapAnswer = """
            #### Q3 roadmap
            - Billing v2 is on track for August.
            - Search reindex slipped one sprint; owner: colleague A.
            - Mobile chat waits on the relay rollout.

            Two items are still open: the SSO deadline and the `export` API.
            """

        private static func message(
            _ id: Int64,
            _ role: String,
            _ text: String,
            now: Date,
            status: String = "complete",
            siblings: ChatFeed.Siblings = .init(),
            attachments: [ChatFeed.Attachment] = [],
            steps: [ChatFeed.Step] = [],
            error: (code: String, message: String)? = nil
        ) -> ChatFeed.Message {
            ChatFeed.Message(
                id: id, role: role, text: text, status: status, errorCode: error?.code, errorMessage: error?.message,
                createdAt: now.addingTimeInterval(Double(id - 100) * 30), siblings: siblings, attachments: attachments, steps: steps
            )
        }

        private static func conversation(_ id: Int64, _ title: String, lease: ChatFeed.Lease? = nil) -> ChatFeed.Conversation {
            ChatFeed.Conversation(id: id, title: title, actualProvider: "claude", lease: lease)
        }

        /// The sources of the roadmap answer (mockup 3c): Slack threads and Jira issues.
        static let roadmapSources: [ChatFeed.Source] = [
            .init(kind: "slack", title: "#roadmap — thread from Tuesday", url: "https://acme.slack.com/archives/C1/p1", ref: "slack:1",
                  group: "#roadmap", snippet: "billing v2 is on track…"),
            .init(kind: "slack", title: "#roadmap — search reindex", ref: "slack:2", group: "#roadmap", snippet: "slipping one sprint"),
            .init(kind: "slack", title: "#mobile — relay rollout", ref: "slack:3", group: "#mobile"),
            .init(kind: "jira", title: "PROJ-881 SSO deadline", url: "https://acme.example.com/browse/PROJ-881", ref: "jira:PROJ-881",
                  group: "PROJ", snippet: "In progress"),
            .init(kind: "jira", title: "PROJ-902 export API", ref: "jira:PROJ-902", group: "PROJ"),
            .init(kind: "jira", title: "PROJ-640 Billing v2", ref: "jira:PROJ-640", group: "PROJ")
        ]

        private static let roadmapSteps: [ChatFeed.Step] = [
            .init(name: "list_messages", outcome: .succeeded, summary: "12 messages", sources: Array(roadmapSources.prefix(3))),
            .init(name: "list_jira_issues", outcome: .succeeded, summary: "8 issues", sources: Array(roadmapSources.suffix(3))),
            .init(name: "get_jira_issue", outcome: .succeeded, summary: "PROJ-881")
        ]

        /// Mockup 2a: a finished turn, three steps, six sources, the second of two answers.
        static func done(now: Date) -> ChatFeed {
            ChatFeed(conversation: conversation(roadmap, "Q3 roadmap summary"), messages: [
                message(101, "user", "Summarise the Q3 roadmap threads and what is still open", now: now),
                message(103, "assistant", roadmapAnswer, now: now, siblings: .init(index: 2, count: 2, ids: [102, 103]), steps: roadmapSteps)
            ])
        }

        /// Mockup 2b: the hub answers now; a photo and a PDF went with the question.
        static func busy(now: Date) -> ChatFeed {
            ChatFeed(conversation: conversation(roadmap, "Q3 roadmap summary", lease: .init(owner: "hub", turnID: "turn-2")), messages: [
                message(101, "user", "What changed in this plan vs last week?", now: now, attachments: [
                    .init(id: 1, name: "whiteboard.jpg", mime: "image/jpeg", size: 812_000),
                    .init(id: 2, name: "plan.pdf", mime: "application/pdf", size: 120_000)
                ]),
                message(102, "assistant", "The plan moves the SSO deadline by two weeks and", now: now, status: "partial",
                        steps: [.init(name: "get_jira_issue")])
            ])
        }

        /// Mockup 2c: two actions wait for the owner's approval.
        static func waiting(now: Date) -> ChatFeed {
            ChatFeed(
                conversation: conversation(release, "Release checklist", lease: .init(owner: "hub", turnID: "turn-5")),
                messages: [
                    message(101, "user", "Post the checklist to #release and move PROJ-12 to Done", now: now),
                    message(102, "assistant", "", now: now, status: "partial", steps: [
                        .init(name: "send_slack_message", outcome: .succeeded, summary: "Drafted message"),
                        .init(name: "transition_jira_issue", outcome: .succeeded, summary: "Drafted move")
                    ])
                ],
                actions: [
                    .init(id: 31, tool: "send_slack_message", title: "Send Slack message",
                          argsDisplay: ##"{"target": {"account_id": 1, "label": "#release", "workspace": "acme"}, "##
                              + ##""text": "Release 1.4 checklist: ✅ notes ✅ tag ⏳ store review"}"##,
                          argsSHA256: "a1", status: "pending", external: true, turnID: "t-release", argsComplete: true),
                    .init(id: 32, tool: "transition_jira_issue", title: "Move PROJ-12 to Done",
                          argsDisplay: #"{"key": "PROJ-12", "status": "Done"}"#, argsSHA256: "b2", status: "pending",
                          external: true, turnID: "t-release", argsComplete: true)
                ]
            )
        }

        static let vendorReply = """
            Here is a draft you can send from your mail app:

            :::artifact key="reply-to-vendor" kind="email" title="Reply to vendor" to="vendor@example.com" subject="Re: renewal"
            Hello, thank you for the offer. We have decided not to renew this year, and we will reach out if that changes.
            :::
            """

        /// Mockup 2d: an email artifact, then the answer stopped (a retryable code).
        static func artifactAndError(now: Date) -> ChatFeed {
            ChatFeed(
                conversation: conversation(vendor, "Draft reply to the vendor"),
                messages: [
                    message(101, "user", "Draft a polite reply declining the renewal", now: now),
                    message(102, "assistant", vendorReply, now: now, status: "partial",
                            error: ("rate_limit", "Claude hit its usage limit. Try again in a few minutes."))
                ],
                artifacts: [.init(key: "reply-to-vendor", kind: "email", title: "Reply to vendor", version: 2, content: """
                    Hello, thank you for the offer. We have decided not to renew this year, and we will reach out if that changes.
                    """)]
            )
        }

        /// Mockup 2e: the copy the phone holds while the Mac sleeps.
        static func held(now: Date) -> ChatFeed {
            ChatFeed(conversation: conversation(billing, "Who owns the billing API?"), messages: [
                message(101, "user", "Who owns the billing API?", now: now),
                message(102, "assistant", "Colleague B leads it since March; colleague C reviews schema changes.", now: now)
            ])
        }

        /// Mockup 2f: the Mac app runs this turn.
        static func elsewhere(now: Date) -> ChatFeed {
            ChatFeed(conversation: conversation(roadmap, "Q3 roadmap summary", lease: .init(owner: "desktop", turnID: "turn-7")), messages: [
                message(101, "user", "Summarise the Q3 roadmap threads", now: now),
                message(102, "assistant", "The roadmap has three threads", now: now, status: "partial")
            ])
        }

        /// Mockup 2i: older history above, a passage quoted into the composer.
        static func quoting(now: Date) -> ChatFeed {
            ChatFeed(conversation: conversation(roadmap, "Q3 roadmap summary"), messages: [
                message(140, "assistant", "Two items are still open: the SSO deadline and the export API.", now: now)
            ], hasMore: true)
        }

        static let quote = ChatQuoteDraft(quote: "the SSO deadline and the export API", comment: "")
    }
}
