import SwiftUI
import AppKit
import WatchtowerCore

/// Chat-first creation composer (spec §9.5): one multiline editor, a permanent
/// key-hint caption, the Extract affordance as a secondary control, and an
/// error row — no form fields. Enter creates the target row mechanically
/// (TGT-BRIEF-02: no AI involvement in row creation) and briefs the assistant
/// via `TargetBriefCenter`; ⌘Enter creates silently; Shift+Enter inserts a
/// newline. Submit logic (title derivation) lives in the testable Core type
/// `TargetComposerLogic`.
struct CreateTargetSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    var prefill: TargetPrefill? = nil
    /// Fires after a successful insert with the new target id. Used by the inbox
    /// callsite (Task 14) to backfill `inbox_items.target_id` via
    /// `InboxQueries.linkTarget`, and by TargetsListView to land on the new
    /// target's streaming chat after an Enter-submit. Other callsites pass nil.
    var onCreated: ((Int) -> Void)? = nil

    @State private var text: String = ""
    @State private var errorMessage: String?
    @State private var showExtractSheet = false
    @State private var extractedResult: TargetExtractResult?
    /// True only while THIS sheet instance is the one that started the
    /// in-flight extraction — gates the `phase` transition handler below
    /// so a sheet never reacts to a result/error started by a different
    /// CreateTargetSheet instance elsewhere in the app.
    @State private var awaitingOwnExtraction = false
    @State private var isCreating: Bool = false
    @State private var sourceType: String = "manual"
    @State private var sourceID: String = ""
    @State private var secondaryLinks: [TargetPrefillLink] = []
    /// Optional parent target (`targets.parent_id`). nil = top-level target.
    /// Kept for the "Add sub-target" call site (TargetDetailView).
    @State private var parentID: Int?

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
            VStack(alignment: .leading, spacing: 10) {
                composerEditor
                captionRow
                extractButton
                sourceInfo
                errorRow
            }
            .padding()
        }
        .frame(width: 520)
        .onAppear { applyPrefill() }
        .background {
            // ⌘Enter — just create. The editor's NSTextView does not consume
            // Cmd+Return as a key equivalent, so this window-level shortcut
            // fires even while the editor has focus (the TargetsListView ⌘N
            // hidden-button precedent).
            Button("") { Task { await submit(brief: false) } }
                .keyboardShortcut(.return, modifiers: .command)
                .hidden()
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
                    extractedResult = result
                    showExtractSheet = true
                    // The sheet now owns a copy; clear the Center so the global
                    // capsule doesn't also offer the same result.
                    appState.targetExtractCenter.dismiss()
                }
            case .empty, .failed:
                // Hand off to the global capsule (friendly message + retry).
                awaitingOwnExtraction = false
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
            if isCreating {
                ProgressView().controlSize(.small)
                    .padding(.trailing, 8)
            }
            Button("Cancel") { dismiss() }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
    }

    private var composerEditor: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text("Brief the assistant: what needs to happen, links, context — it will name the task, break it down, and gather data.")
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 8)
                    .allowsHitTesting(false)
            }
            ComposerTextInput(
                text: $text,
                onSubmit: { Task { await submit(brief: true) } },
                onSilentSubmit: { Task { await submit(brief: false) } }
            )
            .padding(4)
        }
        .frame(height: 180)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// Permanent discoverability caption (spec §4) — not a transient tooltip.
    private var captionRow: some View {
        Text("Enter — brief the assistant · ⌘Enter — just create")
            .font(.caption)
            .foregroundStyle(.secondary)
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
                        Text("Extracting…")
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
                    : "Run the entered text through the LLM to propose structured targets"
            )
            Spacer()
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

    private var sourceIcon: String {
        switch sourceType {
        case "track": return "binoculars"
        case "digest": return "doc.text.magnifyingglass"
        case "briefing": return "sun.max"
        default: return "square.and.pencil"
        }
    }

    private func applyPrefill() {
        guard let p = prefill else { return }
        // Prefill text plus intent (as a second paragraph) become the
        // composer's initial text — the assistant derives structure from it.
        var combined = p.text
        let intentTrimmed = p.intent.trimmingCharacters(in: .whitespacesAndNewlines)
        if !intentTrimmed.isEmpty {
            combined = combined.isEmpty ? intentTrimmed : combined + "\n\n" + intentTrimmed
        }
        text = combined
        sourceType = p.sourceType
        sourceID = p.sourceID
        secondaryLinks = p.secondaryLinks
        parentID = p.parentID
    }

    /// Both submit paths create the row mechanically, instantly, locally —
    /// an unreachable AI CLI can never block creating a target
    /// (TGT-BRIEF-02). `brief: true` (Enter) additionally hands the full
    /// composer text to `TargetBriefCenter`, whose run survives this sheet's
    /// dismissal; `brief: false` (⌘Enter) stops at the row.
    private func submit(brief: Bool) async {
        guard !isCreating else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let db = appState.databaseManager else {
            errorMessage = "Database not available"
            return
        }

        isCreating = true
        errorMessage = nil
        defer { isCreating = false }

        let title = TargetComposerLogic.deriveTitle(from: trimmed)
        let today = dateFormatter.string(from: Date())
        // Snapshot @MainActor-isolated values into Sendable locals before
        // they're captured by the async write closure.
        let sourceTypeCopy = sourceType
        let sourceIDCopy = sourceID
        let secondaryLinksCopy = secondaryLinks
        let parentIDCopy = parentID

        let newID: Int
        do {
            newID = try await db.dbPool.write { dbConn -> Int in
                // A composer-created sub-target inherits the parent's level
                // and planning period — the TargetsViewModel.createChild
                // semantics, so it matches a assistant-created one. No
                // parent → day/today.
                var level = "day"
                var periodStart = today
                var periodEnd = today
                if let parentIDCopy,
                   let parent = try TargetQueries.fetchByID(dbConn, id: parentIDCopy) {
                    level = parent.level
                    periodStart = parent.periodStart
                    periodEnd = parent.periodEnd
                }
                return try TargetQueries.create(
                    dbConn,
                    text: title,
                    intent: "",  // the assistant fills it (update_intent)
                    level: level,
                    periodStart: periodStart,
                    periodEnd: periodEnd,
                    parentId: parentIDCopy,
                    sourceType: sourceTypeCopy,
                    sourceID: sourceIDCopy,
                    secondaryLinks: secondaryLinksCopy
                )
            }
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        if brief {
            // The row exists either way (mechanical create succeeded); a
            // failed hand-off lands on the center's `.failed` phase so the
            // target's Assistant tab shows the failure banner — the owner
            // re-asks in the target's chat (spec §7).
            do {
                if let created = try await db.dbPool.read({ dbConn in
                    try TargetQueries.fetchByID(dbConn, id: newID)
                }) {
                    appState.targetBriefCenter.startBrief(target: created, text: trimmed)
                } else {
                    appState.targetBriefCenter.markFailed(
                        targetID: newID,
                        message: "Couldn't start the brief: the created target could not be loaded"
                    )
                }
            } catch {
                appState.targetBriefCenter.markFailed(
                    targetID: newID,
                    message: "Couldn't start the brief: \(error.localizedDescription)"
                )
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
        awaitingOwnExtraction = true
        appState.targetExtractCenter.start(text: text, runner: runner)
    }
}

// MARK: - Composer text input
// Enter = brief the assistant, ⌘Enter = just create, Shift+Enter = newline
// (the ChatInput/ExpandingTextInput key-handling shape, fixed-height variant).

private struct ComposerTextInput: NSViewRepresentable {
    @Binding var text: String
    var onSubmit: () -> Void
    var onSilentSubmit: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }

        textView.delegate = context.coordinator
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.textContainer?.lineFragmentPadding = 4
        textView.drawsBackground = false
        textView.string = text

        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextInput

        init(_ parent: ComposerTextInput) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }

        func textView(_ textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            if sel == #selector(NSResponder.insertNewline(_:)) {
                let event = NSApp.currentEvent
                if event?.modifierFlags.contains(.shift) == true {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                    return true
                }
                if event?.modifierFlags.contains(.command) == true {
                    // Normally intercepted by the sheet's hidden ⌘Enter
                    // shortcut before reaching the text view; handled here too
                    // so ⌘Enter can never fall through to a plain newline —
                    // and never to a brief the owner didn't ask for.
                    parent.onSilentSubmit()
                    return true
                }
                // Plain Enter → brief the assistant
                parent.onSubmit()
                return true
            }
            return false
        }
    }
}
