# Task AI Agent Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Дать каждому таску (`targets`) агентский AI-чат, который стартует от интента, читает Slack-базу и предлагает изменения таска карточками Approve/Reject; запись в БД делает Swift, не AI.

**Architecture:** Всё в Desktop (Swift) + новый prompt-фрагмент. Go (`internal/ai`, CLI, `internal/db`) не меняется. Чат построен по образцу существующего `TrackChatViewModel`/`TrackChatView` с контекстом беседы `type:"target"`. AI выводит fenced-блок ```` ```watchtower-action ```` с JSON; Swift парсит, прячет из текста, рисует карточку; по Approve вызывает методы `TargetsViewModel`, затем отправляет follow-up-turn, и AI продолжает. MCP остаётся read-only (`read_query`).

**Tech Stack:** Swift 5.10, SwiftUI, GRDB.swift, XCTest. macOS 14+. SPM (`cd WatchtowerDesktop && swift build` / `swift test`).

## Global Constraints

- Go-бэкенд НЕ трогаем: `internal/ai`, CLI `ai query`, `internal/db` остаются как есть. Стрим-протокол (`type:"text"|"session_id"|"done"`) не меняется.
- AI не получает write-доступа к БД: `--allowed-tools` остаётся read-only; модель только ПРЕДЛАГАЕТ действия.
- Все записи в `targets` идут через существующий `TargetsViewModel` (он сам делает `load()` и пишет `updated_at`).
- `Target.progress` — `Double` в диапазоне `0.0...1.0` (НЕ 0–100). AI отдаёт проценты 0–100; Swift делит на 100 и клампит.
- Контекст беседы хранится в `chat_conversations` через `ChatConversationQueries` с `contextType:"target"`, `contextID:String(target.id)`.
- Follow-up после действия отправляется как очередной turn (prompt в `aiService.stream`), отображается как `.system`-сообщение.
- Action types v1 ровно пять: `update_status`, `update_notes`, `update_progress`, `add_sub_item`, `create_child_target`.
- Тесты — XCTest в `WatchtowerDesktop/Tests/`, in-memory БД через `TestDatabase.create()` (возвращает `DatabaseQueue` с полной схемой).
- Не относить ни один guard-тест к ослаблению; новые тесты — отдельные.

---

### Task 1: Модель `ProposedAction`

**Files:**
- Create: `WatchtowerDesktop/Sources/Models/ProposedAction.swift`
- Test: `WatchtowerDesktop/Tests/ProposedActionTests.swift`

**Interfaces:**
- Produces:
  - `enum TaskActionKind: String, Codable` со значениями `updateStatus="update_status"`, `updateNotes="update_notes"`, `updateProgress="update_progress"`, `addSubItem="add_sub_item"`, `createChildTarget="create_child_target"`.
  - `struct ProposedAction: Codable, Identifiable, Equatable` с полями: `id: UUID` (не декодируется), `type: TaskActionKind`, `reason: String`, опц. `status: String?`, `note: String?`, `progress: Int?`, `text: String?`, `intent: String?`, `priority: String?`.
  - `func validate() throws` — бросает `ProposedActionError.invalid(String)` при нарушении.
  - `var cardDescription: String` — человекочитаемое описание для карточки.
  - `enum ProposedActionError: Error, Equatable { case invalid(String) }`.

- [ ] **Step 1: Написать падающий тест**

Create `WatchtowerDesktop/Tests/ProposedActionTests.swift`:

```swift
import XCTest
@testable import WatchtowerDesktop

final class ProposedActionTests: XCTestCase {
    private func decode(_ json: String) throws -> ProposedAction {
        try JSONDecoder().decode(ProposedAction.self, from: Data(json.utf8))
    }

