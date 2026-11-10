import DesignKit
import SwiftUI

/// An automation's Inbox card drawn from its block document (Inbox
/// builder A): every block, the card body's fallbacks, and the target
/// button's states. Sample data only.
struct ArtifactsPage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.hero) {
            PageSection("Blocks") {
                Sample("Every v1 block, in the Inbox", usage: "ArtifactView(document: doc, cardActions: actions, mode: .inbox)") {
                    ArtifactView(document: ArtifactsPageSamples.everyBlock, cardActions: ArtifactsPageSamples.cardActions,
                                 mode: .inbox)
                        .frame(width: 560)
                }
                Sample("The same card in the editor's Look preview: buttons drawn, disabled",
                       usage: "ArtifactView(document: doc, mode: .preview)") {
                    ArtifactView(document: ArtifactsPageSamples.waiting, mode: .preview)
                        .frame(width: 560)
                }
            }
            PageSection("Card body") {
                Sample("A newer version, and a layout that can't be read: the plain text and why",
                       usage: "ArtifactCardBody(result: ArtifactDocument.decode(json), text: body, mode: .inbox)") {
                    VStack(alignment: .leading, spacing: Spacing.large) {
                        ArtifactCardBody(result: .unsupported(version: 2), text: ArtifactsPageSamples.plainText,
                                         mode: .inbox)
                        ArtifactCardBody(result: .unreadable, text: ArtifactsPageSamples.plainText, mode: .inbox)
                    }
                    .frame(width: 560)
                }
            }
            PageSection("Target button") {
                Sample("A press proposes a task; the state comes from its newest proposal",
                       usage: "ArtifactTargetButton(label:state:mode:action:)  ·  ArtifactTargetStuckLine(onTryAgain:)") {
                    VStack(alignment: .trailing, spacing: Spacing.regular) {
                        ForEach(Array(ArtifactsPageSamples.targetStates.enumerated()), id: \.offset) { _, state in
                            ArtifactTargetButton(label: "Make a task", state: state, mode: .inbox) {}
                        }
                    }
                    .controlSize(.small)
                    .frame(width: 360, alignment: .trailing)
                }
            }
        }
    }
}

/// The page's sample documents, built in code (the gallery reads no files).
enum ArtifactsPageSamples {
    static let cardActions = [
        ArtifactAction(label: "Reply with a summary", payload: .reply(value: "summary", dataJSON: nil), primary: true)
    ]

    static let everyBlock = ArtifactDocument(blocks: [
        .heading(text: "Release 4.2 — where we are", level: 1),
        .metrics([
            ArtifactMetric(label: "Open issues", value: "12"),
            ArtifactMetric(label: "Blocked", value: "3", tone: .danger, hint: "Two wait on review"),
            ArtifactMetric(label: "Done this week", value: "9", tone: .success)
        ]),
        .text(markdown: "The freeze is on **Thursday**. Two items need a decision."),
        .heading(text: "Needs you", level: 2),
        .list(.init(rows: [
            ArtifactListRow(title: "Sign off the checklist", subtitle: "Colleague A in #acme-release",
                            badge: ArtifactBadge(text: "2 days", tone: .danger), tone: .danger,
                            actions: [ArtifactAction(label: "Reply", payload: .reply(value: "checklist", dataJSON: nil))]),
            ArtifactListRow(title: "Pick the rollout window", subtitle: "Colleague B", tone: .warning,
                            actions: [ArtifactAction(label: "Chat", payload: .chat("Help me pick the window"))]),
            ArtifactListRow(title: "Write the release notes", subtitle: "Nobody owns it yet",
                            actions: [ArtifactAction(label: "Make a task",
                                                     payload: .target(ArtifactTargetAction(title: "Write the notes")))])
        ])),
        .table(.init(columns: [ArtifactTableColumn(title: "Service"), ArtifactTableColumn(title: "Owner"),
                               ArtifactTableColumn(title: "Open", align: .trailing)],
                     rows: [[ArtifactTableCell(text: "api"), ArtifactTableCell(text: "Colleague A"), ArtifactTableCell(text: "5")],
                            [ArtifactTableCell(text: "web"), ArtifactTableCell(text: "Colleague B"),
                             ArtifactTableCell(text: "7", tone: .danger)]])),
        .person(.init(name: "Colleague A", role: "Release manager",
                      lines: [ArtifactPersonLine(text: "Owns the checklist"),
                              ArtifactPersonLine(text: "Waiting on you", tone: .warning)])),
        .link(title: "Release 4.2 plan", url: "https://wiki.example.com/acme/release-4-2", subtitle: nil),
        .actions([ArtifactAction(label: "Open the board", payload: .open("https://example.com/acme/board")),
                  ArtifactAction(label: "Ask the assistant", payload: .agent(task: "Summarise the blockers", workbench: nil))])
    ])

    static let waiting = ArtifactDocument(blocks: [
        .heading(text: "Waiting for you · 2", level: 1),
        .list(.init(rows: [
            ArtifactListRow(title: "Release checklist", subtitle: "Colleague A in #acme-release",
                            badge: ArtifactBadge(text: "2 days", tone: .danger), tone: .danger,
                            actions: [ArtifactAction(label: "Reply", payload: .reply(value: "t-1", dataJSON: nil))]),
            ArtifactListRow(title: "Migration review", subtitle: "Colleague C in #acme-infra",
                            badge: ArtifactBadge(text: "3 h"), tone: .neutral,
                            actions: [ArtifactAction(label: "Reply", payload: .reply(value: "t-2", dataJSON: nil))])
        ]))
    ])

    static let plainText = "Release 4.2 — where we are\n- Sign off the checklist — Colleague A [2 days]"

    static let targetStates: [ArtifactTargetButtonState] = [
        .idle, .waiting, .creating, .stuck, .created, .failed(message: "parent_id: task #12 is closed"),
        .proposeError(message: "the database is busy — try again.")
    ]
}
