import Foundation

/// Why a folder write did not land (spec "Writes: CLI only"). The Desktop
/// never retries one by itself.
package enum InboxFoldersCLIError: Error, Equatable, LocalizedError {
    /// The revision race was lost ("the Inbox menu changed"): re-read the
    /// tree and say so; nothing was written.
    case menuChanged
    /// The CLI refused the write; its message without cobra's "Error: ".
    case refused(String)
    /// No `watchtower` binary: every edit is off, reading still works.
    case cliUnavailable
    /// The CLI answered without the pinned JSON: never taken as success.
    case unexpectedAnswer

    /// The phrase of Go's `ErrRevisionConflict` that marks a lost race.
    package static let conflictPhrase = "the Inbox menu changed"

    package var errorDescription: String? {
        switch self {
        case .menuChanged: "The menu changed — reloaded. Drag again if needed."
        case let .refused(message): message
        case .cliUnavailable: "The watchtower CLI isn't available"
        case .unexpectedAnswer: "Unexpected answer from watchtower"
        }
    }
}

/// The Desktop's only write path to the Inbox menu: `watchtower inbox
/// folders …` (cmd/inbox_folders.go), one method per verb, each decoding the
/// pinned `--json` keys of the last stdout line. Every write carries the
/// revision the caller read (`--expect-revision`). Errors are always an
/// `InboxFoldersCLIError`.
package struct InboxFoldersCLI {
    /// One call: the tree read, or a write at the revision the caller read.
    package enum Operation: Equatable, Sendable {
        case list
        case write(Write, expectRevision: Int64)
    }

    /// The five folder writes (cmd/inbox_folders.go); nil leaves a field as
    /// it is, or to the CLI's default.
    package enum Write: Equatable, Sendable {
        case create(title: String, icon: String?, parent: Int64?, position: Int?)
        case update(Int64, title: String?, icon: String?, visibility: Visibility?)
        case move(Int64, parent: Int64, position: Int)
        case delete(Int64)
        case route(automationID: Int64, to: RouteDestination)
    }

    /// `update --hidden=true|false`.
    package enum Visibility: Equatable, Sendable {
        case hidden, shown
    }

    /// Where `route` sends an automation: an existing folder, or a new one
    /// created in the same transaction.
    package enum RouteDestination: Equatable, Sendable {
        case folder(Int64)
        case newFolder(title: String, icon: String?, parent: Int64?)
    }

    private let runner: (any CLIRunnerProtocol)?

    /// `runner` nil = no binary was found (`ProcessCLIRunner.makeDefault()`).
    package init(runner: (any CLIRunnerProtocol)?) {
        self.runner = runner
    }

    package static func args(_ operation: Operation) -> [String] {
        switch operation {
        case .list:
            return ["inbox", "folders", "list", "--json"]
        case let .write(write, revision):
            return ["inbox", "folders"] + args(write) + ["--expect-revision", String(revision), "--json"]
        }
    }

    private static func args(_ write: Write) -> [String] {
        switch write {
        case let .create(title, icon, parent, position):
            return ["create", "--title", title] + flag("--icon", icon) + flag("--parent", parent.map(String.init))
                + flag("--position", position.map(String.init))
        case let .update(id, title, icon, visibility):
            var out = ["update", String(id)] + flag("--title", title) + flag("--icon", icon)
            if let visibility { out.append("--hidden=\(visibility == .hidden)") }
            return out
        case let .move(id, parent, position):
            return ["move", String(id), "--parent", String(parent), "--position", String(position)]
        case let .delete(id):
            return ["delete", String(id)]
        case let .route(automationID, .folder(id)):
            return ["route", String(automationID), "--folder", String(id)]
        case let .route(automationID, .newFolder(title, icon, parent)):
            return ["route", String(automationID), "--new-title", title] + flag("--new-icon", icon)
                + flag("--parent", parent.map(String.init))
        }
    }

    private static func flag(_ name: String, _ value: String?) -> [String] {
        value.map { [name, $0] } ?? []
    }

    package func list() async throws -> ListResult { try await call(.list) }

    package func create(
        title: String,
        icon: String? = nil,
        parent: Int64? = nil,
        position: Int? = nil,
        expectRevision: Int64
    ) async throws -> WriteResult {
        try await call(.write(.create(title: title, icon: icon, parent: parent, position: position),
                              expectRevision: expectRevision))
    }

    package func update(
        _ id: Int64,
        title: String? = nil,
        icon: String? = nil,
        visibility: Visibility? = nil,
        expectRevision: Int64
    ) async throws -> WriteResult {
        try await call(.write(.update(id, title: title, icon: icon, visibility: visibility),
                              expectRevision: expectRevision))
    }

    package func move(_ id: Int64, parent: Int64, position: Int, expectRevision: Int64) async throws -> WriteResult {
        try await call(.write(.move(id, parent: parent, position: position), expectRevision: expectRevision))
    }

    package func delete(_ id: Int64, expectRevision: Int64) async throws -> DeleteResult {
        try await call(.write(.delete(id), expectRevision: expectRevision))
    }

    package func route(
        automationID: Int64,
        to destination: RouteDestination,
        expectRevision: Int64
    ) async throws -> RouteResult {
        try await call(.write(.route(automationID: automationID, to: destination), expectRevision: expectRevision))
    }

    private func call<T: Decodable>(_ operation: Operation) async throws -> T {
        guard let runner else { throw InboxFoldersCLIError.cliUnavailable }
        let data: Data
        do {
            data = try await runner.run(args: Self.args(operation))
        } catch {
            throw Self.map(error)
        }
        return try Self.decodeLastLine(data)
    }

    /// A runner failure as the menu shows it.
    package static func map(_ error: any Error) -> InboxFoldersCLIError {
        switch error {
        case let error as InboxFoldersCLIError:
            return error
        case CLIRunnerError.binaryNotFound:
            return .cliUnavailable
        case let CLIRunnerError.nonZeroExit(code, stderr):
            if stderr.contains(InboxFoldersCLIError.conflictPhrase) { return .menuChanged }
            let message = stripErrorLead(stderr)
            return .refused(message.isEmpty ? "watchtower exited with code \(code)" : message)
        default:
            return .refused(error.localizedDescription)
        }
    }

    /// The CLI's message without cobra's "Error: " lead and the trailing newline.
    package static func stripErrorLead(_ stderr: String) -> String {
        let text = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let lead = "Error: "
        return text.hasPrefix(lead) ? String(text.dropFirst(lead.count)) : text
    }

    /// `--json` prints one object as the last stdout line; anything that is
    /// not one with every pinned key is `.unexpectedAnswer`.
    package static func decodeLastLine<T: Decodable>(_ data: Data) throws -> T {
        guard let text = String(bytes: data, encoding: .utf8),
              let line = text.split(whereSeparator: \.isNewline)
                  .last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        else { throw InboxFoldersCLIError.unexpectedAnswer }
        do {
            return try JSONDecoder().decode(T.self, from: Data(line.utf8))
        } catch {
            throw InboxFoldersCLIError.unexpectedAnswer
        }
    }
}

