import AppKit
import SwiftUI
import WatchtowerCore

/// Where the drawer host puts its content and its drawer. Expanding never
/// resizes the content: it keeps the width it had beside the drawer and the
/// drawer covers it, so a terminal's pty never gets a near-zero column
/// count (the split view detaches a hidden terminal for the same reason).
enum OwnerAskDrawerLayout {
    /// The content never gets narrower than this beside the drawer.
    static let minContentWidth: CGFloat = 200
    /// The drawer never gets narrower than its own minimum: a pane with no
    /// room for both shows it covering, as expanded.
    static let minDrawerWidth = CGFloat(OwnerAsksViewModel.drawerWidthRange.lowerBound)

    struct Frames: Equatable {
        /// The content's width, covered or not.
        let content: CGFloat
        /// The drawer's leading edge and width.
        let drawerX: CGFloat
        let drawer: CGFloat
        /// The drawer covers the content (expanded, or no room beside it):
        /// the content is hidden and its terminal takes no focus.
        let covers: Bool
    }

    static func frames(total: CGFloat, drawerWidth: CGFloat, hasDrawer: Bool, expanded: Bool) -> Frames {
        guard hasDrawer else { return Frames(content: total, drawerX: total, drawer: 0, covers: false) }
        let room = total - minContentWidth
        guard room >= minDrawerWidth else { return Frames(content: total, drawerX: 0, drawer: total, covers: true) }
        let drawer = min(max(drawerWidth, minDrawerWidth), room)
        let content = total - drawer
        return expanded
            ? Frames(content: content, drawerX: 0, drawer: total, covers: true)
            : Frames(content: content, drawerX: content, drawer: drawer, covers: false)
    }

    /// Whether the content is covered, for `askDrawerCovers`: by this
    /// host's drawer, or by an outer host's (a session pane's host inside
    /// the page-level one) — an inner host never uncovers what an outer one
    /// covers.
    static func contentCovered(outer: Bool, by frames: Frames) -> Bool {
        outer || frames.covers
    }
}

/// Lays an ask drawer beside `content` (spec 2026-10-03 Part 8): a
/// session's terminal, or the whole workspace for an ask filed outside the
/// app. The drawer is resizable from its leading edge (its width kept by
/// `OwnerAsksViewModel.drawerWidth`) and can take the whole width, drawn
/// over the content (`OwnerAskDrawerLayout`).
struct OwnerAskDrawerHost<Content: View>: View {
    let vm: WorkbenchesViewModel
    /// The ask to show here; nil leaves `content` alone.
    let ask: OwnerAsk?
    @ViewBuilder let content: () -> Content
    @State private var liveWidth: Double?
    @Environment(\.askDrawerCovers) private var outerCovers

    var body: some View {
        let asks = vm.asks
        GeometryReader { geometry in
            let frames = OwnerAskDrawerLayout.frames(
                total: geometry.size.width, drawerWidth: CGFloat(liveWidth ?? asks.drawerWidth),
                hasDrawer: ask != nil, expanded: asks.drawerExpanded
            )
            let expanded = frames.covers
            ZStack(alignment: .topLeading) {
                // Hidden, never removed or resized, under an expanded drawer:
                // the terminal host, the board and Monaco keep their identity,
                // state and size.
                content()
                    .frame(width: frames.content, height: geometry.size.height)
                    .opacity(expanded ? 0 : 1)
                    .disabled(expanded)
                    .allowsHitTesting(!expanded)
                    .accessibilityHidden(expanded)
                    .environment(\.askDrawerCovers, OwnerAskDrawerLayout.contentCovered(outer: outerCovers, by: frames))
                if let ask {
                    HStack(spacing: 0) {
                        if !expanded { Divider() }
                        OwnerAskDrawer(vm: vm, ask: ask)
                    }
                    .frame(width: frames.drawer, height: geometry.size.height)
                    .overlay(alignment: .leading) {
                        if !expanded {
                            PanelResizeHandle(
                                width: Binding(get: { asks.drawerWidth }, set: { asks.setDrawerWidth($0) }),
                                liveWidth: $liveWidth,
                                range: OwnerAsksViewModel.drawerWidthRange,
                                growsLeftward: true
                            )
                        }
                    }
                    .offset(x: frames.drawerX)
                }
            }
        }
    }
}

