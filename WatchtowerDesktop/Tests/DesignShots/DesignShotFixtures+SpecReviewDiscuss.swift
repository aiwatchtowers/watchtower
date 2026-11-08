import AppKit
import SwiftUI
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore

/// Shots of spec 2026-11-08 (summary, Discuss threads, per-kind buttons,
/// the `stalled` and `cap` lines) over the same `acme` review as
/// `SpecReviewShotFixtures`. Threads are fixture data on the screen's
/// environment: nothing here runs an assistant.
@MainActor
extension SpecReviewShotFixtures {
    static func threads(_ map: [String: SpecReviewThreadContent]) -> SpecReviewThreads {
        SpecReviewThreads { map[$0] ?? SpecReviewThreadContent() }
    }

    private static let ownerAsks = "Why would mentions not notify? Muting is about the channel, not about me."
    private static let assistantExplains = "Because the spec only says the channel is muted. **Behaviour** names the bell "
        + "and the twenty-four hours, but nothing about mentions, so code that silences the whole channel would match "
        + "the text. You said mentions should still reach you; the reviewer is right that the document does not carry it."
    private static let question = "Did you leave mentions out on purpose, or should a mention still notify while the channel is muted?"

    private static var opening: [SpecReviewThreadEntry] {
        [.owner(id: "m1", text: ownerAsks), .assistant(id: "m2", text: assistantExplains)]
    }

    private static func questionRow(_ state: SpecReviewQuestionRow.State, answer: String = "") -> SpecReviewThreadEntry {
        .question(SpecReviewQuestionRow(id: 3, askID: 1, thread: "spec_review_thread:1:1:ag:4", itemKey: "ag:4",
                                        question: question, answer: answer, state: state))
    }

    private static func proposed(_ status: SpecReviewProposedFinding.Status) -> [SpecReviewThreadEntry] {
        [
            .owner(id: "m1", text: "And what about threads I follow in that channel?"),
            .assistant(id: "m2", text: "The spec does not say. A reply in a thread you follow would stay silent for a day, "
                + "and the review does not raise it. I propose it as a finding."),
            .finding(id: "f1", SpecReviewProposedFinding(
                kind: "blind_spot", severity: .major, title: "Followed threads go silent",
                text: "A reply in a thread the owner follows stays silent for the whole mute.",
                quote: .init(source: "thread", text: "threads I follow in that channel"),
                anchor: .init(heading: "Behaviour", quote: "Muting lasts twenty-four hours."),
                status: status))
        ]
    }

    /// Every thread state a card can show, by name.
    static func threadContent(_ state: String) -> SpecReviewThreadContent {
        switch state {
        case "open":
            return SpecReviewThreadContent(entries: opening, isOpen: true)
        case "replying":
            return SpecReviewThreadContent(entries: opening + [.owner(id: "m3", text: "Does the notifier already handle it?")],
                                           isReplying: true, isOpen: true)
        case "pending":
            return SpecReviewThreadContent(entries: opening + [
                .owner(id: "m3", text: "Maybe the author left it out on purpose?"),
                .assistant(id: "m4", text: "Only the author can say what it meant here. I have asked it in its session."),
                questionRow(.open)
            ], isOpen: true)
        case "answered":
            return SpecReviewThreadContent(entries: opening + [
                .owner(id: "m3", text: "Maybe the author left it out on purpose?"),
                questionRow(.answered, answer: "Left out by mistake: a mention should still notify. I will add a line to Behaviour."),
                .assistant(id: "m5", text: "The author confirms it is an omission, so the finding holds. Press **Fix** and the author adds the line.")
            ], isOpen: true)
        case "expired":
            return SpecReviewThreadContent(entries: opening + [
                .owner(id: "m3", text: "Maybe the author left it out on purpose?"),
                questionRow(.expired),
                .assistant(id: "m5", text: "Without the author: nothing in the document keeps mentions loud, so the finding holds.")
            ], isOpen: true)
        case "proposed":
            return SpecReviewThreadContent(entries: proposed(.proposed), isOpen: true)
        case "refused":
            return SpecReviewThreadContent(entries: proposed(.refused("not added: quote not found")), isOpen: true)
        case "folded":
            return SpecReviewThreadContent(entries: opening + [
                .owner(id: "m3", text: "Fine, then it should be fixed."),
                .assistant(id: "m4", text: "Agreed. **Fix** sends it to the author.")
            ])
        default:
            return SpecReviewThreadContent()
        }
    }

