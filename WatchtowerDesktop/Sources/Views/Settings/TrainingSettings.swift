import SwiftUI
import GRDB

struct TrainingSettings: View {
    @Environment(AppState.self) private var appState
    @State private var prompts: [PromptTemplate] = []
    @State private var feedbackStats: [FeedbackStats] = []
    @State private var selectedPromptID: String?
    @State private var isLoading = true
    @State private var isTuning = false
    @State private var tuneOutput: String = ""
    @State private var tuneError: String?
    @State private var showTuneOutput = false

    var body: some View {
        HSplitView {
            // Left: prompt list + feedback stats
            sidebar
                .frame(minWidth: 200, idealWidth: 220, maxWidth: 280)

            // Right: prompt detail/editor
            if let id = selectedPromptID, let prompt = prompts.first(where: { $0.id == id }) {
                PromptDetailPane(prompt: prompt, dbManager: appState.databaseManager) {
                    reload()
                }
            } else {
                VStack {
                    Spacer()
                    Text("Select a prompt to view or edit")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear { reload() }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Feedback stats
            feedbackStatsSection
                .padding()

            // Tune button
            tuneSection
                .padding(.horizontal)
                .padding(.bottom)

            Divider()

            // Prompt list
            if isLoading {
                VStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            } else if prompts.isEmpty {
                VStack {
                    Spacer()
                    Text("No prompts yet.\nRun a sync to seed defaults.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                    Spacer()
                }
            } else {
                List(prompts, selection: $selectedPromptID) { prompt in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(promptLabel(prompt.id))
                            .font(.subheadline)
                            .fontWeight(.medium)
                        HStack(spacing: 6) {
                            Text("v\(prompt.version)")
                                .font(.caption2)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(.blue.opacity(0.15), in: Capsule())
                            Text(prompt.language)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                    .tag(prompt.id)
                }
                .listStyle(.sidebar)
            }
        }
    }

    // MARK: - Feedback Stats

    private var feedbackStatsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Feedback")
                .font(.headline)

            if feedbackStats.isEmpty {
                Text("No feedback yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(feedbackStats, id: \.entityType) { stat in
                    HStack {
                        Text(feedbackTypeLabel(stat.entityType))
                            .font(.caption)
                        Spacer()
                        HStack(spacing: 6) {
                            Label("\(stat.positive)", systemImage: "hand.thumbsup.fill")
                                .font(.caption2)
                                .foregroundStyle(.green)
                            Label("\(stat.negative)", systemImage: "hand.thumbsdown.fill")
                                .font(.caption2)
                                .foregroundStyle(.red)
                        }
                    }
                }

                let totalPositive = feedbackStats.reduce(0) { $0 + $1.positive }
                let totalNegative = feedbackStats.reduce(0) { $0 + $1.negative }
                let total = totalPositive + totalNegative
                if total > 0 {
                    Divider()
                    HStack {
                        Text("Quality")
                            .font(.caption)
                            .fontWeight(.medium)
                        Spacer()
                        Text("\(totalPositive * 100 / total)%")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(totalPositive * 100 / total >= 70 ? .green : .orange)
                    }
                }
            }
        }
    }

    // MARK: - Tune

    private var tuneSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                runTune()
            } label: {
                HStack(spacing: 4) {
                    if isTuning {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "wand.and.stars")
                    }
                    Text(isTuning ? "Tuning…" : "Run Tuning")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(isTuning || feedbackStats.isEmpty)
            .help("Analyze feedback and auto-improve prompt templates")

            if let err = tuneError {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }

            if !tuneOutput.isEmpty {
                Button("Show Output") {
                    showTuneOutput = true
                }
                .buttonStyle(.plain)
                .font(.caption2)
                .foregroundStyle(.blue)
            }
        }
        .sheet(isPresented: $showTuneOutput) {
            TuneOutputSheet(output: tuneOutput)
        }
    }

    private func runTune() {
        guard let cliPath = Constants.findCLIPath() else {
            tuneError = "watchtower binary not found"
            return
        }

        isTuning = true
        tuneError = nil
        tuneOutput = ""

        Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: cliPath)
            process.arguments = ["tune", "--apply"]

