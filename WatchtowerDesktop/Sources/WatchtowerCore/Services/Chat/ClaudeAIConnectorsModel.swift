import Foundation

/// Settings → Profile → claude.ai tools (#737, spec D2): the account's
/// connectors as the main chat's last session listed them, and the owner's
/// switches. Owned by `AppState`, so a write in flight survives closing
/// Settings. Switches are written through the CLI (`watchtower config set`,
/// the single writer of `ai.claude_ai.*`); a session reads them when it
/// starts, so a successful write calls `onSwitched` (the chat pool's
/// `retireIdleSessions`) and the next turn starts a session with the new
/// set. Embedded chats never get these tools (v1, decision Q2).
@MainActor
@Observable
package final class ClaudeAIConnectorsModel {
    /// The last list read; nil when there is none yet or it could not be read.
    package private(set) var file: ClaudeAIConnectorsFile?
    package private(set) var switches = ClaudeAIConnectorSwitches()
    package private(set) var isWriting = false
    /// Why the list or the switches could not be read; reset by each read.
    package private(set) var readError: String?
    /// Why the last switch was not saved; kept until a switch is saved, so
    /// it is still there when Settings is opened again.
    package private(set) var writeError: String?

    /// Called after a switch was written.
    @ObservationIgnored package var onSwitched: (() -> Void)?

    /// `config set` is quick; a CLI that hangs becomes a shown error.
    package static let writeTimeout: TimeInterval = 30

    @ObservationIgnored private let filePath: () -> String?
    @ObservationIgnored private let configPath: String
    @ObservationIgnored private let cliRunner: CLIRunnerProtocol?
    /// Writes run one after another, each from the state the previous one left.
    @ObservationIgnored private var lastWrite: Task<Void, Never>?

    /// `filePath` is resolved on every read: the active workspace (and so the
    /// database's directory) can change while the app runs.
    package init(
        filePath: @escaping () -> String?,
        configPath: String = Constants.configPath,
        cliRunner: CLIRunnerProtocol? = nil
    ) {
        self.filePath = filePath
        self.configPath = configPath
        self.cliRunner = cliRunner
    }

    package var servers: [ClaudeAIConnectorsFile.Server] { file?.servers ?? [] }

    /// Whether the owner's own switch for this connector is on.
    package func isEnabled(_ name: String) -> Bool { !switches.isDisabled(name) }

    /// Whether the next chat turn gets this connector: both switches on.
    package func isActive(_ name: String) -> Bool { switches.connectors && isEnabled(name) }

    /// Re-reads the list and the switches. A failed read keeps what was shown
    /// and reports it.
    package func reload() {
        var errors: [String] = []
        do {
            file = try filePath().flatMap { try ClaudeAIConnectorsFile.read(at: $0) }
        } catch {
            errors.append(Self.logged("Couldn't read the claude.ai connector list: \(error.localizedDescription)"))
        }
        do {
            switches = try ClaudeAIConnectorSwitches.read(configPath: configPath)
        } catch {
            errors.append(Self.logged("Couldn't read the claude.ai switches: \(error.localizedDescription)"))
        }
        readError = errors.isEmpty ? nil : errors.joined(separator: "\n")
    }

    /// `ai.claude_ai.connectors`: every connector on or off at once.
    package func setAllEnabled(_ on: Bool) async {
        await serialized {
            guard var current = self.currentSwitches(),
                  await self.write(key: "ai.claude_ai.connectors", value: on ? "true" : "false") else { return }
            current.connectors = on
            self.switches = current
        }
    }

    /// `ai.claude_ai.disabled_connectors`: one connector on or off. The list
    /// is re-read from disk right before the write, so a name switched off
    /// elsewhere (or no longer listed) is kept, and written sorted.
    package func setEnabled(name: String, _ on: Bool) async {
        await serialized {
            // `config set` splits the value on commas: such a name can't be stored.
            guard !name.contains(",") else {
                self.writeError = "\"\(name)\" has a comma in its name, so it can't be switched here."
                return
            }
            guard var current = self.currentSwitches() else { return }
            let disabled = current.disabling(name, !on)
            guard await self.write(key: "ai.claude_ai.disabled_connectors",
                                   value: disabled.joined(separator: ",")) else { return }
            current.disabled = disabled
            self.switches = current
        }
    }

    // MARK: - Private

    private func serialized(_ body: @escaping @MainActor () async -> Void) async {
        let previous = lastWrite
        let task = Task { @MainActor in
            await previous?.value
            await body()
        }
        lastWrite = task
        await task.value
    }

    /// The switches on disk now, for a read-modify-write; nil (and the
    /// error shown) when they can't be read.
    private func currentSwitches() -> ClaudeAIConnectorSwitches? {
        do {
            return try ClaudeAIConnectorSwitches.read(configPath: configPath)
        } catch {
            writeError = Self.logged("Couldn't read the claude.ai switches: \(error.localizedDescription)")
            return nil
        }
    }

    /// One `config set`; on success clears the write error and calls `onSwitched`.
    private func write(key: String, value: String) async -> Bool {
        isWriting = true
        defer { isWriting = false }
        do {
            guard let runner = cliRunner ?? ProcessCLIRunner.makeDefault() else { throw CLIRunnerError.binaryNotFound }
            _ = try await runner.run(args: ["config", "set", key, value], timeout: Self.writeTimeout)
        } catch {
            writeError = Self.logged("Couldn't save the switch: \(error.localizedDescription)")
            return false
        }
        writeError = nil
        onSwitched?()
        return true
    }

    /// House style: a plain tagged print beside the message the owner sees.
    private static func logged(_ message: String) -> String {
        print("[ClaudeAIConnectors] \(message)")
        return message
    }
}

extension ClaudeAIConnectorsModel {
    /// A row's status. The list is what the last session saw, so a switch
    /// changed since then speaks for the next turn.
    package nonisolated static func statusText(_ status: ClaudeAIConnectorsFile.Status, switchedOn: Bool) -> String {
        guard switchedOn else { return "Off" }
        switch status {
        case .connected: return "Connected"
        case .needsAuth: return "Not connected"
        case .failed: return "Failed to connect"
        case .pending: return "Connecting"
        case .disabled: return "On from the next chat turn"
        }
    }

    /// The tools with the hints their connector declares, e.g.
    /// "search (read-only) · send · delete (destructive)".
    package nonisolated static func toolsText(_ tools: [ClaudeAIConnectorsFile.Tool]) -> String {
        tools.map { tool in
            let hints = [tool.readOnly ? "read-only" : nil, tool.destructive ? "destructive" : nil]
                .compactMap { $0 }
            return hints.isEmpty ? tool.name : "\(tool.name) (\(hints.joined(separator: ", ")))"
        }
        .joined(separator: " · ")
    }
}
