import SwiftUI
import GRDB

struct TrainingView: View {
    @Environment(AppState.self) private var appState
    @State private var prompts: [PromptTemplate] = []
    @State private var feedbackStats: [FeedbackStats] = []
    @State private var recentFeedback: [Feedback] = []
    @State private var selectedPromptID: PromptID?
    @State private var isLoading = true
    @State private var isTuning = false
    @State private var tuneOutput: String = ""
    @State private var tuneError: String?
    @State private var showTuneOutput = false

    private var totalFeedback: Int { feedbackStats.reduce(0) { $0 + $1.total } }
    private var totalPositive: Int { feedbackStats.reduce(0) { $0 + $1.positive } }
    private var totalNegative: Int { feedbackStats.reduce(0) { $0 + $1.negative } }
    private var qualityPercent: Int { totalFeedback > 0 ? totalPositive * 100 / totalFeedback : 0 }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            header
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 16)

            Divider()

            if isLoading {
                Spacer()
                ProgressView()
                    .controlSize(.large)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 24) {
                        // Dashboard cards
                        dashboardCards
                            .padding(.horizontal, 24)
                            .padding(.top, 20)

                        // Tune section
                        tuneCard
                            .padding(.horizontal, 24)

                        // Prompts grid
                        promptsSection
                            .padding(.horizontal, 24)
                            .padding(.bottom, 24)
                    }
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .onAppear { reload() }
        .sheet(isPresented: $showTuneOutput) {
            TuneOutputSheet(output: tuneOutput)
        }
        .sheet(item: $selectedPromptID) { item in
            if let prompt = prompts.first(where: { $0.id == item.id }) {
                PromptEditorSheet(prompt: prompt, dbManager: appState.databaseManager) {
                    reload()
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Training")
                    .font(.title)
                    .fontWeight(.bold)
                Text("Fine-tune AI prompts based on your feedback")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()

            Button {
                reload()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.body)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
        }
    }

    // MARK: - Dashboard Cards

    private var dashboardCards: some View {
        HStack(spacing: 16) {
            // Quality score card
            DashboardCard(
                title: "Quality Score",
                gradient: qualityGradient
            ) {
                VStack(spacing: 4) {
                    Text(totalFeedback > 0 ? "\(qualityPercent)%" : "—")
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text(qualityLabel)
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.white.opacity(0.85))
                }
            }

            // Total feedback card
            DashboardCard(
                title: "Total Feedback",
                gradient: Gradient(colors: [Color.blue, Color.cyan])
            ) {
                VStack(spacing: 4) {
                    Text("\(totalFeedback)")
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    HStack(spacing: 12) {
                        Label("\(totalPositive)", systemImage: "hand.thumbsup.fill")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.9))
                        Label("\(totalNegative)", systemImage: "hand.thumbsdown.fill")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.9))
                    }
                }
            }

            // Feedback breakdown card
            DashboardCard(
                title: "By Category",
                gradient: Gradient(colors: [Color.purple, Color.pink])
            ) {
                if feedbackStats.isEmpty {
                    Text("No data yet")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(feedbackStats, id: \.entityType) { stat in
                            HStack {
                                Text(feedbackTypeLabel(stat.entityType))
                                    .font(.caption)
                                    .foregroundStyle(.white)
                                Spacer()
                                CategoryBar(positive: stat.positive, negative: stat.negative)
                                Text("\(stat.positivePercent)%")
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.85))
                                    .frame(width: 30, alignment: .trailing)
                            }
                        }
                    }
                }
            }

            // Prompts card
            DashboardCard(
                title: "Active Prompts",
                gradient: Gradient(colors: [Color.orange, Color.yellow])
            ) {
                VStack(spacing: 4) {
                    Text("\(prompts.count)")
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    let totalVersions = prompts.reduce(0) { $0 + $1.version }
                    Text("\(totalVersions) total versions")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
        }
        .frame(maxHeight: 140)
    }

    private var qualityGradient: Gradient {
        if totalFeedback == 0 {
            return Gradient(colors: [Color.gray, Color.gray.opacity(0.7)])
        }
        if qualityPercent >= 80 {
            return Gradient(colors: [Color.green, Color.mint])
        }
        if qualityPercent >= 60 {
            return Gradient(colors: [Color.yellow, Color.orange])
        }
        return Gradient(colors: [Color.red, Color.orange])
    }

    private var qualityLabel: String {
        if totalFeedback == 0 { return "No feedback" }
        if qualityPercent >= 80 { return "Excellent" }
        if qualityPercent >= 60 { return "Good" }
        if qualityPercent >= 40 { return "Needs work" }
        return "Poor"
    }

    // MARK: - Tune Card

    private var tuneCard: some View {
        HStack(spacing: 16) {
            // Icon
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [.purple, .blue],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 48, height: 48)
                Image(systemName: "wand.and.stars")
                    .font(.title2)
                    .foregroundStyle(.white)
            }

            // Text
            VStack(alignment: .leading, spacing: 2) {
                Text("Auto-Tune Prompts")
                    .font(.headline)
                Text("Analyze feedback patterns and automatically improve prompt templates using AI")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            if let err = tuneError {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .frame(maxWidth: 150)
                    .lineLimit(2)
            }

            if !tuneOutput.isEmpty {
                Button("View Results") {
                    showTuneOutput = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            // Tune button
            Button {
                runTune()
            } label: {
                HStack(spacing: 6) {
                    if isTuning {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(isTuning ? "Tuning..." : "Run Tuning")
                }
                .frame(minWidth: 100)
            }
            .buttonStyle(.borderedProminent)
            .tint(.purple)
            .controlSize(.regular)
            .disabled(isTuning || feedbackStats.isEmpty)
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.purple.opacity(0.2), lineWidth: 1)
        )
    }

    // MARK: - Prompts Section

    private var promptsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Prompt Templates")
                .font(.headline)

            if prompts.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "doc.text")
                            .font(.largeTitle)
                            .foregroundStyle(.tertiary)
                        Text("No prompts yet")
                            .foregroundStyle(.secondary)
                        Text("Run a sync to seed default prompt templates")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(40)
                    Spacer()
                }
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            } else {
                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: 12),
                    GridItem(.flexible(), spacing: 12),
                ], spacing: 12) {
                    ForEach(prompts) { prompt in
                        PromptCard(prompt: prompt) {
                            selectedPromptID = PromptID(id: prompt.id)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Actions

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
            let loadedRecent = (try? await db.dbPool.read { db in
                try FeedbackQueries.getAllFeedback(db, limit: 20)
            }) ?? []
            await MainActor.run {
                prompts = loadedPrompts
                feedbackStats = loadedStats
                recentFeedback = loadedRecent
                isLoading = false
            }
        }
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

// H6 fix: wrapper struct instead of global String: Identifiable conformance
struct PromptID: Identifiable {
    let id: String
}

// MARK: - Dashboard Card

struct DashboardCard<Content: View>: View {
    let title: String
    let gradient: Gradient
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            VStack {
                Spacer()
                content()
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Footer
            HStack {
                Text(title)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white.opacity(0.9))
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.black.opacity(0.15))
        }
        .background(
            LinearGradient(
                gradient: gradient,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
    }
}

// MARK: - Category Bar

struct CategoryBar: View {
    let positive: Int
    let negative: Int

    var body: some View {
        let total = positive + negative
        GeometryReader { geo in
            HStack(spacing: 1) {
                if total > 0 {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(.white.opacity(0.7))
                        .frame(width: geo.size.width * CGFloat(positive) / CGFloat(total))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(.white.opacity(0.25))
                }
            }
        }
        .frame(width: 50, height: 6)
    }
}

// MARK: - Prompt Card

struct PromptCard: View {
    let prompt: PromptTemplate
    let onTap: () -> Void

    private var categoryColor: Color {
        if prompt.id.hasPrefix("digest") { return .blue }
        if prompt.id.hasPrefix("action") { return .orange }
        if prompt.id.hasPrefix("analysis") { return .purple }
        return .gray
    }

    private var categoryLabel: String {
        if prompt.id.hasPrefix("digest") { return "Digest" }
        if prompt.id.hasPrefix("action") { return "Actions" }
        if prompt.id.hasPrefix("analysis") { return "Analysis" }
        return "Other"
    }

    private var promptLabel: String {
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
        return labels[prompt.id] ?? prompt.id
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    // Category badge
                    Text(categoryLabel)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(categoryColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(categoryColor.opacity(0.12), in: Capsule())

                    Spacer()

                    Text("v\(prompt.version)")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Text(promptLabel)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                // Preview of template
                Text(prompt.template.prefix(80) + (prompt.template.count > 80 ? "..." : ""))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: 0)

                HStack {
                    Image(systemName: "globe")
                        .font(.system(size: 9))
                    Text(prompt.language)
                        .font(.caption2)
                    Spacer()
                    Text(formatDate(prompt.updatedAt))
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(categoryColor.opacity(0.15), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func formatDate(_ dateStr: String) -> String {
        // Show relative or short date
        let parts = dateStr.split(separator: " ")
        if let datePart = parts.first {
            return String(datePart)
        }
        return dateStr
    }
}

// MARK: - Prompt Editor Sheet

struct PromptEditorSheet: View {
    let prompt: PromptTemplate
    let dbManager: DatabaseManager?
    let onSave: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var editedTemplate: String = ""
    @State private var isEditing = false
    @State private var saveError: String?
    @State private var history: [PromptHistoryEntry] = []
    @State private var showHistory = false

    private var promptLabel: String {
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
        return labels[prompt.id] ?? prompt.id
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(promptLabel)
                        .font(.title2)
                        .fontWeight(.bold)
                    HStack(spacing: 8) {
                        Text(prompt.id)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.1), in: Capsule())
                        Text("Version \(prompt.version)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(prompt.language)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Button {
                    showHistory = true
                } label: {
                    Label("History", systemImage: "clock.arrow.circlepath")
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

                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
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
        .frame(width: 800, height: 600)
        .sheet(isPresented: $showHistory) {
            PromptHistorySheet(promptID: prompt.id, dbManager: dbManager)
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
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}