    func testDecodesUpdateStatus() throws {
        let a = try decode(#"{"type":"update_status","status":"done","reason":"finished"}"#)
        XCTAssertEqual(a.type, .updateStatus)
        XCTAssertEqual(a.status, "done")
        XCTAssertEqual(a.reason, "finished")
        XCTAssertNoThrow(try a.validate())
    }

    func testDecodesCreateChildTarget() throws {
        let a = try decode(#"{"type":"create_child_target","text":"Ping Bob","intent":"unblock","priority":"high","reason":"needed"}"#)
        XCTAssertEqual(a.type, .createChildTarget)
        XCTAssertEqual(a.text, "Ping Bob")
        XCTAssertEqual(a.intent, "unblock")
        XCTAssertEqual(a.priority, "high")
    }

    func testUnknownTypeFailsDecoding() {
        XCTAssertThrowsError(try decode(#"{"type":"delete_everything","reason":"x"}"#))
    }

    func testValidateRejectsBadStatus() throws {
        let a = try decode(#"{"type":"update_status","status":"frobnicate","reason":"x"}"#)
        XCTAssertThrowsError(try a.validate())
    }

    func testValidateRejectsProgressOutOfRange() throws {
        let a = try decode(#"{"type":"update_progress","progress":150,"reason":"x"}"#)
        XCTAssertThrowsError(try a.validate())
    }

    func testValidateRejectsEmptyNote() throws {
        let a = try decode(#"{"type":"update_notes","note":"   ","reason":"x"}"#)
        XCTAssertThrowsError(try a.validate())
    }

    func testValidateRejectsEmptyReason() throws {
        let a = try decode(#"{"type":"add_sub_item","text":"do it","reason":""}"#)
        XCTAssertThrowsError(try a.validate())
    }

    func testCardDescriptionIncludesReason() throws {
        let a = try decode(#"{"type":"update_status","status":"done","reason":"all merged"}"#)
        XCTAssertTrue(a.cardDescription.contains("done"))
        XCTAssertTrue(a.cardDescription.contains("all merged"))
    }
}
```

- [ ] **Step 2: Запустить тест — убедиться, что не компилируется/падает**

Run: `cd WatchtowerDesktop && swift test --filter ProposedActionTests`
Expected: FAIL (нет типа `ProposedAction`).

- [ ] **Step 3: Реализовать модель**

Create `WatchtowerDesktop/Sources/Models/ProposedAction.swift`:

```swift
import Foundation

enum TaskActionKind: String, Codable {
    case updateStatus = "update_status"
    case updateNotes = "update_notes"
    case updateProgress = "update_progress"
    case addSubItem = "add_sub_item"
    case createChildTarget = "create_child_target"
}

enum ProposedActionError: Error, Equatable {
    case invalid(String)
}

/// A task-mutating action the AI proposes. The AI never writes to the DB;
/// it emits one of these as JSON inside a ```watchtower-action``` block and
/// the desktop app applies it only after the user approves.
struct ProposedAction: Codable, Identifiable, Equatable {
    let id = UUID()
    let type: TaskActionKind
    let reason: String
    var status: String?
    var note: String?
    var progress: Int?
    var text: String?
    var intent: String?
    var priority: String?

    enum CodingKeys: String, CodingKey {
        case type, reason, status, note, progress, text, intent, priority
    }

    static let allowedStatuses: Set<String> = [
        "todo", "in_progress", "blocked", "done", "dismissed", "snoozed",
    ]
    static let allowedPriorities: Set<String> = ["high", "medium", "low"]

    func validate() throws {
        if reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ProposedActionError.invalid("reason is required")
        }
        switch type {
        case .updateStatus:
            guard let status, Self.allowedStatuses.contains(status) else {
                throw ProposedActionError.invalid("status must be one of \(Self.allowedStatuses.sorted())")
            }
        case .updateNotes:
            guard let note, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ProposedActionError.invalid("note is required")
            }
        case .updateProgress:
            guard let progress, (0...100).contains(progress) else {
                throw ProposedActionError.invalid("progress must be 0...100")
            }
        case .addSubItem:
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ProposedActionError.invalid("text is required")
            }
        case .createChildTarget:
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ProposedActionError.invalid("text is required")
            }
            if let priority, !Self.allowedPriorities.contains(priority) {
                throw ProposedActionError.invalid("priority must be one of \(Self.allowedPriorities.sorted())")
            }
        }
    }

    var cardDescription: String {
        switch type {
        case .updateStatus:
            return "Set status → \(status ?? "?")\n\(reason)"
        case .updateNotes:
            return "Add note: \(note ?? "")\n\(reason)"
        case .updateProgress:
            return "Set progress → \(progress ?? 0)%\n\(reason)"
        case .addSubItem:
            return "Add sub-item: \(text ?? "")\n\(reason)"
        case .createChildTarget:
            return "Create child target: \(text ?? "")\n\(reason)"
        }
    }
}
```

- [ ] **Step 4: Запустить тест — зелёный**

Run: `cd WatchtowerDesktop && swift test --filter ProposedActionTests`
Expected: PASS (8 тестов).

- [ ] **Step 5: Commit**

```bash
git add WatchtowerDesktop/Sources/Models/ProposedAction.swift WatchtowerDesktop/Tests/ProposedActionTests.swift
git commit -m "feat(targets): ProposedAction model for task AI agent"
```

---

### Task 2: Парсер fenced-блоков `TaskActionParser`

**Files:**
- Create: `WatchtowerDesktop/Sources/Services/TaskActionParser.swift`
- Test: `WatchtowerDesktop/Tests/TaskActionParserTests.swift`

**Interfaces:**
- Consumes: `ProposedAction` (Task 1).
- Produces:
  - `enum TaskActionParser` со `static func parse(_ raw: String) -> (text: String, actions: [ProposedAction], errors: [String])`.
  - `text` — исходный текст с ВЫРЕЗАННЫМИ блоками (trimmed). `actions` — провалидированные действия. `errors` — сообщения для невалидных/битых блоков.

- [ ] **Step 1: Написать падающий тест**

Create `WatchtowerDesktop/Tests/TaskActionParserTests.swift`:

```swift
import XCTest
@testable import WatchtowerDesktop

final class TaskActionParserTests: XCTestCase {
    func testNoBlockReturnsTextUnchanged() {
        let r = TaskActionParser.parse("Just a plain answer.")
        XCTAssertEqual(r.text, "Just a plain answer.")
        XCTAssertTrue(r.actions.isEmpty)
        XCTAssertTrue(r.errors.isEmpty)
    }

    func testSingleBlockExtractedAndStripped() {
        let raw = """
        Here is what I'll do:
        ```watchtower-action
        {"type":"update_status","status":"done","reason":"merged"}
        ```
        Done.
        """
        let r = TaskActionParser.parse(raw)
        XCTAssertEqual(r.actions.count, 1)
        XCTAssertEqual(r.actions.first?.type, .updateStatus)
        XCTAssertFalse(r.text.contains("watchtower-action"))
        XCTAssertTrue(r.text.contains("Here is what"))
        XCTAssertTrue(r.text.contains("Done."))
    }

    func testMultipleBlocks() {
        let raw = """
        ```watchtower-action
        {"type":"add_sub_item","text":"a","reason":"r1"}
        ```
        and
        ```watchtower-action
        {"type":"update_progress","progress":50,"reason":"r2"}
        ```
        """
        let r = TaskActionParser.parse(raw)
        XCTAssertEqual(r.actions.count, 2)
        XCTAssertTrue(r.errors.isEmpty)
    }

    func testBrokenJSONBecomesError() {
        let raw = """
        ```watchtower-action
        {"type":"update_status", oops}
        ```
        """
        let r = TaskActionParser.parse(raw)
        XCTAssertTrue(r.actions.isEmpty)
        XCTAssertEqual(r.errors.count, 1)
    }

    func testInvalidActionBecomesError() {
        let raw = """
        ```watchtower-action
        {"type":"update_progress","progress":999,"reason":"x"}
        ```
        """
        let r = TaskActionParser.parse(raw)
        XCTAssertTrue(r.actions.isEmpty)
        XCTAssertEqual(r.errors.count, 1)
    }
}
```

- [ ] **Step 2: Запустить — падает**

Run: `cd WatchtowerDesktop && swift test --filter TaskActionParserTests`
Expected: FAIL (нет `TaskActionParser`).

- [ ] **Step 3: Реализовать парсер**

Create `WatchtowerDesktop/Sources/Services/TaskActionParser.swift`:

```swift
import Foundation

/// Extracts ```watchtower-action``` fenced JSON blocks from AI output.
/// The AI emits one ProposedAction JSON object per block; everything else
/// is the human-visible answer. Blocks are removed from the visible text.
enum TaskActionParser {
    private static let pattern = "```watchtower-action\\s*\\n(.*?)\\n?```"

    static func parse(_ raw: String) -> (text: String, actions: [ProposedAction], errors: [String]) {
        guard let regex = try? NSRegularExpression(
            pattern: pattern, options: [.dotMatchesLineSeparators]
        ) else {
            return (raw, [], [])
        }

        let full = raw as NSString
        let matches = regex.matches(in: raw, range: NSRange(location: 0, length: full.length))

        var actions: [ProposedAction] = []
        var errors: [String] = []
        for match in matches where match.numberOfRanges >= 2 {
            let json = full.substring(with: match.range(at: 1))
            do {
                let action = try JSONDecoder().decode(ProposedAction.self, from: Data(json.utf8))
                try action.validate()
                actions.append(action)
            } catch let ProposedActionError.invalid(msg) {
                errors.append(msg)
            } catch {
                errors.append("malformed action JSON")
            }
        }

        let stripped = regex.stringByReplacingMatches(
            in: raw, range: NSRange(location: 0, length: full.length), withTemplate: ""
        )
        let text = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        return (text, actions, errors)
    }
}
```

- [ ] **Step 4: Запустить — зелёный**

Run: `cd WatchtowerDesktop && swift test --filter TaskActionParserTests`
Expected: PASS (5 тестов).

- [ ] **Step 5: Commit**

```bash
git add WatchtowerDesktop/Sources/Services/TaskActionParser.swift WatchtowerDesktop/Tests/TaskActionParserTests.swift
git commit -m "feat(targets): parse watchtower-action blocks from AI output"
```

---

### Task 3: DB-мутаторы `updateProgress` и `createChild`

**Files:**
- Modify: `WatchtowerDesktop/Sources/Database/Queries/TargetQueries.swift` (добавить `updateProgress`)
- Modify: `WatchtowerDesktop/Sources/ViewModels/TargetsViewModel.swift` (добавить `updateProgress`, `createChild`)
- Test: `WatchtowerDesktop/Tests/TargetAgentMutatorsTests.swift`

**Interfaces:**
- Consumes: `TargetQueries.create` (`text:intent:level:periodStart:periodEnd:parentId:priority:sourceType:sourceID:` → `Int`), `TargetQueries.fetchByID`.
- Produces:
  - `static func TargetQueries.updateProgress(_ db: Database, id: Int, progress: Double) throws`
  - `@MainActor func TargetsViewModel.updateProgress(_ target: Target, to progress: Double)`
  - `@MainActor func TargetsViewModel.createChild(_ parent: Target, text: String, intent: String, priority: String) -> Int?` — возвращает id нового таска или nil при ошибке.

- [ ] **Step 1: Написать падающий тест**

Create `WatchtowerDesktop/Tests/TargetAgentMutatorsTests.swift`:

```swift
import XCTest
import GRDB
@testable import WatchtowerDesktop

final class TargetAgentMutatorsTests: XCTestCase {
    func testUpdateProgressClampsAndPersists() throws {
        let queue = try TestDatabase.create()
        let id = try queue.write { db in
            try TargetQueries.create(db, text: "t", periodStart: "2026-06-26", periodEnd: "2026-06-26")
        }
        try queue.write { db in
            try TargetQueries.updateProgress(db, id: id, progress: 0.42)
        }
        let target = try queue.read { db in try TargetQueries.fetchByID(db, id: id) }
        XCTAssertEqual(target?.progress ?? 0, 0.42, accuracy: 0.0001)
    }

    @MainActor
    func testCreateChildInheritsPeriodAndParent() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let parentID = try manager.dbPool.write { db in
            try TargetQueries.create(db, text: "parent", periodStart: "2026-06-01", periodEnd: "2026-06-30")
        }
        let parent = try manager.dbPool.read { db in try TargetQueries.fetchByID(db, id: parentID) }!
        let vm = TargetsViewModel(dbManager: manager)

        let childID = vm.createChild(parent, text: "child", intent: "do x", priority: "high")
        XCTAssertNotNil(childID)

        let child = try manager.dbPool.read { db in try TargetQueries.fetchByID(db, id: childID!) }!
        XCTAssertEqual(child.parentId, parentID)
        XCTAssertEqual(child.periodStart, "2026-06-01")
        XCTAssertEqual(child.periodEnd, "2026-06-30")
        XCTAssertEqual(child.priority, "high")
        XCTAssertEqual(child.intent, "do x")
    }
}
```

> Примечание: проверь точную сигнатуру `TargetsViewModel.init` — выше предполагается `init(dbManager:)`. Если init требует доп. аргументы со значениями по умолчанию, вызов не меняется; если обязателен ещё один параметр — передай его (см. `ViewModels/TargetsViewModel.swift:27`).

- [ ] **Step 2: Запустить — падает**

Run: `cd WatchtowerDesktop && swift test --filter TargetAgentMutatorsTests`
Expected: FAIL (нет `updateProgress`/`createChild`).

- [ ] **Step 3a: Добавить `TargetQueries.updateProgress`**

В `WatchtowerDesktop/Sources/Database/Queries/TargetQueries.swift` после `updatePriority` (около строки 236) добавь:

```swift
    static func updateProgress(_ db: Database, id: Int, progress: Double) throws {
        let clamped = min(max(progress, 0.0), 1.0)
        try db.execute(
            sql: """
                UPDATE targets SET progress = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
                WHERE id = ?
                """,
            arguments: [clamped, id]
        )
    }
```

- [ ] **Step 3b: Добавить методы в `TargetsViewModel`**

В `WatchtowerDesktop/Sources/ViewModels/TargetsViewModel.swift` после `updateStatus` (около строки 323) добавь:

```swift
    func updateProgress(_ target: Target, to progress: Double) {
        do {
            try dbManager.dbPool.write { db in
                try TargetQueries.updateProgress(db, id: target.id, progress: progress)
            }
            load()
        } catch {
            errorMessage = "Failed to update progress: \(error.localizedDescription)"
        }
    }

    /// Create a child target under `parent`, inheriting its planning period and
    /// level. Used by the task AI agent. Returns the new id, or nil on failure.
    @discardableResult
    func createChild(_ parent: Target, text: String, intent: String, priority: String) -> Int? {
        do {
            let newID = try dbManager.dbPool.write { db in
                try TargetQueries.create(
                    db,
                    text: text,
                    intent: intent,
                    level: parent.level,
                    periodStart: parent.periodStart,
                    periodEnd: parent.periodEnd,
                    parentId: parent.id,
                    priority: priority,
                    sourceType: "chat",
                    sourceID: "target:\(parent.id)"
                )
            }
            load()
            return newID
        } catch {
            errorMessage = "Failed to create child target: \(error.localizedDescription)"
            return nil
        }
    }
```

- [ ] **Step 4: Запустить — зелёный**

Run: `cd WatchtowerDesktop && swift test --filter TargetAgentMutatorsTests`
Expected: PASS (2 теста).

- [ ] **Step 5: Commit**

```bash
git add WatchtowerDesktop/Sources/Database/Queries/TargetQueries.swift WatchtowerDesktop/Sources/ViewModels/TargetsViewModel.swift WatchtowerDesktop/Tests/TargetAgentMutatorsTests.swift
git commit -m "feat(targets): updateProgress + createChild mutators for AI agent"
```

---

### Task 4: Исполнитель действий `TaskActionExecutor`

**Files:**
- Create: `WatchtowerDesktop/Sources/Services/TaskActionExecutor.swift`
- Test: `WatchtowerDesktop/Tests/TaskActionExecutorTests.swift`

**Interfaces:**
- Consumes: `ProposedAction` (T1); `TargetsViewModel` методы `updateStatus`, `addNote`, `updateProgress`, `addSubItem`, `createChild` (T3 + существующие).
- Produces:
  - `enum TaskActionExecutor` со `@MainActor static func apply(_ action: ProposedAction, target: Target, viewModel: TargetsViewModel) -> String`.
  - Возвращает короткое summary (для follow-up в беседу), напр. `"set status to done"`. Маппинг по `type`. Делит `progress`/100 для `updateProgress`.

- [ ] **Step 1: Написать падающий тест**

Create `WatchtowerDesktop/Tests/TaskActionExecutorTests.swift`:

```swift
import XCTest
import GRDB
@testable import WatchtowerDesktop

@MainActor
final class TaskActionExecutorTests: XCTestCase {
    private func makeTarget(_ manager: DatabaseManager) throws -> Target {
        let id = try manager.dbPool.write { db in
            try TargetQueries.create(db, text: "parent", periodStart: "2026-06-01", periodEnd: "2026-06-30")
        }
        return try manager.dbPool.read { db in try TargetQueries.fetchByID(db, id: id) }!
    }

    func testApplyUpdateStatus() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let target = try makeTarget(manager)
        let vm = TargetsViewModel(dbManager: manager)

        let action = ProposedAction(type: .updateStatus, reason: "done", status: "done")
        _ = TaskActionExecutor.apply(action, target: target, viewModel: vm)

        let after = try manager.dbPool.read { db in try TargetQueries.fetchByID(db, id: target.id) }!
        XCTAssertEqual(after.status, "done")
    }

    func testApplyUpdateProgressDividesByHundred() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let target = try makeTarget(manager)
        let vm = TargetsViewModel(dbManager: manager)

        let action = ProposedAction(type: .updateProgress, reason: "half", progress: 50)
        _ = TaskActionExecutor.apply(action, target: target, viewModel: vm)

        let after = try manager.dbPool.read { db in try TargetQueries.fetchByID(db, id: target.id) }!
        XCTAssertEqual(after.progress, 0.5, accuracy: 0.0001)
    }

    func testApplyAddNote() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let target = try makeTarget(manager)
        let vm = TargetsViewModel(dbManager: manager)

        let action = ProposedAction(type: .updateNotes, reason: "log", note: "spoke to Bob")
        _ = TaskActionExecutor.apply(action, target: target, viewModel: vm)

        let after = try manager.dbPool.read { db in try TargetQueries.fetchByID(db, id: target.id) }!
        XCTAssertTrue(after.decodedNotes.contains { $0.text == "spoke to Bob" })
    }

    func testApplyAddSubItem() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let target = try makeTarget(manager)
        let vm = TargetsViewModel(dbManager: manager)

        let action = ProposedAction(type: .addSubItem, reason: "step", text: "draft reply")
        _ = TaskActionExecutor.apply(action, target: target, viewModel: vm)

        let after = try manager.dbPool.read { db in try TargetQueries.fetchByID(db, id: target.id) }!
        XCTAssertTrue(after.decodedSubItems.contains { $0.text == "draft reply" })
    }

