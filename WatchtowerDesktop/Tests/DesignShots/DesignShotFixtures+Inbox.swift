import GRDB
import SwiftUI
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport
@testable import ChatUI

/// The Inbox read like mail (spec B1): a list with all three sections — a
/// proposal, today's cards and an earlier card and reminder — and a selected
/// card with three buttons of its own, a link and a markdown body. Today is
/// fixed (2026-10-21 12:00 UTC), so the sections never move. Each database
/// is a Go desktop case and the list is Go's feed of it (`InboxShotFeed`).
@MainActor
enum InboxShotFixtures {
    private static var poolPath: String?

    static func cleanUp() {
        if let poolPath { TestDatabase.cleanup(path: poolPath) }
        poolPath = nil
    }

    nonisolated private static let now = AutomationDates.parse("2026-10-21T12:00:00Z") ?? Date()

    static func readingPane() async -> AnyView {
        do {
            let (pool, path) = try TestDatabase.createPool()
            cleanUp()
            poolPath = path
            // A proposal, ACME-482 (artifact 4, selected), ACME-479 read, the
            // mail triage's two cards (one from Oct 18) and an overdue reminder.
            let tower = try InboxShotFeed.seeded("desktop_shot_inbox_reading_pane", pool)
            let selected: Int64 = 4
            // Labeled: a trailing closure would bind to `automationsWake`.
            // swiftlint:disable:next trailing_closure
            let vm = ActionStripViewModel(dbPool: pool, cliRunner: FakeCLIRunner(), clock: { now })
            await InboxShotFeed.listed(vm, tower)
            vm.selection = .output(selected)
            return AnyView(InboxSplitView(
                vm: vm,
                proposalCard: { action in
                    MacAgentActionCard(action: action, inFlight: false, onApprove: {}, onReject: {}, onRetry: {})
                },
                onCardAction: { _ in }, onOpenAutomationRun: { _ in }, now: now,
                // Labeled: two closure parameters precede it.
                // swiftlint:disable:next trailing_closure
                emptyList: { EmptyView() }
            )
            .environment(\.markdownNavScreens, ["home"]))
        } catch {
            XCTFail("inbox shot fixture failed: \(error)")
            return AnyView(Text("fixture failed: \(String(describing: error))").foregroundStyle(.red))
        }
    }

    /// A pending `save_automation` proposal selected: its summary, Open Draft
    /// and Reject in the reading pane.
    static func proposalPane() async -> AnyView {
        do {
            let (pool, path) = try TestDatabase.createPool()
            cleanUp()
            poolPath = path
            // A pending `save_automation` proposal (1, selected) beside the mail triage's card.
            let tower = try InboxShotFeed.seeded("desktop_shot_inbox_proposal_pane", pool)
            let selected: Int64 = 1
            // Labeled: a trailing closure would bind to `automationsWake`.
            // swiftlint:disable:next trailing_closure
            let vm = ActionStripViewModel(dbPool: pool, cliRunner: FakeCLIRunner(), clock: { now })
            await InboxShotFeed.listed(vm, tower)
            vm.selection = .proposal(selected)
            return AnyView(InboxSplitView(
                vm: vm,
                proposalCard: { action in
                    MacAgentActionCard(action: action, inFlight: false, onApprove: {}, onReject: {}, onRetry: {})
                },
                saveProposal: { action in
                    SaveAutomationProposalPane(action: action, approval: vm.feedApproval(action.id),
                                               onOpenDraft: { _ in }, onReject: {})
                },
                onCardAction: { _ in }, onOpenAutomationRun: { _ in }, now: now,
                // Labeled: two closure parameters precede it.
                // swiftlint:disable:next trailing_closure
                emptyList: { EmptyView() }
            ))
        } catch {
            XCTFail("inbox proposal shot fixture failed: \(error)")
            return AnyView(Text("fixture failed: \(String(describing: error))").foregroundStyle(.red))
        }
    }

    /// The pane at its narrowest (420 pt) with four 40-character labels:
    /// both button rows wrap, Done and Dismiss stay trailing. The card is
    /// Go's case `desktop_shot_inbox_narrow_pane` (its recipe needs
    /// confirmation), its buttons drawn from that case's feed.
    static func narrowPane() -> AnyView {
        do {
            let (pool, path) = try TestDatabase.createPool()
            cleanUp()
            poolPath = path
            let tower = try InboxShotFeed.seeded("desktop_shot_inbox_narrow_pane", pool)
            let card = try XCTUnwrap(pool.read { db in try AutomationQueries.fetchInboxOutputs(db, ids: [1]).first })
            let feedCard = tower.current().feed.cards.first { $0.id == "o1" }
            let targets = InboxTargetButtonSource { _ in feedCard }
            return AnyView(InboxReadingPane(item: .output(card), navScreens: ["home"], targets: targets, now: now) { _ in }
                .frame(width: 420)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .detailBackground())
        } catch {
            XCTFail("inbox narrow shot fixture failed: \(error)")
            return AnyView(Text("fixture failed: \(String(describing: error))").foregroundStyle(.red))
        }
    }

    /// The whole Inbox with its filter bar: two open messages and a reminder,
    /// one message selected (C1: who, where, the text, why it matters, its
    /// buttons and Snooze ▾).
    static func messagePane() async -> AnyView {
        do {
            let (pool, path) = try TestDatabase.createPool()
            cleanUp()
            poolPath = path
            // A read DM, an overdue reminder and the launch-plan mention (2, selected).
            let tower = try InboxShotFeed.seeded("desktop_shot_inbox_message_pane", pool)
            let selected = 2
            let suite = "InboxShotFixtures.messagePane"
            let defaults = UserDefaults(suiteName: suite) ?? .standard
            defaults.removePersistentDomain(forName: suite)
            // Labeled: a trailing closure would bind to `automationsWake`.
            // swiftlint:disable:next trailing_closure
            let vm = ActionStripViewModel(dbPool: pool, cliRunner: FakeCLIRunner(), defaults: defaults, clock: { now })
            await InboxShotFeed.listed(vm, tower)
            vm.selection = .message(selected)
            return AnyView(ActionStripActionsView(
                vm: vm, cheatSheetRows: [], feature: .on(lastCheck: nil), isEnabling: false, featureError: nil,
                onEnable: {}, onOpenSettings: {}, onOpen: { _ in }, now: now
            )
            .detailBackground())
        } catch {
            XCTFail("inbox message shot fixture failed: \(error)")
            return AnyView(Text("fixture failed: \(String(describing: error))").foregroundStyle(.red))
        }
    }
}
