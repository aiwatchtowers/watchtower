# Projects POC — Phase 4 generic edits (apply to Tasks 13/15/16 before Phase 6)

> Binding amendment to `phase4-desktop-terminal-docs.md`, written by the Phase 6 author. It makes Phase 4's comment pieces reusable outside projects (chat artifacts, chat quote-reply — `phase6-chat-comments.md`) with **identical Phase 4 behaviour**: only names, file locations and one view signature change. Apply these while executing Task 16 (or as one follow-up commit if Task 16 already landed). Phase 5 Task 19's `CommentThreadView` call site changes the same way (see the end).


Minimal and behaviour-preserving: after these, the Documents pane (and Task 19's board threads) behave exactly as Phase 4 specifies; only names/locations/signatures change so Phase 6 can reuse the pieces outside projects.

**Task 13 — no change.** `CommentAnchor`'s data shape already lives in `WatchtowerCore/Services/CommentAnchor.swift` with no project dependency; `ProjectCommentThread` stays the project's thread model (Task 16's edit adds a mapping from it).

**Task 15 — no change.** `CommentAnchor.make(text:range:headings:)`/`locate(in:)` and `DocumentRendering.render(_:)` → `RenderedDocument` already take plain text/markdown and know nothing about projects; Phase 6 calls them as specified (and builds `RenderedDocument(text:headings:runs:)` for non-markdown artifacts from inside WatchtowerCore, where the memberwise init is visible).

**Task 16 — five edits:**

- **E1. Move `DocumentTextView.swift` to `WatchtowerDesktop/Sources/Views/Comments/DocumentTextView.swift`** (was `Views/Projects/`). Content unchanged (`DocumentAttributedString` + `DocumentTextView(text:selection:onClick:)`), except the `DocumentAttributedString` doc comment's first line reads "Rendered text → `NSAttributedString`: …" (no "document" wording tied to projects).
- **E2. New Core value `CommentThreadContent`** — create `WatchtowerDesktop/Sources/WatchtowerCore/Models/CommentThreadContent.swift`:

```swift
import Foundation

/// What `CommentThreadView` shows, independent of where the comments live
/// (project documents/targets, chat artifacts): the quoted text, a status
/// line (nil for an open thread) and the comments in order.
package struct CommentThreadContent: Identifiable, Equatable, Sendable {
    package struct Entry: Identifiable, Equatable, Sendable {
        package let id: Int64
        package let author: String
        package let body: String

        package init(id: Int64, author: String, body: String) {
            self.id = id
            self.author = author
            self.body = body
        }
    }

    package let id: Int64
    package let quote: String
    package let statusNote: String?
    package let entries: [Entry]

    package init(id: Int64, quote: String, statusNote: String?, entries: [Entry]) {
        self.id = id
        self.quote = quote
        self.statusNote = statusNote
        self.entries = entries
    }
}
```

  and append to `WatchtowerDesktop/Sources/WatchtowerCore/Models/Project.swift`:

```swift
extension ProjectCommentThread {
    /// The thread as `CommentThreadView` shows it — the same labels the
    /// Phase 4 view derived itself ("You"/the agent's label/"Agent";
    /// "Resolved"/"Outdated — the quoted text changed").
    package var content: CommentThreadContent {
        let note: String? = switch root.status {
        case "open": nil
        case "resolved": "Resolved"
        default: "Outdated — the quoted text changed"
        }
        return CommentThreadContent(
            id: id,
            quote: root.anchorQuote,
            statusNote: note,
            entries: ([root] + replies).map { comment in
                let author = comment.isAgent ? (comment.agentLabel.isEmpty ? "Agent" : comment.agentLabel) : "You"
                return CommentThreadContent.Entry(id: comment.id, author: author, body: comment.body)
            }
        )
    }
}
```

  with a test `WatchtowerDesktop/Tests/Core/CommentThreadContentTests.swift`:

```swift
import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

final class CommentThreadContentTests: XCTestCase {
    func testProjectThreadMapsAuthorsQuoteAndStatus() throws {
        let queue = try TestDatabase.create()
        try queue.write { d in
            let p = try TestDatabase.insertProject(d)
            let doc = try TestDatabase.insertProjectDocument(d, projectID: p)
            let root = try TestDatabase.insertProjectComment(d, projectID: p, author: "owner", body: "Why?",
                                                             documentID: doc, quote: "retry")
            _ = try TestDatabase.insertProjectComment(d, projectID: p, author: "agent", body: "Because.",
                                                      documentID: doc, parentID: root)
            _ = try TestDatabase.insertProjectComment(d, projectID: p, author: "owner", body: "Old",
                                                      documentID: doc, status: "outdated", quote: "gone")
            let threads = ProjectCommentThread.group(try ProjectQueries.comments(d, documentID: doc))

            let open = threads[0].content
            XCTAssertEqual(open.id, root)
            XCTAssertEqual(open.quote, "retry")
            XCTAssertNil(open.statusNote)
            XCTAssertEqual(open.entries.map(\.author), ["You", "Agent"])
            XCTAssertEqual(open.entries.map(\.body), ["Why?", "Because."])
            XCTAssertEqual(threads[1].content.statusNote, "Outdated — the quoted text changed")
        }
    }
}
```

  Run: `make test-swift FILTER=CommentThreadContentTests > /tmp/p16e.log 2>&1; echo "exit=$?"` → `exit=0`.
- **E3. Move `CommentThreadView.swift` to `WatchtowerDesktop/Sources/Views/Comments/CommentThreadView.swift`** and replace its body with the generic version (optional closures: `nil` hides the control):

```swift
import SwiftUI
import WatchtowerCore

/// One comment thread: the quote, the comments, a status line, and the
/// actions its owner allows — a nil closure hides that control. Knows nothing
/// about where the comments live: project document/target threads (Tasks
/// 16/19) and chat artifact comments (Task 24) all pass a
/// `CommentThreadContent`.
struct CommentThreadView: View {
    let thread: CommentThreadContent
    var isActive = false
    var onReply: ((String) async -> Void)?
    var onResolve: (() async -> Void)?
    var onReopen: (() async -> Void)?
    var onDelete: (() async -> Void)?
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !thread.quote.isEmpty {
                Text("\u{201C}\(thread.quote)\u{201D}")
                    .font(.caption).italic()
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            ForEach(thread.entries) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.author).font(.caption).fontWeight(.semibold)
                    Text(entry.body).font(.callout).textSelection(.enabled)
                }
            }
            if let note = thread.statusNote {
                Text(note).font(.caption2).foregroundStyle(.secondary)
            }
            if onReply != nil {
                TextField("Reply", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
            }
            HStack {
                if let onReply {
                    Button("Reply") {
                        let text = draft
                        draft = ""
                        Task { await onReply(text) }
                    }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Spacer()
                if let onDelete { Button("Delete", role: .destructive) { Task { await onDelete() } } }
                if let onResolve { Button("Resolve") { Task { await onResolve() } } }
                if let onReopen { Button("Reopen") { Task { await onReopen() } } }
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? Color.yellow.opacity(0.15) : Color(nsColor: .controlBackgroundColor))
        )
    }
}
```

- **E4. `ProjectDocumentsView.thread(_:_:)` call site** becomes (same behaviour: an open thread offers Resolve, any other offers Reopen; replies always):

```swift
    private func thread(_ thread: ProjectCommentThread, _ docVM: ProjectDocumentViewModel) -> some View {
        CommentThreadView(
            thread: thread.content,
            isActive: thread.id == activeThreadID,
            onReply: { await docVM.reply(to: thread.id, body: $0) },
            onResolve: thread.root.isOpen ? { await docVM.resolve(thread.id) } : nil,
            onReopen: thread.root.isOpen ? nil : { await docVM.reopen(thread.id) }
        )
        .onTapGesture { activeThreadID = thread.id }
    }
```

- **E5. Task 16's Files / Interfaces / commit list** follow the moves: `Views/Comments/DocumentTextView.swift` and `Views/Comments/CommentThreadView.swift` (instead of `Views/Projects/…`), plus `WatchtowerCore/Models/CommentThreadContent.swift`, the `Project.swift` extension and `Tests/Core/CommentThreadContentTests.swift` (add them to Step 11's `git add`; run `make test-swift FILTER=CommentThreadContentTests` in Step 10). The Interfaces line reads `CommentThreadView(thread: CommentThreadContent, isActive:onReply:onResolve:onReopen:onDelete:)` (closures optional) — "reused by Task 19 for target threads and by Task 24 for artifact comments".

**Consequence for Phase 5 Task 19.** Its target-thread call site becomes `CommentThreadView(thread: thread.content, onReply: { … }, onResolve: thread.root.isOpen ? { … } : nil, onReopen: thread.root.isOpen ? nil : { … })` — same behaviour (open → Resolve, otherwise Reopen). Its Step 0 grep looks in `Sources/Views/Comments/CommentThreadView.swift`.