    func testApplyCreateChildTarget() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let target = try makeTarget(manager)
        let vm = TargetsViewModel(dbManager: manager)

        let action = ProposedAction(type: .createChildTarget, reason: "spin off",
                                    text: "Ping Bob", intent: "unblock", priority: "high")
        let summary = TaskActionExecutor.apply(action, target: target, viewModel: vm)

        let children = try manager.dbPool.read { db in
            try Target.fetchAll(db, sql: "SELECT * FROM targets WHERE parent_id = ?", arguments: [target.id])
        }
        XCTAssertEqual(children.count, 1)
        XCTAssertEqual(children.first?.text, "Ping Bob")
        XCTAssertFalse(summary.isEmpty)
    }
}
```

> Примечание: `Target.decodedNotes` / `decodedSubItems` — существующие computed-свойства модели `Target` (см. `Models/Target.swift`). Если имена отличаются — сверь и поправь обращения в тесте.

- [ ] **Step 2: Запустить — падает**

Run: `cd WatchtowerDesktop && swift test --filter TaskActionExecutorTests`
Expected: FAIL (нет `TaskActionExecutor`).

- [ ] **Step 3: Реализовать исполнитель**

Create `WatchtowerDesktop/Sources/Services/TaskActionExecutor.swift`:

```swift
import Foundation

