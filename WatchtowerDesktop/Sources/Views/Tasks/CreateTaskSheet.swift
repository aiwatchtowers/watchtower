import SwiftUI

struct CreateTaskSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    var prefillText: String = ""
    var prefillIntent: String = ""
    var prefillSourceType: String = "manual"
    var prefillSourceID: String = ""

    @State private var text: String = ""
    @State private var intent: String = ""
    @State private var priority: String = "medium"
    @State private var dueDate: Date?
    @State private var hasDueDate: Bool = false
    @State private var subItems: [TaskSubItem] = []
    @State private var newSubItemText: String = ""
    @State private var errorMessage: String?
    @State private var isGenerating: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader
            Divider()
            formContent
            Divider()
            sheetFooter
        }
        .frame(width: 480, height: 560)
        .onAppear {
            text = prefillText
            intent = prefillIntent
        }
    }

    private var sheetHeader: some View {
        HStack {
            Text("New Task")
                .font(.headline)
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding()
    }

    private var formContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                textField
                aiGenerateButton
                intentField
                priorityRow
                dueDateRow
                checklistSection
                sourceInfo
                errorRow
            }
            .padding()
        }
    }

    private var textField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("What needs to be done?")
                .font(.subheadline)
                .fontWeight(.medium)
            TextField("Task description", text: $text, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
        }
    }

    private var aiGenerateButton: some View {
        HStack {
            Button {
                generateWithAI()
            } label: {
                HStack(spacing: 6) {
                    if isGenerating {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "sparkles")
                    }
                    Text(isGenerating ? "Generating..." : "Generate with AI")
                }
            }
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isGenerating)

            Spacer()

            if isGenerating {
                Text("AI is breaking down the task...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var intentField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Why? (optional)")
                .font(.subheadline)
                .fontWeight(.medium)
            TextField("Context or intent", text: $intent)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var priorityRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Priority")
                .font(.subheadline)
                .fontWeight(.medium)
            Picker("Priority", selection: $priority) {
                Text("High").tag("high")
                Text("Medium").tag("medium")
                Text("Low").tag("low")
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
    }

    private var dueDateRow: some View {
        HStack {
            Toggle("Due date", isOn: $hasDueDate)
                .font(.subheadline)
                .fontWeight(.medium)
            if hasDueDate {
                DatePicker(
                    "",
                    selection: Binding(
                        get: { dueDate ?? Date() },
                        set: { dueDate = $0 }
                    ),
                    displayedComponents: [.date, .hourAndMinute]
                )
                .labelsHidden()
            }
        }
    }

    private var checklistSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Checklist")
                .font(.subheadline)
                .fontWeight(.medium)

            ForEach(Array(subItems.enumerated()), id: \.offset) { index, item in
                HStack(spacing: 8) {
                    Image(systemName: "circle")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    Text(item.text)
                        .font(.callout)
                    Spacer()
                    Button {
                        subItems.remove(at: index)
                    } label: {
                        Image(systemName: "xmark.circle")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 8) {
                Image(systemName: "plus.circle")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                TextField("Add checklist item...", text: $newSubItemText)
                    .font(.callout)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        let trimmed = newSubItemText.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            subItems.append(TaskSubItem(text: trimmed, done: false))
                            newSubItemText = ""
                        }
                    }
            }
        }
    }

    @ViewBuilder
    private var sourceInfo: some View {
        if prefillSourceType != "manual" {
            HStack(spacing: 4) {
                Image(systemName: sourceIcon)
                    .foregroundStyle(.secondary)
                Text("From \(prefillSourceType) #\(prefillSourceID)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var errorRow: some View {
        if let errorMessage {
            Text(errorMessage)
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private var sheetFooter: some View {
        HStack {
            Spacer()
            Button("Create") {
                createTask()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding()
    }

    private var sourceIcon: String {
        switch prefillSourceType {
        case "track": return "binoculars"
        case "digest": return "doc.text.magnifyingglass"
        case "briefing": return "sun.max"
        default: return "square.and.pencil"
        }
    }

    // MARK: - AI Generation

    private func generateWithAI() {
        guard let cliPath = Constants.findCLIPath() else {
            errorMessage = "watchtower binary not found"
            return
        }

        let taskText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !taskText.isEmpty else { return }

        isGenerating = true
        errorMessage = nil

        Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: cliPath)

            var args = ["tasks", "generate", "--text", taskText]
            if prefillSourceType != "manual" && !prefillSourceID.isEmpty {
                args += ["--source-type", prefillSourceType, "--source-id", prefillSourceID]
            }
            process.arguments = args
            process.environment = Constants.resolvedEnvironment()

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            do {
                try process.run()
                process.waitUntilExit()

                let outData = stdout.fileHandleForReading.readDataToEndOfFile()
                let outStr = String(data: outData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                let errStr = String(data: errData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                await MainActor.run {
                    isGenerating = false

                    if process.terminationStatus != 0 {
                        errorMessage = errStr.isEmpty ? "AI generation failed" : errStr
                        return
                    }

                    applyGeneratedResult(outStr)
                }
            } catch {
                await MainActor.run {
                    isGenerating = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func applyGeneratedResult(_ jsonStr: String) {
        guard let data = jsonStr.data(using: .utf8) else {
            errorMessage = "Invalid response from AI"
            return
        }

        struct GeneratedTask: Decodable {
            let text: String?
            let intent: String?
            let priority: String?
            // swiftlint:disable:next identifier_name
            let due_date: String?
            // swiftlint:disable:next identifier_name
            let sub_items: [TaskSubItem]?
        }

        do {
            let result = try JSONDecoder().decode(GeneratedTask.self, from: data)

            if let t = result.text, !t.isEmpty { text = t }
            if let i = result.intent, !i.isEmpty { intent = i }
            if let p = result.priority, ["high", "medium", "low"].contains(p) { priority = p }
            if let d = result.due_date, !d.isEmpty,
               let date = TaskItem.parseDueDate(d) {
                dueDate = date
                hasDueDate = true
            }
            if let items = result.sub_items, !items.isEmpty {
                subItems = items
            }
        } catch {
            errorMessage = "Failed to parse AI response: \(error.localizedDescription)"
        }
    }

    // MARK: - Create

    private func createTask() {
        guard let db = appState.databaseManager else {
            errorMessage = "Database not available"
            return
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let dueDateStr: String
        if hasDueDate, let dueDate {
            dueDateStr = TaskItem.formatDueDate(dueDate)
        } else {
            dueDateStr = ""
        }

        let subItemsJSON: String
        if subItems.isEmpty {
            subItemsJSON = "[]"
        } else if let data = try? JSONEncoder().encode(subItems),
                  let json = String(data: data, encoding: .utf8) {
            subItemsJSON = json
        } else {
            subItemsJSON = "[]"
        }

        do {
            _ = try db.dbPool.write { dbConn in
                try TaskQueries.create(
                    dbConn,
                    text: trimmed,
                    intent: intent.trimmingCharacters(in: .whitespacesAndNewlines),
                    priority: priority,
                    dueDate: dueDateStr,
                    sourceType: prefillSourceType,
                    sourceID: prefillSourceID,
                    subItems: subItemsJSON
                )
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