/// One ask, next to the terminal of the session that filed it: a header
/// (kind, title, target, age, "k of N ›", expand, close), a scroll body —
/// the notice of the last answer, the agent's header card, the question
/// card, then the review document or the checklist, and a note — and the
/// answer bar. A closed ask (answered, withdrawn) shows the same read-only:
/// its answer, or the draft kept when the agent withdrew it under the owner.
struct OwnerAskDrawer: View {
    let vm: WorkbenchesViewModel
    let ask: OwnerAsk
    @State private var scrollTarget: DocumentScrollTarget?
    @State private var showingDiff = false
    @State private var topHeight: CGFloat = 0

    private var asks: OwnerAsksViewModel { vm.asks }

    /// Input goes to the draft only while the ask is open and no answer is
    /// being written (`OwnerAsksViewModel.editDraft`).
    private var editable: Bool { ask.isOpen && !asks.answering.contains(ask.id) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if ask.kind == .review {
                reviewLayout
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        topSections
                        kindBody
                        noteView
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Divider()
            OwnerAskAnswerBar(
                asks: asks,
                ask: ask,
                statusLine: OwnerAskPresentation.statusLine(ask, replacedBy: asks.replacements[ask.projectID]?[ask.id])
            )
        }
        .background(Color(nsColor: .textBackgroundColor))
        .sheet(isPresented: $showingDiff) { OwnerAskDiffSheet(asks: asks, ask: ask) }
        // "k of N ›" swaps the ask under the same drawer.
        .onChange(of: ask.id) { _, _ in
            scrollTarget = nil
            showingDiff = false
        }
    }

    /// The notice, the agent's header card and the question card.
    @ViewBuilder
    private var topSections: some View {
        if let notice = asks.notices[ask.id] {
            noticeRow(notice)
        }
        OwnerAskHeaderCard(
            ask: ask,
            showDiff: ask.kind == .review && ask.previousAskID != nil ? { showingDiff = true } : nil,
            focusAction: focusAction
        )
        if !ask.payload.questions.isEmpty {
            ChatQuestionCardView(
                card: ChatQuestionCard(questions: ask.payload.questions),
                answerText: nil,
                onAnswer: nil,
                draftPicks: picksBinding,
                editable: editable
            )
        }
    }

    private var hasTopSections: Bool {
        asks.notices[ask.id] != nil || !ask.summary.isEmpty || !ask.payload.focus.isEmpty || !ask.changes.isEmpty
            || ask.previousAskID != nil || !ask.payload.questions.isEmpty
    }