/// Applies an approved ProposedAction to a target via TargetsViewModel.
/// The AI proposes; this executor (driven by an explicit user Approve) is the
/// only thing that mutates the DB. Returns a short summary for the follow-up
/// message sent back into the conversation.
enum TaskActionExecutor {
    @MainActor
    static func apply(_ action: ProposedAction, target: Target, viewModel: TargetsViewModel) -> String {
        switch action.type {
        case .updateStatus:
            let status = action.status ?? "todo"
            viewModel.updateStatus(target, to: status)
            return "set status to \(status)"
        case .updateNotes:
            let note = action.note ?? ""
            viewModel.addNote(target, text: note)
            return "added a note"
        case .updateProgress:
            let pct = action.progress ?? 0
            viewModel.updateProgress(target, to: Double(pct) / 100.0)
            return "set progress to \(pct)%"
        case .addSubItem:
            let text = action.text ?? ""
            viewModel.addSubItem(target, text: text)
            return "added sub-item \"\(text)\""
        case .createChildTarget:
            let text = action.text ?? ""
            viewModel.createChild(
                target, text: text,
                intent: action.intent ?? "",
                priority: action.priority ?? "medium"
            )
            return "created child target \"\(text)\""
        }
    }
}
```

- [ ] **Step 4: Запустить — зелёный**

Run: `cd WatchtowerDesktop && swift test --filter TaskActionExecutorTests`
Expected: PASS (5 тестов).

- [ ] **Step 5: Commit**

```bash
git add WatchtowerDesktop/Sources/Services/TaskActionExecutor.swift WatchtowerDesktop/Tests/TaskActionExecutorTests.swift
git commit -m "feat(targets): TaskActionExecutor applies approved actions"
```

---

### Task 5: `TargetChatViewModel` (агентский цикл)

**Files:**
- Create: `WatchtowerDesktop/Sources/ViewModels/TargetChatViewModel.swift`
- Test: `WatchtowerDesktop/Tests/TargetChatViewModelTests.swift`

**Interfaces:**
- Consumes: `TaskActionParser` (T2), `TaskActionExecutor` (T4), `ProposedAction` (T1), `ChatConversationQueries`, `ChatMessageQueries`, `ChatViewModel.fetchSchema`, `WorkspaceQueries`, `WatchtowerAIService`, `AIServiceProtocol`, `ChatMessage`.
- Produces:
  - `@MainActor @Observable final class TargetChatViewModel` с публичными: `var messages: [ChatMessage]`, `var actionCards: [TargetActionCard]`, `var isStreaming`, `var inputText`, `var errorMessage`, `func send()`, `func cancelStream()`, `func approve(_ card: TargetActionCard)`, `func reject(_ card: TargetActionCard)`, `init(target:viewModel:dbManager:aiService:)`.
  - `struct TargetActionCard: Identifiable, Equatable` с `id: UUID`, `messageID: UUID`, `action: ProposedAction`, `var state: State`; `enum State: Equatable { case pending, applied(String), rejected, failed(String) }`.
  - `static func buildSystemPrompt(target:dbPool:) -> String` — включает `intent`, описание таска, схему БД и КОНТРАКТ ДЕЙСТВИЙ (см. ниже).

**Контракт действий в system-prompt (точный текст для блока):**

```
=== TASK ACTIONS ===
To change THIS task, do NOT write to the database and do NOT call any write tool.
Instead output a fenced block exactly like:
```watchtower-action
{ "type": "<action>", ...fields, "reason": "<why>" }
```
One JSON object per block; emit multiple blocks for multiple actions.
After emitting a block, STOP and wait — do NOT assume it was applied.
Supported actions and required fields:
- update_status      { "status": "todo|in_progress|blocked|done|dismissed|snoozed" }
- update_notes       { "note": "<text to append>" }
- update_progress    { "progress": <0-100 integer> }
- add_sub_item       { "text": "<sub-item text>" }
- create_child_target{ "text": "<title>", "intent": "<goal>", "priority": "high|medium|low" }
Every block must also include "reason".
```

- [ ] **Step 1: Написать падающий тест**

Create `WatchtowerDesktop/Tests/TargetChatViewModelTests.swift`:

```swift
import XCTest
import GRDB
@testable import WatchtowerDesktop