// MARK: - Results (the pinned `--json` keys)

extension InboxFoldersCLI {
    /// A folder object: `id`, `kind`, `slug`, `title`, `icon`, `parent_id`
    /// (present, null for the root), `position`, `hidden`, `automation_ids`.
    package struct Folder: Decodable, Equatable, Sendable {
        package let folder: InboxFolder
        package let automationIDs: [Int64]

        package init(folder: InboxFolder, automationIDs: [Int64] = []) {
            self.folder = folder
            self.automationIDs = automationIDs
        }

        enum CodingKeys: String, CodingKey {
            case id, kind, slug, title, icon, position, hidden
            case parentID = "parent_id", automationIDs = "automation_ids"
        }

        package init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // `parent_id` is pinned: absent is not the root's null.
            guard c.contains(.parentID) else {
                throw DecodingError.keyNotFound(CodingKeys.parentID, .init(codingPath: c.codingPath, debugDescription: "pinned"))
            }
            let kindRaw = try c.decode(String.self, forKey: .kind)
            guard let kind = InboxFolder.Kind(rawValue: kindRaw) else {
                throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "unknown kind \(kindRaw)")
            }
            folder = InboxFolder(
                id: try c.decode(Int64.self, forKey: .id), kind: kind,
                parentID: try c.decodeNil(forKey: .parentID) ? nil : try c.decode(Int64.self, forKey: .parentID),
                slug: try c.decode(String.self, forKey: .slug), title: try c.decode(String.self, forKey: .title),
                icon: try c.decode(String.self, forKey: .icon), position: try c.decode(Int.self, forKey: .position),
                hidden: try c.decode(Bool.self, forKey: .hidden)
            )
            automationIDs = try c.decode([Int64].self, forKey: .automationIDs)
        }
    }

    /// `list --json`: `revision`, `folders` (pre-order).
    package struct ListResult: Decodable, Equatable, Sendable {
        package let revision: Int64
        package let folders: [Folder]

        /// The tree the menu draws, routes rebuilt from `automation_ids`.
        package var tree: InboxFolderTree {
            var routes: [Int64: Int64] = [:]
            for folder in folders {
                for automation in folder.automationIDs { routes[automation] = folder.folder.id }
            }
            return InboxFolderTree(revision: revision, folders: folders.map(\.folder), routes: routes)
        }
    }

    /// `create` / `update` / `move --json`: the new `revision`, the `folder`.
    package struct WriteResult: Decodable, Equatable, Sendable {
        package let revision: Int64
        package let folder: Folder
    }

    /// `delete --json`: the new `revision` and what `moved` up.
    package struct DeleteResult: Decodable, Equatable, Sendable {
        package let revision: Int64
        package let moved: Moved

        package struct Moved: Decodable, Equatable, Sendable {
            package let folders: Int
            package let automations: Int
            package let artifacts: Int
            package let renamed: [Renamed]
        }

        /// A moved child renamed to keep its new siblings' titles unique.
        package struct Renamed: Decodable, Equatable, Sendable {
            package let id: Int64
            package let from: String
            package let to: String
        }
    }

    /// `route --json`: the new `revision`, the automation, its `folder` and
    /// whether that folder was `created` by this call.
    package struct RouteResult: Decodable, Equatable, Sendable {
        package let revision: Int64
        package let automationID: Int64
        package let folder: Folder
        package let created: Bool

        enum CodingKeys: String, CodingKey {
            case revision, folder, created, automationID = "automation_id"
        }
    }
}