    /// One finding card on its own, the thread in `state`.
    static func threadCard(_ state: String, key: String = "ag:4") -> AnyView {
        cardPage {
            let model = try model("done", status: "done", withResult: true)
            let finding = try XCTUnwrap(model.chapters.flatMap(\.findings).first { $0.key == key })
            return AnyView(SpecReviewFindingCard(model: model, finding: finding)
                .environment(\.specReviewThreads, threads([key: threadContent(state)])))
        }
    }

    /// A column of cards on the drawer's surface, as tall as its content.
    static func cardPage(_ make: () throws -> AnyView) -> AnyView {
        AnyView(view(make)
            .padding(Spacing.medium)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .textBackgroundColor)))
    }

    /// The summary on its own: two theses open, one with its thread.
    static func summary() -> AnyView {
        cardPage {
            let model = try model("done", status: "done", withResult: true)
            let result = try XCTUnwrap(model.row?.result)
            let thread = SpecReviewThreadContent(entries: [
                .owner(id: "t1", text: "How late can a mute end?"),
                .assistant(id: "t2", text: "Up to a minute: the sidebar refreshes once a minute (**Decisions**), "
                    + "so a mute that ends just after a refresh shows until the next one.")
            ], isOpen: true)
            return AnyView(SpecReviewSummaryView(brief: result.brief, theses: result.theses, onDiscuss: { _ in },
                                                 onReadSpec: { _ in }, expanded: ["th:goal", "th:risk"])
                .environment(\.specReviewThreads, threads(["th:risk": thread])))
        }
    }

    /// One card per kind (spec 2026-11-08 §2) on the findings screen:
    /// As agreed, a fixable finding, a check to verify, a finding from a
    /// discussion, and a thesis.
    static func findingKinds() -> AnyView {
        cardPage {
            let model = try model("done", status: "done", withResult: true)
            let findings = model.chapters.flatMap(\.findings)
            let asAgreed = try XCTUnwrap(findings.first { $0.key == "ag:1" })
            let actionable = try XCTUnwrap(findings.first { $0.key == "ag:4" })
            let check = try XCTUnwrap(model.chapters.flatMap(\.checks).first { $0.key == "ck:3" })
            let fromThread = try JSONDecoder().decode(SpecReviewResult.BlindSpot.self, from: Data("""
                {"key":"tf:1","text":"Followed threads go silent","chapter":"ch:2","severity":"major",
                 "why":"A reply in a thread the owner follows stays silent for the whole mute.",
                 "where":{"heading":"Behaviour","quote":"Muting lasts twenty-four hours."}}
                """.utf8))
            let thesis = try XCTUnwrap(model.row?.result?.theses.first { $0.key == "th:goal" })
            return AnyView(VStack(alignment: .leading, spacing: Spacing.medium) {
                SpecReviewFindingCard(model: model, finding: asAgreed)
                SpecReviewFindingCard(model: model, finding: actionable)
                SpecReviewCheckCard(model: model, check: check)
                SpecReviewFindingCard(model: model, finding: .blindSpot(fromThread), kind: .fromDiscussion)
                SpecReviewThesisRow(thesis: thesis, isExpanded: .constant(true), onDiscuss: {}, onReadSpec: {})
            }
            .environment(\.specReviewThreads, threads([:])))
        }
    }

    /// One card per loop kind: a dispute, a finding the author never
    /// answered, a fix by the author (with a folded thread).
    static func loopKinds() -> AnyView {
        cardPage {
            let model = try loopModel("loop-owner-items", end: "stalled", round: 4)
            let ledger = try XCTUnwrap(model.row?.ledger)
            let dispute = try XCTUnwrap(ledger.first { $0.item.key == "ow:2" })
            let unanswered = try XCTUnwrap(ledger.first { $0.item.key == "bs:2" })
            let fixed = try XCTUnwrap(ledger.first { $0.item.key == "da:1" })
            return AnyView(VStack(alignment: .leading, spacing: Spacing.medium) {
                SpecReviewDisputeCard(model: model, entry: dispute)
                SpecReviewDisputeCard(model: model, entry: unanswered, unanswered: true)
                SpecReviewFixRow(model: model, entry: fixed)
            }
            .environment(\.specReviewThreads, threads(["da:1": threadContent("folded")])))
        }
    }

    /// A loop screen that ended on `end`: the owner's own items, fixed and
    /// still open, among the reviewer's.
    static func loopEnded(_ key: String, end: String, round: Int, ownerItems: Bool = true) -> AnyView {
        view {
            let model = try loopModel(key, end: end, round: round, ownerItems: ownerItems)
            model.phase = .wrapup
            return withFooter(model, SpecReviewView(model: model) {}
                .environment(\.specReviewThreads, threads(["ow:2": threadContent("folded")])))
        }
    }
}