    /// A review's document scrolls by itself (a snapshot may be 2 MiB, too
    /// much for a SwiftUI scroll view): the top sections scroll above it in
    /// at most 40% of the height, the note sits below it.
    private var reviewLayout: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                if hasTopSections {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) { topSections }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }, action: { topHeight = $0 })
                    }
                    .frame(height: min(topHeight, geometry.size.height * 0.4))
                    Divider()
                }
                OwnerAskReviewBody(asks: asks, ask: ask, editable: editable, scrollTarget: scrollTarget)
                if editable || !note.isEmpty {
                    Divider()
                    noteView.padding(.horizontal, 14).padding(.vertical, 8)
                }
            }
        }
    }

    /// A review's focus item jumps to its place once the snapshot is
    /// rendered; one not in it gets no link.
    private func focusAction(_ focus: OwnerAskFocus) -> (() -> Void)? {
        guard ask.kind == .review, let range = asks.reviewDocuments.range(of: focus, askID: ask.id) else { return nil }
        return { scrollTarget = DocumentScrollTarget(offset: range.location) }
    }

    // MARK: - Header

    private var header: some View {
        let stack = asks.stack(projectID: ask.projectID)
        return HStack(spacing: 8) {
            Image(systemName: OwnerAskPresentation.kindIcon(ask.kind))
                .foregroundStyle(Color.accentColor)
                .accessibilityLabel(OwnerAskPresentation.kindLabel(ask.kind))
            VStack(alignment: .leading, spacing: 1) {
                Text(ask.title).font(.headline).lineLimit(2)
                Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if let position = stack.position(of: ask.id), stack.count > 1 {
                Button {
                    Task { await vm.showNextAsk(after: ask.id, projectID: ask.projectID) }
                } label: {
                    Text("\(OwnerAskPresentation.positionLabel(position, of: stack.count)) ›").monospacedDigit()
                }
                .buttonStyle(.borderless)
                .help("Next ask")
            }
            Button {
                // The terminal under an expanded drawer is hidden: it must
                // not keep the keystrokes.
                // Only the terminal's focus goes; the note field keeps its caret.
                if !asks.drawerExpanded, TerminalHostAttachment.terminalHasFocus(in: NSApp.keyWindow) {
                    NSApp.keyWindow?.makeFirstResponder(nil)
                }
                asks.drawerExpanded.toggle()
            } label: {
                Image(systemName: asks.drawerExpanded
                      ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.borderless)
            .help(asks.drawerExpanded ? "Back beside the terminal" : "Expand")
            .accessibilityLabel(asks.drawerExpanded ? "Collapse" : "Expand")
            Button {
                asks.closeDrawer(projectID: ask.projectID)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Close; your draft is kept")
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Kind · #target · age.
    private var caption: String {
        let parts: [String?] = [
            OwnerAskPresentation.kindLabel(ask.kind),
            ask.targetID.map { "#\($0)" },
            TimeFormatting.shortAge(from: ask.createdAt, now: Date())
        ]
        return parts.compactMap(\.self).joined(separator: " · ")
    }

    private func noticeRow(_ notice: OwnerAsksViewModel.Notice) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: notice == .withdrawn ? "exclamationmark.triangle" : "checkmark.circle")
                .foregroundStyle(notice == .withdrawn ? .orange : .green)
            Text(notice.text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Dismiss") { asks.dismissNotice(askID: ask.id) }
                .controlSize(.small)
        }
        .padding(8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Body by kind

    @ViewBuilder
    private var kindBody: some View {
        switch ask.kind {
        case .review: EmptyView() // `reviewLayout`
        case .check:
            OwnerAskChecklistBody(
                items: ask.payload.checklist,
                marks: marks,
                notes: checkNotes,
                editable: editable,
                mark: { id, state in asks.editDraft(ask.id) { $0.checks[id] = state } },
                setNote: { id, text in asks.editDraft(ask.id) { $0.checkNotes[id] = text } }
            )
        case .question: EmptyView()
        }
    }

    @ViewBuilder
    private var noteView: some View {
        if editable {
            TextField(
                "Note for the agent (optional)",
                text: Binding(get: { asks.drafts.draft(for: ask.id).note }, set: { text in asks.editDraft(ask.id) { $0.note = text } }),
                axis: .vertical
            )
            .textFieldStyle(.roundedBorder)
            .lineLimit(2...6)
        } else if !note.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("Note").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(note).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
        }
    }

    // MARK: - What the body shows: the draft, or a closed ask's answer

    private var picksBinding: Binding<[String: ChatQuestionAnswer.Entry]> {
        if let answer = ask.answer { return .constant(OwnerAskPresentation.picks(from: answer)) }
        let (asks, id) = (asks, ask.id)
        return Binding(get: { asks.drafts.draft(for: id).picks }, set: { picks in asks.editDraft(id) { $0.picks = picks } })
    }

    private var marks: [String: OwnerAskAnswer.CheckState] {
        ask.answer.map(OwnerAskPresentation.marks(from:)) ?? asks.drafts.draft(for: ask.id).checks
    }

    private var checkNotes: [String: String] {
        ask.answer.map(OwnerAskPresentation.notes(from:)) ?? asks.drafts.draft(for: ask.id).checkNotes
    }

    private var note: String {
        ask.answer?.note ?? asks.drafts.draft(for: ask.id).note
    }
}

extension EnvironmentValues {
    /// Set by `OwnerAskDrawerHost` on its content while the drawer covers it
    /// (expanded, or a pane too narrow for both): a terminal in it takes no
    /// focus (`TerminalHostAttachment.needsFocus`).
    @Entry var askDrawerCovers = false
}