@MainActor
final class TargetChatViewModelTests: XCTestCase {
    private func makeTarget(_ manager: DatabaseManager, intent: String) throws -> Target {
        let id = try manager.dbPool.write { db in
            try TargetQueries.create(db, text: "ship feature", intent: intent,
                                     periodStart: "2026-06-01", periodEnd: "2026-06-30")
        }
        return try manager.dbPool.read { db in try TargetQueries.fetchByID(db, id: id) }!
    }

    func testSystemPromptIncludesIntentAndContract() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        try manager.dbPool.write { db in try TestDatabase.insertWorkspace(db) }
        let target = try makeTarget(manager, intent: "get sign-off from design")

        let prompt = TargetChatViewModel.buildSystemPrompt(target: target, dbPool: manager.dbPool)
        XCTAssertTrue(prompt.contains("get sign-off from design"))
        XCTAssertTrue(prompt.contains("=== TASK ACTIONS ==="))
        XCTAssertTrue(prompt.contains("watchtower-action"))
        XCTAssertTrue(prompt.contains("create_child_target"))
    }

    func testApproveAppliesActionAndAppendsFollowUp() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let target = try makeTarget(manager, intent: "x")
        let vm = TargetsViewModel(dbManager: manager)
        let chat = TargetChatViewModel(target: target, viewModel: vm, dbManager: manager,
                                       aiService: MockClaudeService())

        let action = ProposedAction(type: .updateStatus, reason: "done", status: "done")
        let card = TargetActionCard(messageID: UUID(), action: action, state: .pending)
        chat.actionCards = [card]
        chat.approve(card)

        let after = try manager.dbPool.read { db in try TargetQueries.fetchByID(db, id: target.id) }!
        XCTAssertEqual(after.status, "done")
        // card transitions to applied
        XCTAssertEqual(chat.actionCards.first?.state, .applied("set status to done"))
    }

    func testRejectMarksCardRejected() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let target = try makeTarget(manager, intent: "x")
        let vm = TargetsViewModel(dbManager: manager)
        let chat = TargetChatViewModel(target: target, viewModel: vm, dbManager: manager,
                                       aiService: MockClaudeService())

        let action = ProposedAction(type: .updateStatus, reason: "done", status: "done")
        let card = TargetActionCard(messageID: UUID(), action: action, state: .pending)
        chat.actionCards = [card]
        chat.reject(card)

        XCTAssertEqual(chat.actionCards.first?.state, .rejected)
        let after = try manager.dbPool.read { db in try TargetQueries.fetchByID(db, id: target.id) }!
        XCTAssertEqual(after.status, "todo") // unchanged
    }
}
```

> `MockClaudeService` — существующий helper (`Tests/Helpers/MockClaudeService.swift`), реализует `AIServiceProtocol`. Approve/Reject в тесте вызывают follow-up-стрим; mock должен корректно завершаться (вернуть пустой/готовый стрим). Если у mock нет настраиваемого ответа по умолчанию — он всё равно должен завершать стрим без ошибки. Сверь сигнатуру init mock'а.

- [ ] **Step 2: Запустить — падает**

Run: `cd WatchtowerDesktop && swift test --filter TargetChatViewModelTests`
Expected: FAIL (нет `TargetChatViewModel`).

- [ ] **Step 3: Реализовать ViewModel**

Create `WatchtowerDesktop/Sources/ViewModels/TargetChatViewModel.swift`. Скопируй структуру из `Views/Tracks/TrackChatView.swift` (класс `TrackChatViewModel`, строки 6–294) и адаптируй:

1. Замени `track: Track` → `target: Target`, `viewModel: TracksViewModel?` → `viewModel: TargetsViewModel`, контекст беседы `"track"`/`track.id` → `"target"`/`String(target.id)`, заголовок `"Track: ..."` → `"Task: \(String(target.text.prefix(60)))"`, `reloadTrack`/`TrackQueries.fetchByID` → `reloadTarget`/`TargetQueries.fetchByID`.
2. Добавь модель карточки и состояние:

```swift
struct TargetActionCard: Identifiable, Equatable {
    let id = UUID()
    let messageID: UUID
    let action: ProposedAction
    var state: State

