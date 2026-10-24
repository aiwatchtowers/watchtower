import Foundation
import GRDB
import Observation
import WatchtowerCore

/// What the chat shows under an owner message that said "remember: …".
enum RememberMark: Equatable {
    case remembered(lineID: Int64)
    case alreadyPresent
    case full
    case empty
    case undone
    case notFound
    case failed(String)
}

/// The two CLI calls remember-in-place makes (`WorkbenchCLI` in the app, a
/// fake in tests).
protocol RememberCLI: Sendable {
    func remember(text: String, conversationID: Int64, messageID: Int64) async throws -> InstructionRememberResult
    func forget(lineID: Int64) async throws -> Bool
}

extension WorkbenchCLI: RememberCLI {
    func remember(text: String, conversationID: Int64, messageID: Int64) async throws -> InstructionRememberResult {
        try await instructionsRemember(text: text, conversationID: conversationID, messageID: messageID)
    }

    func forget(lineID: Int64) async throws -> Bool {
        try await instructionsForget(lineID: lineID)
    }
}

/// Remember in place: a chat message that starts with a remember prefix is
/// stored as an instruction line by the CLI (the one writer), and the chat
/// shows the outcome under the message. The call runs off the send path, so
/// a slow or failing CLI never delays or blocks the turn.
@MainActor
@Observable
final class RememberCenter {
    /// Bumped after every successful remember or undo, so Settings knows to
    /// reload its Instructions.
    private(set) var revision = 0
    private var marks: [Int64: RememberMark] = [:]

    @ObservationIgnored private let cli: any RememberCLI
    @ObservationIgnored var dbPool: DatabasePool?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []

    init(cli: any RememberCLI, dbPool: DatabasePool? = nil) {
        self.cli = cli
        self.dbPool = dbPool
    }

    func mark(for messageID: Int64) -> RememberMark? { marks[messageID] }

    /// A new owner message is on disk. Only a remember command does anything.
    func ownerMessageSent(text: String, conversationID: Int64, messageID: Int64) {
        guard let rule = RememberCommand.parse(text) else { return }
        if rule.isEmpty {
            marks[messageID] = .empty
            return
        }
        let cli = cli
        tasks.append(Task { [weak self] in
            let mark: RememberMark
            var changed = false
            do {
                let result = try await cli.remember(text: text, conversationID: conversationID, messageID: messageID)
                if result.outcome == "added", let id = result.lineID {
                    mark = .remembered(lineID: id)
                    changed = true
                } else {
                    mark = .alreadyPresent
                }
            } catch let error as OwnerInstructionsError {
                switch error.code {
                case "too_long": mark = .full
                case "empty": mark = .empty
                default: mark = .failed(error.message)
                }
            } catch {
                mark = .failed(error.localizedDescription)
            }
            self?.finish(messageID: messageID, mark: mark, changed: changed)
        })
    }

    /// Removes the line this message added. A line already gone is not an
    /// error: the mark says so.
    func undo(messageID: Int64) async {
        guard case .remembered(let lineID)? = marks[messageID] else { return }
        do {
            marks[messageID] = try await cli.forget(lineID: lineID) ? .undone : .notFound
            revision += 1
        } catch let error as OwnerInstructionsError where error.code == "not_found" {
            marks[messageID] = .notFound
        } catch {
            marks[messageID] = .failed(error.localizedDescription)
        }
    }

    /// Rebuilds `.remembered` for messages the ledger holds a line for (a
    /// reopened conversation). A mark already known is kept.
    func loadMarks(messageIDs: [Int64]) {
        let ids = messageIDs.filter { marks[$0] == nil }
        guard !ids.isEmpty, let dbPool else { return }
        do {
            let lines = try dbPool.read { try InstructionChatLineQueries.forMessages($0, ids: ids) }
            for (messageID, line) in lines { marks[messageID] = .remembered(lineID: line.id) }
        } catch {
            NSLog("RememberCenter: reading the remembered lines failed: %@", error.localizedDescription)
        }
    }

    /// Waits for the calls started so far (tests).
    func waitForIdle() async {
        let pending = tasks
        tasks = []
        for task in pending { await task.value }
    }

    private func finish(messageID: Int64, mark: RememberMark, changed: Bool) {
        marks[messageID] = mark
        if changed { revision += 1 }
    }
}
