import AppKit
import XCTest
import SwiftUI
import ViewInspector
@testable import DesignKit
import WatchtowerCore
@testable import WatchtowerDesktop

/// In the Inbox a list row's actions appear over its trailing edge on
/// hover or keyboard focus and never take layout space, so the row's height
/// never changes (spec "Waiting for me and Mail waiting": "the row height
/// never changes"). The Look preview keeps today's inline layout.
@MainActor
final class ArtifactRowHoverTests: XCTestCase {
    private let ref = ArtifactRef(kind: .inboxItem, id: 7)

    private var row: ArtifactListRow {
        ArtifactListRow(
            title: "Colleague A asked about the acme release notes and the rollout plan for next week",
            subtitle: "#acme-release",
            badge: ArtifactBadge(text: "3d"),
            ref: ref
        )
    }

    private var hooks: ArtifactRefHooks {
        // Labeled: a trailing closure would bind to `open`, the last parameter.
        // swiftlint:disable:next trailing_closure
        ArtifactRefHooks(nativeActions: { _, _ in
            AnyView(HStack {
                Button("Open in Slack") {}
                Button("Reply…") {}
                Button("Done") {}
                Button("Hide") {}
                Button("Snooze") {}
            }.fixedSize())
        })
    }

    private func view(focused: ArtifactRef?, mode: ArtifactRenderMode = .inbox) -> some View {
        var environment = ArtifactEnvironment(refHooks: hooks)
        environment.focusedRef = focused
        return ArtifactListRowView(row: row, firstIndex: 0, mode: mode)
            .environment(\.artifactEnvironment, environment)
    }

    func testHoverNeverChangesRowHeight() {
        for width: CGFloat in [360, 640] {
            func height(focused: ArtifactRef?) -> CGFloat {
                NSHostingView(rootView: view(focused: focused).frame(width: width)).fittingSize.height
            }
            let hidden = height(focused: nil)
            XCTAssertGreaterThan(hidden, 0)
            XCTAssertEqual(height(focused: ref), hidden, "width \(width): actions shown keep the height")
        }
    }

    func testActionsHiddenUntilHoverOrFocus() throws {
        XCTAssertFalse(ArtifactRowChrome.showsActions(isHovered: false, isFocused: false, mode: .inbox))
        XCTAssertTrue(ArtifactRowChrome.showsActions(isHovered: true, isFocused: false, mode: .inbox))
        XCTAssertTrue(ArtifactRowChrome.showsActions(isHovered: false, isFocused: true, mode: .inbox))
        // Waiting for me's Older note row keeps its Mark All Done… shown.
        XCTAssertTrue(ArtifactRowChrome.showsActions(isHovered: false, isFocused: false, mode: .inbox, pinned: true))
        // The pin is the host's: the Inbox's hooks pin the Older row, the kit pins nothing.
        let inbox = InboxRefHooks.make(isShown: { _ in true }, content: { _, _ in nil })
        XCTAssertTrue(inbox.pinsActions(ArtifactRef(kind: .waitingOlder, key: "people")))
        XCTAssertFalse(inbox.pinsActions(ref))
        XCTAssertFalse(ArtifactRefHooks().pinsActions(ArtifactRef(kind: .waitingOlder, key: "people")))

        let hidden = try view(focused: nil).inspect()
            .find(viewWithAccessibilityIdentifier: ArtifactRowChrome.actionsIdentifier)
        XCTAssertEqual(try hidden.opacity(), 0)
        let other = try view(focused: ArtifactRef(kind: .inboxItem, id: 8)).inspect()
            .find(viewWithAccessibilityIdentifier: ArtifactRowChrome.actionsIdentifier)
        XCTAssertEqual(try other.opacity(), 0, "another row's focus")
        let shown = try view(focused: ref).inspect()
            .find(viewWithAccessibilityIdentifier: ArtifactRowChrome.actionsIdentifier)
        XCTAssertEqual(try shown.opacity(), 1)
        XCTAssertNoThrow(try shown.find(button: "Done"))
    }

    func testActionsReplaceTheAgeChip() throws {
        let hidden = try view(focused: nil).inspect()
            .find(viewWithAccessibilityIdentifier: ArtifactRowChrome.badgeIdentifier)
        XCTAssertEqual(try hidden.opacity(), 1)
        let shown = try view(focused: ref).inspect()
            .find(viewWithAccessibilityIdentifier: ArtifactRowChrome.badgeIdentifier)
        XCTAssertEqual(try shown.opacity(), 0, "the actions take the chip's place")
    }

    func testHiddenActionsStayAccessible() {
        let ping = InboxRowActionsContent(
            kind: .inboxItem(openLabel: "Open in Slack", openEnabled: true, canReply: true, showsHandToAgent: true))
        let names = InboxRefHooks.accessibilityPresses(ping).map(\.name)
        XCTAssertEqual(names, ["Open in Slack", "Reply…", "Done", "Hide", "Snooze Tomorrow", "Snooze In 3 days",
                               "Snooze Next week", "Discuss in Chat"])
        var busy = ping
        busy.state = .busy
        XCTAssertTrue(InboxRefHooks.accessibilityPresses(busy).isEmpty)
        let sender = InboxRowActionsContent(kind: .mailSender(address: "a@example.com", openEnabled: false))
        XCTAssertEqual(InboxRefHooks.accessibilityPresses(sender, hasBulk: true).map(\.name),
                       ["Mark All Done…", "Mute"])
        // No bulk press: no Mark All Done… to name (the row draws none).
        XCTAssertEqual(InboxRefHooks.accessibilityPresses(sender).map(\.name), ["Mute"])
        let older = InboxRowActionsContent(kind: .waitingOlder)
        XCTAssertTrue(InboxRefHooks.accessibilityPresses(older).isEmpty)
        XCTAssertEqual(InboxRefHooks.accessibilityPresses(older, hasBulk: true).map(\.name), ["Mark All Done…"])
        let opens = InboxRowActionsContent(kind: .mailSender(address: "a@example.com", openEnabled: true))
        XCTAssertEqual(InboxRefHooks.accessibilityPresses(opens, hasBulk: true).map(\.name),
                       ["Open", "Mark All Done…", "Mute"])

        var pressed: [InboxRowPress] = []
        let hooks = InboxRefHooks.make(
            isShown: { _ in true }, content: { _, _ in ping }, onPress: { pressed.append($1) })
        let actions = hooks.accessibilityActions(ref)
        XCTAssertEqual(actions.map(\.name), names)
        actions[2].perform()
        XCTAssertEqual(pressed, [.done])
    }