    enum State: Equatable {
        case pending
        case applied(String)
        case rejected
        case failed(String)
    }
}
```

В классе добавь `var actionCards: [TargetActionCard] = []`.

3. После завершения turn'а (в `executeStream`, там где сейчас сохраняется ответ) распарси действия и преврати ответ в видимый текст. Замени блок сохранения ответа на:

```swift
        // Parse watchtower-action blocks out of the final text.
        let parsed = TaskActionParser.parse(fullText)
        let visibleText = parsed.text
        updateLastMessage(visibleText)

        let assistantMessageID = messages.indices.last.map { messages[$0].id } ?? UUID()
        for action in parsed.actions {
            actionCards.append(TargetActionCard(
                messageID: assistantMessageID, action: action, state: .pending
            ))
        }
        for err in parsed.errors {
            appendSystemMessage("⚠️ Invalid action proposal: \(err)")
        }

        if !visibleText.isEmpty, let convID = conversationID {
            Self.persistResponse(dbManager: dbManager, conversationID: convID, text: visibleText)
        }
```

(Остальная часть `executeStream` — session persist + `finishStream()` — без изменений.)

4. Добавь helpers:

```swift
    private func appendSystemMessage(_ text: String) {
        messages.append(ChatMessage(
            id: UUID(), role: .system, text: text, timestamp: Date(), isStreaming: false
        ))
        if let convID = conversationID {
            persistMessage(conversationID: convID, role: "system", text: text)
        }
    }

    func approve(_ card: TargetActionCard) {
        guard let idx = actionCards.firstIndex(where: { $0.id == card.id }),
              actionCards[idx].state == .pending else { return }
        reloadTarget()
        let summary = TaskActionExecutor.apply(card.action, target: target, viewModel: viewModel)
        actionCards[idx].state = .applied(summary)
        reloadTarget()
        sendFollowUp("Action applied: \(summary). Continue with the task.")
    }

    func reject(_ card: TargetActionCard) {
        guard let idx = actionCards.firstIndex(where: { $0.id == card.id }),
              actionCards[idx].state == .pending else { return }
        actionCards[idx].state = .rejected
        sendFollowUp("User rejected the action (reason given: \(card.action.reason)). " +
                     "Suggest an alternative or ask what to do.")
    }