            process.environment = ProcessInfo.processInfo.environment

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            do {
                try process.run()
                process.waitUntilExit()

                let outData = stdout.fileHandleForReading.readDataToEndOfFile()
                let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                let outStr = String(data: outData, encoding: .utf8) ?? ""
                let errStr = String(data: errData, encoding: .utf8) ?? ""

                await MainActor.run {
                    if process.terminationStatus == 0 {
                        tuneOutput = outStr
                        tuneError = nil
                    } else {
                        tuneOutput = outStr
                        tuneError = errStr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? "Tuning failed (exit code \(process.terminationStatus))"
                            : String(errStr.prefix(200))
                    }
                    isTuning = false
                    reload()
                }
            } catch {
                await MainActor.run {
                    tuneError = error.localizedDescription
                    isTuning = false
                }
            }
        }
    }

    // MARK: - Helpers

    private func reload() {
        guard let db = appState.databaseManager else {
            isLoading = false
            return
        }
        Task.detached {
            let loadedPrompts = (try? await db.dbPool.read { db in
                try PromptQueries.fetchAll(db)
            }) ?? []
            let loadedStats = (try? await db.dbPool.read { db in
                try FeedbackQueries.getStats(db)
            }) ?? []
            await MainActor.run {
                prompts = loadedPrompts
                feedbackStats = loadedStats
                if selectedPromptID == nil, let first = loadedPrompts.first {
                    selectedPromptID = first.id
                }
                isLoading = false
            }
        }
    }

    private func promptLabel(_ id: String) -> String {
        let labels: [String: String] = [
            "digest.channel": "Channel Digest",
            "digest.daily": "Daily Rollup",
            "digest.weekly": "Weekly Summary",
            "digest.period": "Period Summary",
            "actionitems.extract": "Action Items Extract",
            "actionitems.update": "Action Items Update",
            "analysis.user": "User Analysis",
            "analysis.period": "Period Analysis",
        ]
        return labels[id] ?? id
    }

    private func feedbackTypeLabel(_ type: String) -> String {
        switch type {
        case "digest": return "Digests"
        case "action_item": return "Actions"
        case "decision": return "Decisions"
        default: return type.capitalized
        }
    }
}

// MARK: - Prompt Detail Pane

struct PromptDetailPane: View {
    let prompt: PromptTemplate
    let dbManager: DatabaseManager?
    let onSave: () -> Void

    @State private var editedTemplate: String = ""
    @State private var history: [PromptHistoryEntry] = []
    @State private var isEditing = false
    @State private var saveError: String?
    @State private var showHistory = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(prompt.id)
                        .font(.headline)
                    HStack(spacing: 8) {
                        Text("Version \(prompt.version)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(prompt.language)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(prompt.updatedAt)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer()

                Button {
                    showHistory.toggle()
                } label: {
                    Label("History", systemImage: "clock.arrow.circlepath")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                if isEditing {
                    Button("Cancel") {
                        isEditing = false
                        editedTemplate = prompt.template
                        saveError = nil
                    }
                    .controlSize(.small)

                    Button("Save") {
                        savePrompt()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                } else {
                    Button("Edit") {
                        editedTemplate = prompt.template
                        isEditing = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding()

            if let err = saveError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }

            Divider()

            // Content
            if isEditing {
                TextEditor(text: $editedTemplate)
                    .font(.system(.caption, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(8)
            } else {
                ScrollView {
                    Text(prompt.template)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            }
        }
        .sheet(isPresented: $showHistory) {
            PromptHistorySheet(promptID: prompt.id, dbManager: dbManager)
        }
        .onChange(of: prompt.id) {
            isEditing = false
            saveError = nil
        }
    }

    private func savePrompt() {
        guard let db = dbManager else { return }
        do {
            try db.dbPool.write { database in
                try database.execute(
                    sql: """
                        INSERT INTO prompt_history (prompt_id, version, template, reason)
                        SELECT id, version, template, 'manual edit' FROM prompts WHERE id = ?
                        """,
                    arguments: [prompt.id]
                )
                try database.execute(
                    sql: """
                        UPDATE prompts SET template = ?, version = version + 1, updated_at = datetime('now')
                        WHERE id = ?
                        """,
                    arguments: [editedTemplate, prompt.id]
                )
            }
            isEditing = false
            saveError = nil
            onSave()
        } catch {
            saveError = error.localizedDescription
        }
    }
}

// MARK: - Prompt History Sheet

struct PromptHistorySheet: View {
    let promptID: String
    let dbManager: DatabaseManager?
    @Environment(\.dismiss) private var dismiss
    @State private var history: [PromptHistoryEntry] = []
    @State private var selectedEntry: PromptHistoryEntry?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Version History — \(promptID)")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            if history.isEmpty {
                VStack {
                    Spacer()
                    Text("No version history")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                HSplitView {
                    List(history, selection: Binding(
                        get: { selectedEntry?.id },
                        set: { id in selectedEntry = history.first { $0.id == id } }
                    )) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text("v\(entry.version)")
                                    .fontWeight(.medium)
                                Spacer()
                                Text(entry.reason)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text(entry.createdAt)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 2)
                        .tag(entry.id)
                    }
                    .listStyle(.sidebar)
                    .frame(minWidth: 180, maxWidth: 220)

                    if let entry = selectedEntry {
                        ScrollView {
                            Text(entry.template)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding()
                        }
                    } else {
                        VStack {
                            Spacer()
                            Text("Select a version")
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .frame(width: 700, height: 500)
        .onAppear { loadHistory() }
    }

    private func loadHistory() {
        guard let db = dbManager else { return }
        history = (try? db.dbPool.read { db in
            try PromptQueries.fetchHistory(db, promptID: promptID)
        }) ?? []
        selectedEntry = history.first
    }
}

// MARK: - Tune Output Sheet

struct TuneOutputSheet: View {
    let output: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Tuning Results")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            ScrollView {
                Text(output)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        }
        .frame(width: 600, height: 400)
    }
}