    /// A sender row whose Mark All Done… is asking keeps Cancel and
    /// "Mark N Done" shown with neither the pointer nor the keyboard on it.
    func testConfirmingSenderRowShowsItsActionsWithoutHover() async throws {
        let center = InboxBulkCenter(cli: { InboxBulkCLI(runner: nil) }, onFinished: {})
        let model = center.model(for: .sender("news@example.com"))
        let senderRef = ArtifactRef(kind: .mailSender, key: "news@example.com")
        let content = InboxRowActionsContent(kind: .mailSender(address: "news@example.com", openEnabled: true))
        let hooks = InboxRefHooks.make(
            isShown: { _ in true }, content: { _, _ in content }, bulk: { _ in model },
            pins: { center.isPinned(.sender($0.key)) })
        let row = ArtifactListRow(title: "news@example.com", subtitle: "46 open · 3 today",
                                  badge: ArtifactBadge(text: "46"), ref: senderRef)
        func overlay() throws -> InspectableView<ViewType.ClassifiedView> {
            try ArtifactListRowView(row: row, firstIndex: 0, mode: .inbox)
                .environment(\.artifactEnvironment, ArtifactEnvironment(refHooks: hooks))
                .inspect()
                .find(viewWithAccessibilityIdentifier: ArtifactRowChrome.actionsIdentifier)
        }
        XCTAssertEqual(try overlay().opacity(), 0, "idle: hover or focus only")

        let plan = InboxBulkPlan(ids: ["1", "2", "3"], count: 3)
        model.begin { plan }
        let deadline = Date().addingTimeInterval(10)
        while model.state != .confirming(plan), Date() < deadline { await Task.yield() }
        let asking = try overlay()
        XCTAssertEqual(try asking.opacity(), 1, "asking: shown without hover")
        XCTAssertNoThrow(try asking.find(button: "Mark 3 Done"))
        XCTAssertNoThrow(try asking.find(button: "Cancel"))
        XCTAssertNoThrow(try asking.find(text: "3 open from this sender"))
        XCTAssertThrowsError(try asking.find(button: "Open"), "the question alone while it asks")
        XCTAssertThrowsError(try asking.find(button: "Mute"), "the question alone while it asks")
        XCTAssertEqual(hooks.accessibilityActions(senderRef).map(\.name), ["Cancel", "Mark 3 Done"],
                       "VoiceOver names the question's answers only")

        model.cancel()
        let answered = try overlay()
        XCTAssertEqual(try answered.opacity(), 0, "answered: back to hover or focus")
        XCTAssertNoThrow(try answered.find(button: "Mute"), "the usual buttons are back")
        XCTAssertNoThrow(try answered.find(button: "Mark All Done…"))
        XCTAssertEqual(hooks.accessibilityActions(senderRef).map(\.name), ["Open", "Mark All Done…", "Mute"])
    }

    /// The drawn buttons and the named actions come from one list: every
    /// name is a drawn button or a drawn menu's choice, with the same rule.
    func testNamedActionsAreTheDrawnButtons() throws {
        var idea = InboxRowActionsContent(kind: .idea(kind: .idea, status: .proposed, awaitsVerdict: true))
        XCTAssertEqual(InboxRefHooks.accessibilityPresses(idea).map(\.name),
                       ["Approve", "Make a Task", "Not now 1 week", "Not now 1 month", "Not now No date", "Reject"])
        let drawn = try InboxRowActionsView(content: idea).inspect()
        for title in ["Approve", "Make a Task", "Reject"] { XCTAssertNoThrow(try drawn.find(button: title)) }
        XCTAssertNoThrow(try drawn.find(ViewType.Menu.self))
        idea.writesUnavailable = true
        XCTAssertTrue(InboxRefHooks.accessibilityPresses(idea).isEmpty, "every verdict off: none named")
        XCTAssertTrue(try InboxRowActionsView(content: idea).inspect().find(button: "Approve").isDisabled())

        let track = InboxRowActionsContent(kind: .track(custom: true, linkedTargetID: 4), cliMissing: true)
        XCTAssertEqual(InboxRefHooks.accessibilityPresses(track).map(\.name),
                       ["Done", "Go to Target", "Delete…"], "Stop watching runs the missing CLI")
    }

    func testPreviewModeUnchanged() throws {
        XCTAssertTrue(ArtifactRowChrome.showsActions(isHovered: false, isFocused: false, mode: .preview))
        let preview = try view(focused: nil, mode: .preview).inspect()
        XCTAssertThrowsError(try preview.find(viewWithAccessibilityIdentifier: ArtifactRowChrome.actionsIdentifier),
                             "no overlay in the preview")
        XCTAssertNoThrow(try preview.find(button: "Done"), "the actions stay inline")
        XCTAssertNoThrow(try preview.find(text: "3d"))
    }
}
