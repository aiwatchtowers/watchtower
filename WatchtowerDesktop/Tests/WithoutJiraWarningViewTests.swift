import XCTest
import SwiftUI
import ViewInspector
@testable import WatchtowerDesktop

@MainActor
final class WithoutJiraWarningViewTests: XCTestCase {

    private func makeRow(
        channelID: String = "C1",
        channelName: String = "general",
        digestCount: Int = 3,
        distinctDays: Int = 5,
        messageCount: Int = 42
    ) -> WithoutJiraRow {
        WithoutJiraRow(
            channelID: channelID,
            channelName: channelName,
            digestCount: digestCount,
            distinctDays: distinctDays,
            messageCount: messageCount
        )
    }

    /// Пустой список → дерево не содержит заголовка "Untracked Discussions".
    func testEmptyArrayHidesView() throws {
        let view = WithoutJiraWarningView(warnings: [])
        XCTAssertThrowsError(try view.inspect().find(text: "Untracked Discussions"))
    }

    /// Непустой список → заголовок виден.
    func testHeaderShownForNonEmpty() throws {
        let view = WithoutJiraWarningView(warnings: [makeRow()])
        XCTAssertNoThrow(try view.inspect().find(text: "Untracked Discussions"))
    }

    /// Имя канала рендерится с префиксом '#'.
    func testChannelNameRenderedWithHash() throws {
        let view = WithoutJiraWarningView(warnings: [makeRow(channelName: "release-talk")])
        XCTAssertNoThrow(try view.inspect().find(text: "#release-talk"))
    }

    /// Метрика "discussed N days (M messages)..." собирается верно.
    func testMetricsTextComposed() throws {
        let view = WithoutJiraWarningView(
            warnings: [makeRow(distinctDays: 7, messageCount: 99)]
        )
        XCTAssertNoThrow(try view.inspect().find(text: "discussed 7 days (99 messages), no Jira issue"))
    }

    /// Несколько каналов → имена обоих в дереве.
    func testMultipleRowsRendered() throws {
        let view = WithoutJiraWarningView(warnings: [
            makeRow(channelID: "C1", channelName: "alpha"),
            makeRow(channelID: "C2", channelName: "beta")
        ])
        XCTAssertNoThrow(try view.inspect().find(text: "#alpha"))
        XCTAssertNoThrow(try view.inspect().find(text: "#beta"))
    }
}
