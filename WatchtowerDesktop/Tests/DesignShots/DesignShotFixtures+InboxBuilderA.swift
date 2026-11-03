import AppKit
import GRDB
import SwiftUI
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore

/// Inbox builder A (plan Task 1): the block renderer, today's Inbox card
/// states, every Look step state and the target button's states, on the
/// Swift sample documents (`WatchtowerKit/Tests/Fixtures/artifact_samples.json`).
/// Compared with the mockups `docs/design/mockups/inbox-builder/a-01 … a-11`.
@MainActor
enum InboxBuilderAShotFixtures {
    static var shots: [DesignShot] {
        [
            DesignShot(name: "artifact-blocks", size: NSSize(width: 660, height: 0)) { blocks() },
            DesignShot(name: "artifact-inbox-living", size: NSSize(width: 660, height: 0)) { inboxLiving() },
            DesignShot(name: "artifact-inbox-markdown", size: NSSize(width: 660, height: 0)) { inboxMarkdown() },
            DesignShot(name: "artifact-inbox-unsupported", size: NSSize(width: 660, height: 0)) {
                inboxFallback(source: "Release review · Run #12 · Oct 30", title: "Release 4.2 — where we are",
                              json: unsupportedJSON(), body: releasePlainText)
            },
            DesignShot(name: "artifact-inbox-unreadable", size: NSSize(width: 660, height: 0)) {
                inboxFallback(source: "Weekly acme report · Run #51 · Mon", title: "Weekly acme report",
                              json: #"{"v":1,"blocks":[{"type":"chart"}]}"#,
                              body: "Weekly acme report\n- 12 open issues, 3 blocked\n- Freeze on Thursday")
            }
        ] + lookShots + targetShots
    }

    private static var lookShots: [DesignShot] {
        let now = Date()
        let waiting = [waitingCard()]
        let living = [waitingCard()] + ["Colleague A", "Colleague B", "Colleague C"].enumerated().map { index, name in
            AutomationLookPaneContent.Card(title: name, key: "person-\(index + 1)", blocksJSON: personJSON(name),
                                           body: name)
        }
        let states: [(String, AutomationLookPaneContent, Int?)] = [
            ("look-empty", .empty, nil),
            ("look-running", .running(previous: .init(cards: waiting)), nil),
            ("look-failed", .failed(
                message: "output.inbox(): blocks[1].rows[0].badge.tone must be one of neutral, info, success, "
                    + "warning, danger, accent",
                steps: ["1 · slack.list_mentions — ok", "2 · output.inbox — error"]), nil),
            ("look-preview", .preview(.init(cards: waiting), tokens: 3100, at: now), nil),
            ("look-preview-picker", .preview(.init(cards: living), tokens: 3100, at: now), nil),
            ("look-stale", .stale(.init(cards: waiting)), nil),
            ("look-stopped", .stopped(.init(cards: waiting)), nil),
            ("look-no-inbox-output", .noInboxOutput, nil),
            ("look-no-card", .noCard(tokens: 1200), nil),
            ("look-save-llm-warning", .preview(.init(cards: [waitingCard(sample: "waiting-with-summary")]),
                                               tokens: 5800, at: now), 5800)
        ]
        return states.map { name, content, llmTokens in
            DesignShot(name: name, size: NSSize(width: 480, height: 640)) {
                lookColumn(content, llmTokens: llmTokens, now: now)
            }
        }
    }

    private static var targetShots: [DesignShot] {
        let states: [(String, ArtifactTargetButtonState)] = [
            ("idle", .idle), ("waiting", .waiting), ("creating", .creating), ("stuck", .stuck),
            ("created", .created), ("failed", .failed(message: "parent_id: task #12 is closed")),
            ("propose-error", .proposeError(message: "the database is busy — try again."))
        ]
        return states.map { name, state in
            DesignShot(name: "artifact-target-button-\(name)", size: NSSize(width: 620, height: 0)) {
                targetRow(state)
            }
        } + [
            DesignShot(name: "approval-card-target-stuck", size: NSSize(width: 620, height: 0)) { approvalCardStuck() }
        ]
    }

    // MARK: - Blocks and Inbox cards

    static func blocks() -> AnyView {
        do {
            let sample = try sample("every-block")
            return AnyView(ArtifactView(document: try document(sample.json), cardActions: sample.cardActions, mode: .inbox)
                .padding(Spacing.page)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .detailBackground())
        } catch {
            return failure(error)
        }
    }

    static func inboxLiving() -> AnyView {
        do {
            let sample = try sample("waiting-living")
            return inboxCard(source: "Threads waiting for me · Updated 10 min ago", title: "Waiting for you · 3",
                             result: ArtifactDocument.decode(sample.json), body: "", actions: sample.cardActions)
        } catch {
            return failure(error)
        }
    }

    static func inboxMarkdown() -> AnyView {
        inboxCard(source: "New mail summary · Run #57", title: "New mail: 4 messages", result: .none,
                  body: "Two invoices from **acme**, one meeting move, one newsletter.", actions: [])
    }

    static func inboxFallback(source: String, title: String, json: String, body: String) -> AnyView {
        inboxCard(source: source, title: title, result: ArtifactDocument.decode(json), body: body, actions: [])
    }

