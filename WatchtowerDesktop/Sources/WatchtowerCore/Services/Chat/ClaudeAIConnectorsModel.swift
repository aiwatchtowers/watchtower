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
    /// The last read or write failure; a failed write leaves `switches` as they were.
    package var lastError: String?

    /// Called after a switch was written.
    @ObservationIgnored package var onSwitched: (() -> Void)?

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

    /// Whether the owner's switch for this connector is on (the master
    /// switch is separate: `switches.connectors`).
    package func isEnabled(_ name: String) -> Bool { !switches.disabled.contains(name) }

    /// Re-reads the list and the switches. A failed read keeps what was shown
    /// and reports it.
    package func reload() {
        var errors: [String] = []
        do {
            file = try filePath().flatMap { try ClaudeAIConnectorsFile.read(at: $0) }
        } catch {
            errors.append("Couldn't read the claude.ai connector list: \(error.localizedDescription)")
        }
        do {
            switches = try ClaudeAIConnectorSwitches.read(configPath: configPath)
        } catch {
            errors.append("Couldn't read the claude.ai switches: \(error.localizedDescription)")
        }
        lastError = errors.isEmpty ? nil : errors.joined(separator: "\n")
    }

    /// `ai.claude_ai.connectors`: every connector on or off at once.
    package func setAllEnabled(_ on: Bool) async {
        await serialized {
            guard await self.write(key: "ai.claude_ai.connectors", value: on ? "true" : "false") else { return }
            self.switches.connectors = on
        }
    }

    /// `ai.claude_ai.disabled_connectors`: one connector on or off. The list
    /// is re-read from disk right before the write, so a name switched off
    /// elsewhere (or no longer listed) is kept, and written sorted.
    package func setEnabled(name: String, _ on: Bool) async {
        await serialized {
            // `config set` splits the value on commas: such a name can't be stored.
            guard !name.contains(",") else {
                self.lastError = "\"\(name)\" has a comma in its name, so it can't be switched here."
                return
            }
            let current: ClaudeAIConnectorSwitches
            do {
                current = try ClaudeAIConnectorSwitches.read(configPath: self.configPath)
            } catch {
                self.lastError = "Couldn't read the claude.ai switches: \(error.localizedDescription)"
                return
            }
            var disabled = Set(current.disabled)
            if on { disabled.remove(name) } else { disabled.insert(name) }
            let sorted = disabled.sorted()
            guard await self.write(key: "ai.claude_ai.disabled_connectors",
                                   value: sorted.joined(separator: ",")) else { return }
            self.switches = ClaudeAIConnectorSwitches(connectors: current.connectors, disabled: sorted)
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

    /// One `config set`; on success clears the error and calls `onSwitched`.
    private func write(key: String, value: String) async -> Bool {
        isWriting = true
        defer { isWriting = false }
        do {
            guard let runner = cliRunner ?? ProcessCLIRunner.makeDefault() else { throw CLIRunnerError.binaryNotFound }
            _ = try await runner.run(args: ["config", "set", key, value])
        } catch {
            lastError = "Couldn't save the switch: \(error.localizedDescription)"
            return false
        }
        lastError = nil
        onSwitched?()
        return true
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
