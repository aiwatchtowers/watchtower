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

    struct Frames: Equatable {
        /// The content's width, expanded or not.
        let content: CGFloat
        /// The drawer's leading edge and width.
        let drawerX: CGFloat
        let drawer: CGFloat
    }

    static func frames(total: CGFloat, drawerWidth: CGFloat, hasDrawer: Bool, expanded: Bool) -> Frames {
        guard hasDrawer else { return Frames(content: total, drawerX: total, drawer: 0) }
        let drawer = min(drawerWidth, max(0, total - minContentWidth))
        let content = total - drawer
        return expanded ? Frames(content: content, drawerX: 0, drawer: total) : Frames(content: content, drawerX: content, drawer: drawer)
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

    var body: some View {
        let asks = vm.asks
        let expanded = ask != nil && asks.drawerExpanded
        GeometryReader { geometry in
            let frames = OwnerAskDrawerLayout.frames(
                total: geometry.size.width, drawerWidth: CGFloat(liveWidth ?? asks.drawerWidth),
                hasDrawer: ask != nil, expanded: expanded
            )
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

    private var asks: OwnerAsksViewModel { vm.asks }

    /// Input goes to the draft only while the ask is open and no answer is
    /// being written (`OwnerAsksViewModel.editDraft`).
    private var editable: Bool { ask.isOpen && !asks.answering.contains(ask.id) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let notice = asks.notices[ask.id] {
                        noticeRow(notice)
                    }
                    OwnerAskHeaderCard(ask: ask)
                    if !ask.payload.questions.isEmpty {
                        ChatQuestionCardView(
                            card: ChatQuestionCard(questions: ask.payload.questions),
                            answerText: nil,
                            onAnswer: nil,
                            draftPicks: picksBinding,
                            editable: editable
                        )
                    }
                    kindBody
                    noteView
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            OwnerAskAnswerBar(
                asks: asks,
                ask: ask,
                statusLine: OwnerAskPresentation.statusLine(ask, replacedBy: asks.replacements[ask.projectID]?[ask.id])
            )
        }
        .background(Color(nsColor: .textBackgroundColor))
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
                if !asks.drawerExpanded { NSApp.keyWindow?.makeFirstResponder(nil) }
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
        case .review: reviewBody
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

    /// The snapshot the agent asked about, as plain text.
    private var reviewBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !ask.docPath.isEmpty {
                Label(ask.docPath, systemImage: "doc.text").font(.caption).foregroundStyle(.secondary)
            }
            Text(ask.docSnapshot)
                .font(.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
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
