import SwiftUI
import WatchtowerCore

struct CreateTargetSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    var prefill: TargetPrefill? = nil
    /// Fires after a successful insert with the new target id. Used by the inbox
    /// callsite (Task 14) to backfill `inbox_items.target_id` via
    /// `InboxQueries.linkTarget`. Other callsites pass nil.
    var onCreated: ((Int) -> Void)? = nil

    @State private var text: String = ""
    @State private var intent: String = ""
    @State private var level: String = "day"
    @State private var priority: String = "medium"
    @State private var periodStart: Date = Date()
    @State private var periodEnd: Date = Date()
    @State private var subItems: [TargetSubItem] = []
    @State private var newSubItemText: String = ""
    @State private var errorMessage: String?
    @State private var showExtractSheet = false
    @State private var extractedResult: TargetExtractResult?
    /// True only while THIS sheet instance is the one that started the
    /// in-flight extraction — gates the `phase` transition handler below
    /// so a sheet never reacts to a result/error started by a different
    /// CreateTargetSheet instance elsewhere in the app.
    @State private var awaitingOwnExtraction = false
    /// Inline outcome of the extraction this sheet started. `.empty`/`.failed`
    /// used to be handed to the global capsule, which sits in the main window
    /// *underneath* this modal sheet — unreachable, so the button read as a
    /// no-op. Every terminal phase now lands here instead.
    @State private var extractNotice: ExtractNotice?
    /// The level the AI proposed a period for. The proposed window is persisted
    /// verbatim only while `level` still matches; picking another level hands
    /// the period back to the sheet's own rules.
    @State private var aiPeriodLevel: String?
    /// Form snapshot taken right before an AI fill, restored by banner's Undo.
    @State private var preFillDraft: TargetDraft?
    @State private var showMoreOptions: Bool = false
    @State private var showChecklist: Bool = false
    /// Indices into `subItems` that the user marked to be promoted into
    /// standalone child targets right after the parent target is created.
    /// Indices are kept in sync with `subItems` mutations (see `removeSubItem`).
    @State private var pendingPromotions: Set<Int> = []
    @State private var isCreating: Bool = false
    @State private var sourceType: String = "manual"
    @State private var sourceID: String = ""
    @State private var secondaryLinks: [TargetPrefillLink] = []
    /// Optional parent target (`targets.parent_id`). nil = top-level target.
    @State private var parentID: Int?
    /// Active targets offered in the parent picker. Loaded once on appear.
    @State private var candidateParents: [Target] = []

    private let dateFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt
    }()

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader
            Divider()
            formContent
            Divider()
            sheetFooter
        }
        .frame(width: 520, height: 480)
        .onAppear {
            if let p = prefill {
                text = p.text
                intent = p.intent
                sourceType = p.sourceType
                sourceID = p.sourceID
                secondaryLinks = p.secondaryLinks
                parentID = p.parentID
            }
            if !intent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                showMoreOptions = true
            }
            if !subItems.isEmpty {
                showChecklist = true
            }
            loadCandidateParents()
            // A preselected parent (sub-target creation) snaps the planning
            // window to the parent's, matching `createChild` semantics.
            if let pid = parentID { inheritFromParent(pid) }
        }
        .sheet(isPresented: $showExtractSheet) {
            if let result = extractedResult {
                ExtractPreviewSheet(
                    proposed: result.extracted,
                    omittedCount: result.omittedCount,
                    notes: result.notes,
                    onCreateSelected: { _ in
                        dismiss()
                    }
                )
            }
        }
        .onChange(of: appState.targetExtractCenter.phase) { _, phase in
            guard awaitingOwnExtraction else { return }
            switch phase {
            case .ready:
                awaitingOwnExtraction = false
                if let result = appState.targetExtractCenter.result {
                    applyExtractResult(result)
                    // The sheet now owns the outcome; clear the Center so the
                    // global capsule doesn't also offer the same result.
                    appState.targetExtractCenter.dismiss()
                }
            case .empty:
                awaitingOwnExtraction = false
                showNothingFoundNotice()
                appState.targetExtractCenter.dismiss()
            case let .failed(message, canRetry):
                awaitingOwnExtraction = false
                extractNotice = ExtractNotice(
                    kind: .failed,
                    message: message,
                    canRetry: canRetry,
                    details: appState.targetExtractCenter.lastRawError
                )
                appState.targetExtractCenter.dismiss()
            case .idle, .extracting:
                break
            }
        }
    }

    private var sheetHeader: some View {
        HStack {
            Text("New Target")
                .font(.headline)
            Spacer()
            Button("Cancel") { dismiss() }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
    }

    private var formContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                textFieldWithAI
                extractButton
                extractNoticeRow
                levelPriorityRow
                parentPickerRow
                customPeriodRow
                checklistSection
                moreOptionsSection
                sourceInfo
                errorRow
            }
            .padding()
        }
    }

    private var textFieldWithAI: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text("What's the goal? Paste a message or write your own…")
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 10)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(minHeight: 56, maxHeight: 180)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var extractButton: some View {
        let center = appState.targetExtractCenter
        let isExtracting = center.phase == .extracting
        return HStack {
            Button {
                Task { await runExtract() }
            } label: {
                if isExtracting && awaitingOwnExtraction {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        // The call routinely runs 20–45 s; saying so up front
                        // stops it reading as a hang.
                        Text("Extracting… (up to a minute)")
                    }
                } else {
                    Label("Extract with AI", systemImage: "sparkles")
                }
            }
            .buttonStyle(.bordered)
            .disabled(isExtracting || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help(
                isExtracting && !awaitingOwnExtraction
                    ? "An extraction is already running — wait for it to finish"
                    : "Runs the goal text and the context you wrote through the LLM, "
                        + "then fills this form (or offers a list when it finds several targets)"
            )
            Spacer()
        }
    }

    @ViewBuilder
    private var extractNoticeRow: some View {
        if let notice = extractNotice {
            ExtractNoticeBanner(
                notice: notice,
                onRetry: { Task { await runExtract() } },
                onUndo: { undoExtractFill() },
                onDismiss: { extractNotice = nil }
            )
        }
    }

    private var levelPriorityRow: some View {
        HStack(alignment: .center, spacing: 12) {
            Picker("Level", selection: $level) {
                Text("Quarter").tag("quarter")
                Text("Month").tag("month")
                Text("Week").tag("week")
                Text("Day").tag("day")
                Text("Custom").tag("custom")
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(maxWidth: .infinity)

            Picker("Priority", selection: $priority) {
                Text("High").tag("high")
                Text("Med").tag("medium")
                Text("Low").tag("low")
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 160)
        }
    }

    @ViewBuilder
    private var customPeriodRow: some View {
        if level == "custom" {
            HStack(spacing: 8) {
                DatePicker("Start", selection: $periodStart, displayedComponents: .date)
                    .labelsHidden()
                Text("→").foregroundStyle(.secondary)
                DatePicker("End", selection: $periodEnd, displayedComponents: .date)
                    .labelsHidden()
                Spacer()
            }
            .font(.callout)
        }
    }

    private var parentPickerRow: some View {
        HStack(spacing: 8) {
            Text("Parent")
                .font(.callout)
                .foregroundStyle(.secondary)
            Menu {
                Button("None (top-level)") { selectParent(nil) }
                if !candidateParents.isEmpty {
                    Divider()
                    ForEach(candidateParents) { candidate in
                        Button(candidate.text) { selectParent(candidate.id) }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(parentDisplayName)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Spacer()
        }
    }

    private var parentDisplayName: String {
        guard let parentID,
              let parent = candidateParents.first(where: { $0.id == parentID })
        else { return "None" }
        return parent.text
    }

    /// Selects a parent and, when one is chosen, inherits its planning window.
    private func selectParent(_ id: Int?) {
        parentID = id
        if let id { inheritFromParent(id) }
    }

    /// Snaps `level`/period to the parent's so a sub-target lands inside the
    /// parent's planning window. The user can still override afterward.
    private func inheritFromParent(_ id: Int) {
        guard let parent = candidateParents.first(where: { $0.id == id }) else { return }
        level = parent.level
        if let start = dateFormatter.date(from: parent.periodStart) {
            periodStart = start
        }
        if let end = dateFormatter.date(from: parent.periodEnd) {
            periodEnd = end
        }
    }

    private func loadCandidateParents() {
        guard let db = appState.databaseManager else { return }
        var loaded: [Target]
        do {
            loaded = try db.dbPool.read { dbConn in
                try TargetQueries.fetchAll(dbConn, filter: TargetFilter())
            }
        } catch {
            print("CreateTargetSheet: failed to load candidate parents: \(error)")
            loaded = []
        }
        // Ensure a preselected parent is offered even if it's done/dismissed
        // (active-only filter would otherwise drop it and blank the label).
        if let pid = parentID, !loaded.contains(where: { $0.id == pid }),
           let parent = try? db.dbPool.read({ try TargetQueries.fetchByID($0, id: pid) }) {
            loaded.insert(parent, at: 0)
        }
        candidateParents = loaded
    }

    @ViewBuilder
    private var checklistSection: some View {
        if subItems.isEmpty && !showChecklist {
            Button {
                withAnimation { showChecklist = true }
            } label: {
                Label("Add checklist", systemImage: "plus.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(subItems.enumerated()), id: \.offset) { index, item in
                    HStack(spacing: 8) {
                        Image(systemName: "circle")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                        Text(item.text)
                            .font(.callout)
                        Spacer()
                        Button {
                            togglePromote(at: index)
                        } label: {
                            Image(systemName: pendingPromotions.contains(index)
                                  ? "arrow.up.right.square.fill"
                                  : "arrow.up.right.square")
                                .foregroundStyle(pendingPromotions.contains(index)
                                                 ? Color.accentColor
                                                 : .secondary)
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .help(pendingPromotions.contains(index)
                              ? "Will become a sub-target"
                              : "Promote to sub-target on save")
                        Button {
                            removeSubItem(at: index)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.tertiary)
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                    }
                }
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    TextField("Add checklist item…", text: $newSubItemText)
                        .font(.callout)
                        .textFieldStyle(.plain)
                        .onSubmit {
                            let trimmed = newSubItemText.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty {
                                subItems.append(TargetSubItem(text: trimmed, done: false))
                                newSubItemText = ""
                            }
                        }
                }
            }
        }
    }

    private var moreOptionsSection: some View {
        DisclosureGroup(isExpanded: $showMoreOptions) {
            ZStack(alignment: .topLeading) {
                if intent.isEmpty {
                    Text("Why does this matter?")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 10)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $intent)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(minHeight: 50, maxHeight: 110)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.top, 6)
        } label: {
            Text("Add context")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var sourceInfo: some View {
        if sourceType != "manual" {
            HStack(spacing: 4) {
                Image(systemName: sourceIcon)
                    .foregroundStyle(.secondary)
                Text("From \(sourceType) #\(sourceID)")
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
            if !pendingPromotions.isEmpty {
                Text("\(pendingPromotions.count) checklist item\(pendingPromotions.count == 1 ? "" : "s") will become sub-target\(pendingPromotions.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await createTargetAndPromote() }
            } label: {
                if isCreating {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.small)
                        Text("Creating…")
                    }
                } else {
                    Text("Create")
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(isCreating || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
    }

    private var sourceIcon: String {
        switch sourceType {
        case "track": return "binoculars"
        case "digest": return "doc.text.magnifyingglass"
        case "briefing": return "sun.max"
        default: return "square.and.pencil"
        }
    }

    /// Toggles the "promote on save" mark for the sub-item at `index`.
    private func togglePromote(at index: Int) {
        if pendingPromotions.contains(index) {
            pendingPromotions.remove(index)
        } else {
            pendingPromotions.insert(index)
        }
    }

    /// Removes a sub-item and shifts pending-promotion indices so they keep
    /// pointing at the same items after the removal.
    private func removeSubItem(at index: Int) {
        subItems.remove(at: index)
        var rebuilt: Set<Int> = []
        for i in pendingPromotions where i != index {
            rebuilt.insert(i < index ? i : i - 1)
        }
        pendingPromotions = rebuilt
    }

    private func createTargetAndPromote() async {
        guard let db = appState.databaseManager else {
            errorMessage = "Database not available"
            return
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isCreating = true
        errorMessage = nil
        defer { isCreating = false }

        let today = dateFormatter.string(from: Date())
        // An AI-proposed window is persisted verbatim as long as the level it
        // was proposed for still stands; changing the level hands the period
        // back to the sheet's today/today default.
        let useExplicitPeriod = level == "custom" || aiPeriodLevel == level
        let start = useExplicitPeriod ? dateFormatter.string(from: periodStart) : today
        let end = useExplicitPeriod ? dateFormatter.string(from: periodEnd) : today

        let subItemsJSON: String
        if subItems.isEmpty {
            subItemsJSON = "[]"
        } else if let data = try? JSONEncoder().encode(subItems),
                  let json = String(data: data, encoding: .utf8) {
            subItemsJSON = json
        } else {
            subItemsJSON = "[]"
        }

        // Snapshot @MainActor-isolated values into Sendable locals before
        // they're captured by the async write closure.
        let intentCopy = intent.trimmingCharacters(in: .whitespacesAndNewlines)
        let levelCopy = level
        let priorityCopy = priority
        let sourceTypeCopy = sourceType
        let sourceIDCopy = sourceID
        let secondaryLinksCopy = secondaryLinks
        let parentIDCopy = parentID

        // 1. Insert the parent target.
        let newID: Int
        do {
            newID = try await db.dbPool.write { dbConn -> Int in
                try TargetQueries.create(
                    dbConn,
                    text: trimmed,
                    intent: intentCopy,
                    level: levelCopy,
                    periodStart: start,
                    periodEnd: end,
                    parentId: parentIDCopy,
                    priority: priorityCopy,
                    subItems: subItemsJSON,
                    sourceType: sourceTypeCopy,
                    sourceID: sourceIDCopy,
                    secondaryLinks: secondaryLinksCopy
                )
            }
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        // 2. If the user marked any sub-items for promotion, delegate to the
        //    canonical batch-promote on TargetsViewModel — single source of
        //    truth for the descending-index contract.
        if !pendingPromotions.isEmpty {
            let vm = TargetsViewModel(dbManager: db)
            let items = pendingPromotions.map { (index: $0, overrides: PromoteSubItemOverrides()) }
            do {
                try await vm.promoteSubItemsAfterCreate(parentID: newID, items: items)
            } catch {
                // Parent persisted; surface the partial failure and keep the
                // sheet open so the user can retry or close manually.
                errorMessage = "Target created but some sub-items failed to promote: \(error.localizedDescription)"
                return
            }
        }

        onCreated?(newID)
        dismiss()
    }

    private func runExtract() async {
        guard let runner = ProcessCLIRunner.makeDefault() else {
            errorMessage = "watchtower CLI not found in PATH"
            return
        }
        errorMessage = nil
        extractNotice = nil
        awaitingOwnExtraction = true
        // The "Add context" field rides along — it used to be dropped, so
        // context the user had written could not influence the proposal.
        let input = TargetExtractFill.composeInput(text: text, context: intent)
        appState.targetExtractCenter.start(text: input, runner: runner)
    }

    /// Routes a finished extraction: one proposal fills this form, several open
    /// the multi-select preview, none leaves an inline "nothing found" notice.
    private func applyExtractResult(_ result: TargetExtractResult) {
        switch TargetExtractFill.apply(result.extracted, to: currentDraft()) {
        case .nothing:
            showNothingFoundNotice()
        case .needsPreview:
            extractedResult = result
            showExtractSheet = true
        case let .filled(draft):
            preFillDraft = currentDraft()
            apply(draft)
            extractNotice = ExtractNotice(
                kind: .filled,
                message: "AI filled in the form below — check it, then Create.",
                canRetry: false,
                details: nil
            )
        }
    }

    private func showNothingFoundNotice() {
        extractNotice = ExtractNotice(
            kind: .nothing,
            message: "AI found no target in this text. Add a bit more detail and try again.",
            canRetry: true,
            details: nil
        )
    }

    private func undoExtractFill() {
        if let draft = preFillDraft { apply(draft) }
        preFillDraft = nil
        extractNotice = nil
    }

    private func currentDraft() -> TargetDraft {
        TargetDraft(
            text: text,
            intent: intent,
            level: level,
            priority: priority,
            periodStart: dateFormatter.string(from: periodStart),
            periodEnd: dateFormatter.string(from: periodEnd),
            hasExplicitPeriod: aiPeriodLevel == level,
            subItems: subItems,
            parentID: parentID
        )
    }

    private func apply(_ draft: TargetDraft) {
        text = draft.text
        intent = draft.intent
        level = draft.level
        priority = draft.priority
        subItems = draft.subItems
        parentID = draft.parentID
        if draft.hasExplicitPeriod,
           let start = dateFormatter.date(from: draft.periodStart),
           let end = dateFormatter.date(from: draft.periodEnd) {
            periodStart = start
            periodEnd = end
            aiPeriodLevel = draft.level
        } else {
            aiPeriodLevel = nil
        }
        if !intent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            showMoreOptions = true
        }
        if !subItems.isEmpty {
            showChecklist = true
        }
    }
}