    /// The reading pane's card: its source line, its title, its body.
    private static func inboxCard(
        source: String,
        title: String,
        result: ArtifactDecodeResult,
        body: String,
        actions: [ArtifactAction]
    ) -> AnyView {
        AnyView(VStack(alignment: .leading, spacing: Spacing.medium) {
            Text(source).font(.caption).foregroundStyle(.secondary)
            Text(title).font(.title3.weight(.semibold))
            ArtifactCardBody(result: result, text: body, cardActions: actions, mode: .inbox)
        }
        .padding(Spacing.page)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .environment(\.artifactEnvironment, ArtifactEnvironment(markdown: chatMarkdown))
        .detailBackground())
    }

    /// The app's chat renderer, as the reading pane will inject it.
    private static func chatMarkdown(_ text: String) -> AnyView {
        AnyView(MarkdownView(text: text))
    }

    // MARK: - The Look step

    private enum Step: Hashable { case collects, look, schedule }

    /// The draft column on its Look step: the step picker, the pane, and
    /// the footer with **Save Look** (and the AI-step line when `llmTokens`).
    private static func lookColumn(_ content: AutomationLookPaneContent, llmTokens: Int?, now: Date) -> AnyView {
        AnyView(VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.medium) {
                    KitSegmentedPicker(title: "Step", selection: .constant(Step.look), segments: [
                        KitSegment(value: Step.collects, title: "What it collects"),
                        KitSegment(value: Step.look, title: "Look"),
                        KitSegment(value: Step.schedule, title: "When it runs")
                    ])
                    AutomationLookPane(content: content, onDryRun: {}, now: now)
                }
                .padding(Spacing.large)
            }
            Divider()
            VStack(alignment: .leading, spacing: Spacing.regular) {
                if let llmTokens { AutomationLLMStepWarning(dryRunTokens: llmTokens) }
                HStack {
                    Spacer()
                    Button("Save Look") {}.buttonStyle(.kitPrimary)
                }
            }
            .padding(Spacing.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .detailBackground())
    }

    private static func waitingCard(sample name: String = "waiting-living") -> AutomationLookPaneContent.Card {
        let json = (try? sample(name).json) ?? ""
        return AutomationLookPaneContent.Card(title: "Waiting for you · 3", key: "waiting", blocksJSON: json,
                                              body: "Waiting for you · 3")
    }

    private static func personJSON(_ name: String) -> String {
        let block: [String: Any] = ["type": "person", "name": name, "role": "Colleague", "lines": ["Waiting on you"]]
        let data = (try? JSONSerialization.data(withJSONObject: ["v": 1, "blocks": [block]])) ?? Data()
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    // MARK: - The target button

    private static func targetRow(_ state: ArtifactTargetButtonState) -> AnyView {
        do {
            let sample = try sample("target-row")
            var environment = ArtifactEnvironment()
            environment.targetButtonState = { _ in state }
            return AnyView(ArtifactView(document: try document(sample.json), mode: .inbox)
                .environment(\.artifactEnvironment, environment)
                .padding(Spacing.page)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .detailBackground())
        } catch {
            return failure(error)
        }
    }

    /// The approval card of the same `create_target` proposal, stuck in executing.
    private static func approvalCardStuck() -> AnyView {
        let args = #"{"text":"Sign off the checklist","intent":"Release can't ship without it","parent_id":12}"#
        let action = AgentAction(row: Row([
            "id": 31, "tool": "create_target", "args_json": args, "status": "executing", "surface": "inbox",
            "context_type": "automation_output", "context_id": "7:4:0f3c2a9d81b7e655",
            "reason": "From the Inbox card “Release 4.2 — where we are” of Threads waiting for me",
            "decided_at": "2026-11-03T09:00:00Z"
        ]))
        return AnyView(AgentActionCardView(action: action, inFlight: false, onApprove: {}, onReject: {}, onRetry: {},
                                           targetButtonState: .stuck)
            .padding(Spacing.page)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .detailBackground())
    }

    // MARK: - Samples

    private struct Sample {
        let json: String
        let cardActions: [ArtifactAction]
    }

    private static let releasePlainText = "Release 4.2 — where we are\n- Sign off the checklist — Colleague A [2 days]\n"
        + "- Pick the rollout window — Colleague B"

    private static func samplesObject() throws -> [String: Any] {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // DesignShots
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerDesktop
            .deletingLastPathComponent()
        let url = repo.appendingPathComponent("WatchtowerKit/Tests/Fixtures/artifact_samples.json")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private static func sample(_ name: String) throws -> Sample {
        let documents = try XCTUnwrap(try samplesObject()["documents"] as? [[String: Any]])
        let entry = try XCTUnwrap(documents.first { $0["name"] as? String == name }, "no sample \(name)")
        guard case let .actions(cardActions) = ArtifactDocument.decodeActions(try text(entry["card_actions"])) else {
            throw CocoaError(.coderReadCorrupt)
        }
        return Sample(json: try text(entry["document"]), cardActions: cardActions)
    }

    private static func unsupportedJSON() -> String {
        let unsupported = (try? samplesObject()["unsupported"] as? [[String: Any]])?.first
        return (try? text(unsupported?["document"])) ?? ""
    }

    private static func text(_ object: Any?) throws -> String {
        try XCTUnwrap(String(bytes: try JSONSerialization.data(withJSONObject: try XCTUnwrap(object)), encoding: .utf8))
    }

    private static func document(_ json: String) throws -> ArtifactDocument {
        guard case let .document(document) = ArtifactDocument.decode(json) else {
            throw CocoaError(.coderReadCorrupt)
        }
        return document
    }

    private static func failure(_ error: Error) -> AnyView {
        XCTFail("inbox builder A shot fixture failed: \(error)")
        return AnyView(Text("fixture failed: \(String(describing: error))").foregroundStyle(.red))
    }
}