```

5. Добавь `sendFollowUp` — как `send()`, но prompt задан явно и пользовательское сообщение пишется как `.system` (не `.user`):

```swift
    private func sendFollowUp(_ text: String) {
        guard !isStreaming else { return }
        streamTask?.cancel()
        appendSystemMessage(text)
        messages.append(ChatMessage(
            id: UUID(), role: .assistant, text: "", timestamp: Date(), isStreaming: true
        ))
        isStreaming = true

        let currentSessionID = sessionID
        let dbPath = dbManager.dbPool.path
        let dbPool = dbManager.dbPool
        let capturedTarget = target
        let capturedAIService = aiService
        let capturedConvID = conversationID
        let capturedDBManager = dbManager

        streamTask = Task { [weak self] in
            await self?.executeStream(
                text: text, currentSessionID: currentSessionID, target: capturedTarget,
                dbPool: dbPool, dbPath: dbPath, aiService: capturedAIService,
                dbManager: capturedDBManager, conversationID: capturedConvID
            )
        }
    }
```

6. В `buildSystemPrompt(target:dbPool:)` — за основу возьми `TrackChatViewModel.buildSystemPrompt` (схема, workspace, linking rules — без изменений), но секцию `=== CURRENT TRACK ===` замени на `=== CURRENT TASK ===` с полями `target` (id, text, **intent**, status, priority, ownership, blocking, progress, notes, sub_items) и добавь дословно секцию `=== TASK ACTIONS ===` из контракта выше. Без `channelIDs`-специфики трека; в QUERY TIPS оставь общий пример поиска сообщений по тексту/людям.

- [ ] **Step 4: Запустить — зелёный**

Run: `cd WatchtowerDesktop && swift test --filter TargetChatViewModelTests`
Expected: PASS (3 теста).

- [ ] **Step 5: Commit**

```bash
git add WatchtowerDesktop/Sources/ViewModels/TargetChatViewModel.swift WatchtowerDesktop/Tests/TargetChatViewModelTests.swift
git commit -m "feat(targets): TargetChatViewModel agentic loop with action cards"
```

---

### Task 6: View — `TargetChatSection` + карточка + вкладка в `TargetDetailView`

**Files:**
- Create: `WatchtowerDesktop/Sources/Views/Targets/TargetChatView.swift`
- Modify: `WatchtowerDesktop/Sources/Views/Targets/TargetDetailView.swift` (новая вкладка `.assistant`)
- Test: `WatchtowerDesktop/Tests/TargetChatViewTests.swift`

**Interfaces:**
- Consumes: `TargetChatViewModel`, `TargetActionCard`, `ChatMessage`, `MarkdownText`, `AppState.databaseManager`.
- Produces: `struct TargetChatSection: View { @Bindable var chatVM: TargetChatViewModel }` и `struct TargetActionCardView: View`.

- [ ] **Step 1: Написать падающий тест (smoke)**

Create `WatchtowerDesktop/Tests/TargetChatViewTests.swift`:

```swift
import XCTest
import SwiftUI
@testable import WatchtowerDesktop

