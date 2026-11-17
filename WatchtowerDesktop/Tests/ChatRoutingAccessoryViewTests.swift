import AppKit
import ChatUI
import ChatWire
import SwiftUI
import ViewInspector
import XCTest
@testable import WatchtowerDesktop

/// The shared routing accessory as the Mac draws it (#1822 T17): its refresh triggers are the view's own (a chat
/// change, busy going to idle, app activation), and a failed availability read is drawn as one warning line.
@MainActor
final class ChatRoutingAccessoryViewTests: XCTestCase {
    private final class Count { var value = 0 }

    private func routing(statusError: String? = nil, refreshes: Count? = nil) -> (ChatRoutingModel, ChatComposerModel) {
        let client = RecordingChatClient()
        let conversation = ChatConversationModel(client: client, conversationID: 7)
        conversation.store.apply(.snapshot(ChatFeed(conversation: ChatFeed.Conversation(id: 7, title: "Plan"), messages: [])))
        let composer = ChatComposerModel(conversation: conversation)
        let model = ChatRoutingModel(client: client, composer: { composer }, onRefresh: refreshes.map { count in { count.value += 1 } })
        model.catalog = ChatRoutingCatalog(providers: [.init(id: "claude", displayName: "Claude")], status: nil, statusError: statusError)
        return (model, composer)
    }

    func testRefreshOnChatChangeActivationAndTurnEnd() async throws {
        let count = Count()
        let (model, _) = routing(refreshes: count)
        let stack = try ChatRoutingAccessory(model: model, isBusy: false, reachable: true).inspect().find(ViewType.VStack.self)

        try await stack.callTask(id: Int64?.some(7))
        XCTAssertEqual(count.value, 1, "a chat change re-reads")

        try stack.callOnChange(oldValue: true, newValue: false)
        for _ in 0..<1_000 where count.value < 2 { await Task.yield() }
        XCTAssertEqual(count.value, 2, "busy going to idle re-reads")
        try stack.callOnChange(oldValue: false, newValue: true)
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(count.value, 2, "a turn starting does not")

        let activation = Task { try await stack.callTask() }
        for _ in 0..<1_000 where count.value < 3 {
            NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
            await Task.yield()
        }
        activation.cancel()
        XCTAssertGreaterThanOrEqual(count.value, 3, "app activation re-reads")
    }

    func testHealthErrorShowsLine() throws {
        let (model, _) = routing(statusError: "Couldn't read provider availability")
        let style = RecordingRoutingStyle()
        let view = ChatRoutingAccessory(model: model, isBusy: false, reachable: true).environment(\.chatUIStyle, style)
        let drawn = try view.inspect().findAll(ViewType.Text.self).filter { try $0.string() == "Couldn't read provider availability" }
        XCTAssertEqual(drawn.count, 1, "one line")
        // The body may be evaluated more than once; every evaluation drew that one caption, in warning tone.
        let warnings = style.captions.value.filter(\.warning)
        XCTAssertFalse(warnings.isEmpty)
        XCTAssertTrue(warnings.allSatisfy { $0.text == "Couldn't read provider availability" }, "the only warning line")
        XCTAssertFalse(style.captions.value.contains { $0.text == "Couldn't read provider availability" && !$0.warning },
                       "in warning tone")
    }
}

/// A plain style that records the routing captions it draws.
private struct RecordingRoutingStyle: ChatUIStyle {
    final class Captions { var value: [(text: String, warning: Bool)] = [] }
    let captions = Captions()
    private let plain = PlainChatUIStyle()

    func primaryButton(_ title: String, action: @escaping () -> Void) -> AnyView { plain.primaryButton(title, action: action) }
    func secondaryButton(_ title: String, action: @escaping () -> Void) -> AnyView { plain.secondaryButton(title, action: action) }
    func card<C: View>(@ViewBuilder _ content: () -> C) -> AnyView { plain.card(content) }
    func chip(_ title: String) -> AnyView { plain.chip(title) }
    func routingCaption(_ text: String, warning: Bool) -> AnyView {
        captions.value.append((text, warning))
        return AnyView(Text(text))
    }
}
