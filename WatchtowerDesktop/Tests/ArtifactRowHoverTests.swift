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
        XCTAssertEqual(InboxRefHooks.accessibilityPresses(sender).map(\.name), ["Mark All Done…", "Mute"])

        var pressed: [InboxRowPress] = []
        let hooks = InboxRefHooks.make(
            isShown: { _ in true }, content: { _, _ in ping }, onPress: { pressed.append($1) })
        let actions = hooks.accessibilityActions(ref)
        XCTAssertEqual(actions.map(\.name), names)
        actions[2].perform()
        XCTAssertEqual(pressed, [.done])
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
