import SwiftUI
@testable import WatchtowerDesktop
import WatchtowerCore

/// A long markdown answer in the chat (spec 2026-10-24 §5b): a finished
/// row draws its prose with native text runs, a streaming one with SwiftUI
/// `Text`. The two shots of one width must look the same.
@MainActor
enum ChatMarkdownShotFixtures {
    static let answer = """
        # Daily acme digest

        The recipe runs **every weekday at 9:00** and reads [the channel](https://example.com/c/1), \
        then posts a short note with `output.inbox`. A *closing* line with ~~old text~~ and a \
        [screen link](watchtower-nav://inbox) that wraps across two lines in a narrow column.

        ## What it reads

        - First, it collects the new messages
        - Then it asks `llm()` for a summary
          - nested: with [a style](https://example.com/style)
          - nested: and the owner's language
        - [ ] Confirm the schedule
        - [x] Pick the channel

        | Step | Tool | Reads |
        |---|---|---|
        | 1 | `list_messages` | [#acme](https://example.com/1) |
        | 2 | `llm` | **12** messages |

        | Recipe | Channel | Schedule | State | Runs |
        |:---|---|---|:---:|---:|
        | Daily digest | #acme-general | weekdays 9:00 | on | 12 |
        | Weekly recap with a long name | #acme-team | Fridays 17:00 | off | 3 |

        ```js
        const msgs = tool("list_messages", { channel: "acme" })
        ```

        ### Then

        1. Save the draft
        2. Confirm it
        10. Turn it on

        > A quoted note from the owner, with **bold** and a [link](smb://example.com/share) that is not clickable.
        > Second quoted paragraph.

        ---

        Last paragraph.
        """

    static func finished(width: CGFloat) -> AnyView {
        let message = ChatMessageRecord(id: 2, conversationID: 1, role: "assistant", text: answer, createdAt: 0,
                                        turnID: "t1")
        let item = ChatThreadItem(message: message, steps: [], siblingIndex: 1, siblingCount: 1)
        return AnyView(ChatMessageRow(item: item, isLast: true, isEditing: false, actions: ChatRowActions())
            .environment(\.markdownNavScreens, ["inbox"])
            .frame(width: width, alignment: .topLeading)
            .padding(12))
    }

    static func streaming(width: CGFloat) -> AnyView {
        AnyView(AssistantMessageBody(text: answer, steps: [], isRunning: true)
            .environment(\.markdownNavScreens, ["inbox"])
            .frame(width: width, alignment: .topLeading)
            .padding(12))
    }
}