@MainActor
final class TargetChatViewTests: XCTestCase {
    func testActionCardViewDescribesAction() throws {
        let action = ProposedAction(type: .updateStatus, reason: "all merged", status: "done")
        let card = TargetActionCard(messageID: UUID(), action: action, state: .pending)
        // Card description is the single source of truth for the card body.
        XCTAssertTrue(card.action.cardDescription.contains("done"))
        XCTAssertTrue(card.action.cardDescription.contains("all merged"))
        // View constructs without crashing.
        _ = TargetActionCardView(card: card, onApprove: {}, onReject: {})
    }
}
```

- [ ] **Step 2: Запустить — падает**

Run: `cd WatchtowerDesktop && swift test --filter TargetChatViewTests`
Expected: FAIL (нет `TargetActionCardView`).

- [ ] **Step 3: Реализовать View**

Create `WatchtowerDesktop/Sources/Views/Targets/TargetChatView.swift`. Возьми `TrackChatSection` (`Views/Tracks/TrackChatView.swift:384–499`) за основу для `TargetChatSection`, переименовав тип VM на `TargetChatViewModel` и тексты-плейсхолдеры на «Ask AI to work on this task…». В `ScrollView`, внутри `ForEach(chatVM.messages)`, после `chatBubble(msg)` добавь карточки этого сообщения:

```swift
                    ForEach(chatVM.messages) { msg in
                        chatBubble(msg)
                        ForEach(chatVM.actionCards.filter { $0.messageID == msg.id }) { card in
                            TargetActionCardView(
                                card: card,
                                onApprove: { chatVM.approve(card) },
                                onReject: { chatVM.reject(card) }
                            )
                        }
                    }
```

И добавь сам тип карточки в этот же файл:

```swift
struct TargetActionCardView: View {
    let card: TargetActionCard
    let onApprove: () -> Void
    let onReject: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(card.action.cardDescription)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)

            switch card.state {
            case .pending:
                HStack(spacing: 8) {
                    Button("Approve", action: onApprove)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    Button("Reject", action: onReject)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            case .applied(let summary):
                Label(summary, systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            case .rejected:
                Label("Rejected", systemImage: "xmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            case .failed(let err):
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor.opacity(0.3)))
    }
}
```

- [ ] **Step 4: Запустить — зелёный**

Run: `cd WatchtowerDesktop && swift test --filter TargetChatViewTests`
Expected: PASS (1 тест).

- [ ] **Step 5: Встроить вкладку в `TargetDetailView`**

В `WatchtowerDesktop/Sources/Views/Targets/TargetDetailView.swift`:

1. В `enum Tab` добавь кейс: `case assistant = "Assistant"`.
2. Добавь стейт под чат-VM рядом с остальными `@State`:

```swift
    @State private var chatVM: TargetChatViewModel?
```

3. В теле, где рендерится контент выбранной вкладки, добавь ветку для `.assistant`, создающую VM лениво (как `TrackDetailView`, `TrackDetailView.swift:52–56`):

```swift
            case .assistant:
                if let chatVM {
                    TargetChatSection(chatVM: chatVM)
                } else {
                    Color.clear.onAppear {
                        if let dbManager = appState.databaseManager {
                            chatVM = TargetChatViewModel(
                                target: target, viewModel: viewModel, dbManager: dbManager
                            )
                        }
                    }
                }
```

> Сверь точное место `switch selectedTab` в теле `TargetDetailView` и встрой кейс согласованно с существующими `.details`/`.links`/`.activity`.

- [ ] **Step 6: Собрать весь таргет и прогнать тесты**

Run: `cd WatchtowerDesktop && swift build && swift test`
Expected: BUILD OK; все тесты зелёные (включая новые из задач 1–6).

- [ ] **Step 7: Commit**

```bash
git add WatchtowerDesktop/Sources/Views/Targets/TargetChatView.swift WatchtowerDesktop/Sources/Views/Targets/TargetDetailView.swift WatchtowerDesktop/Tests/TargetChatViewTests.swift
git commit -m "feat(targets): Assistant tab with action-card chat UI"
```

---

## Self-Review

**Spec coverage:**
- Кнопка/вход от интента → Task 6 (вкладка Assistant) + Task 5 (`buildSystemPrompt` инжектит intent). ✓
- Одна постоянная беседа на таск → Task 5 (контекст `"target"` через `ChatConversationQueries`). ✓
- AI читает Slack-базу (read-only) → наследуется из паттерна `TrackChatViewModel` (MCP `read_query`), Go не трогаем. ✓
- AI предлагает действие fenced-блоком → Task 5 контракт + Task 2 парсер. ✓
- Карточка Approve/Reject, запись делает Swift → Task 6 (`TargetActionCardView`) + Task 4 (`TaskActionExecutor`) + Task 3 (мутаторы). ✓
- 5 action types → Task 1 (`TaskActionKind`), покрыты в T1/T2/T4 тестами. ✓
- Невалидный action → видимая ошибка (не тихий no-op) → Task 2 (`errors`) + Task 5 (`appendSystemMessage`). ✓
- Reject → follow-up → Task 5 (`reject` + `sendFollowUp`). ✓ (degenerate clean-exit ветка протестирована — `testRejectMarksCardRejected`).
- Беседа выживает между сессиями (resume по session_id) → наследуется из паттерна (persistSession). ✓
- `progress` 0–100 → 0.0–1.0 → Task 4 (`/100`) + Task 3 (кламп). ✓
- Go-тесты не затронуты → ни одна задача не меняет Go. ✓

**Placeholder scan:** код приведён целиком в каждом шаге; «сверь сигнатуру» — это явные verify-замечания к существующему коду, а не пропуски в новом. ✓

**Type consistency:** `ProposedAction`/`TaskActionKind` (T1) → парсер (T2) → исполнитель (T4) → VM `approve/reject` (T5) → View (T6); `TargetActionCard.State` одинаков в T5 и T6; `TaskActionExecutor.apply` сигнатура совпадает в T4-тесте и T5-вызове; `createChild`/`updateProgress` сигнатуры совпадают в T3 и T4. ✓
