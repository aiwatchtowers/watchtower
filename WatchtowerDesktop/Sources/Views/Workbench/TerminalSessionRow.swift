import SwiftUI
import WatchtowerCore

/// One terminal session in the panel: its state dot, its state label
/// ("Stopped", "Not running · 5m"; a standalone terminal's plain caption),
/// a workbench session's report line ("#314 · 14/15 · PR #147 open"),
/// where its agent works (#565), and the target it works on. A workbench's
/// rows also count the session's open asks and offer "▸ N closed"; that
/// button sits outside the row's open click, which would start the session.
struct TerminalSessionRow: View {
    let row: SessionSwitcherPresentation.Row
    let actions: SessionRowActions
    var openAsks = 0
    /// The session report's line (`WorkbenchesViewModel.reportLine`); a
    /// standalone terminal has none.
    var reportLine: String?
    /// The line's mini progress bar (`WorkbenchesViewModel.reportProgress`).
    var reportProgress: Double?
    var closedAsks: OwnerAskClosedButton?
    /// Deletes the row at once with Undo; set only when its agent is not
    /// working (`SessionDeletePolicy.isQuick`, board #480). VoiceOver offers
    /// it as an action; the ✕ shows while `showsDelete`.
    var quickDelete: (() -> Void)?
    /// A click on the ✕ (not VoiceOver's action) hands the keyboard to the
    /// sessions panel first, so ⌘⌫ goes on from the neighbour.
    var deleteButtonTakesKeyboard: (() -> Void)?
    /// The row is hovered or under the panel cursor.
    var showsDelete = false
    /// The panel has the keyboard and its cursor is on this row.
    var hasCursor = false

    private var session: TerminalSession { row.session }

    var body: some View {
        HStack(spacing: 4) {
            opener
            if openAsks > 0 {
                Text("\(openAsks)")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 5)
                    .background(Color.accentColor.opacity(0.2), in: Capsule())
                    .help("\(openAsks) open ask\(openAsks == 1 ? "" : "s")")
                    .accessibilityLabel("\(openAsks) open ask\(openAsks == 1 ? "" : "s")")
            }
            closedAsks
            if showsDelete, let quickDelete {
                SessionRowDeleteButton {
                    deleteButtonTakesKeyboard?()
                    quickDelete()
                }
            }
        }
        .overlay {
            if hasCursor {
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(-3)
                    .allowsHitTesting(false)
            }
        }
        .listRowSeparator(.hidden)
        .contextMenu {
            Button("Rename…") { actions.rename(session) }
            if session.projectID != nil, let cleanUp = actions.cleanUp {
                Button("Clean Up…") { cleanUp(session) }
            }
            // A placed session's folder is its worktree (spec 2026-10-14
            // §7, D9); shown only while the directory exists.
            if session.worktreeBranch != nil, FileManager.default.fileExists(atPath: session.folderPath) {
                Button("Show Worktree in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: session.folderPath)])
                }
            }
            Divider()
            Button("Delete…", role: .destructive) { actions.delete(session) }
        }
    }

    private var opener: some View {
        HStack(spacing: 6) {
            SessionLiveDot(state: row.state)
                .frame(width: 16)
                // The label below reads the state out.
                .accessibilityHidden(row.showsStateLabel)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.title).lineLimit(1).truncationMode(.tail)
                if row.showsStateLabel, let caption = row.caption {
                    SessionStateLabel(state: row.state, caption: caption)
                    if let reportLine {
                        HStack(spacing: 4) {
                            if let reportProgress {
                                ProgressView(value: reportProgress)
                                    .progressViewStyle(.linear)
                                    .controlSize(.mini)
                                    .frame(width: 32)
                                    .accessibilityLabel("Progress")
                            }
                            Text(reportLine)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                } else if let caption = row.caption {
                    // A standalone terminal's caption repeats the dot's label
                    // for VoiceOver, except a not started one's age.
                    Text(caption)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .accessibilityHidden(row.state.kind != .notStarted)
                }
                if let place = row.place { SessionPlaceLine(label: place) }
                if let badge = row.badge {
                    Text(badge).font(.caption2).foregroundStyle(.secondary)
                }
                if let tag = row.agentTag { AgentTag(text: tag) }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { actions.open(session) })
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(hasCursor ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { actions.open(session) }
        .accessibilityActions {
            if let quickDelete { Button("Delete session", action: quickDelete) }
        }
        .help(row.state.live ? session.title : "Not running — click to start")
    }
}

/// A session's state dot (`SessionStatePresentation`): its kind's colour,
/// filled while its process runs and a ring when not — the panel's rows,
/// both session switchers and the go-to palette draw the same one. Its
/// accessibility label is the state's caption.
struct SessionLiveDot: View {
    let state: SessionSwitcherPresentation.State
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: SessionStatePresentation.isRing(state) ? "circle" : "circle.fill")
            .font(.system(size: 7))
            .foregroundStyle(SessionStatePresentation.color(for: state).color)
            // Background agents run: the dot pulses; Reduce Motion keeps it still.
            .symbolEffect(.pulse, isActive: SessionStatePresentation.pulses(state) && !reduceMotion)
            .accessibilityLabel(SessionStatePresentation.caption(for: state))
    }
}

/// A session's state glyph and caption ("? Waiting for you · ask #12"),
/// where a site has room for more than the dot: the panel row, the header
/// switcher button and its popover rows. One accessibility element reading
/// the caption.
struct SessionStateLabel: View {
    let state: SessionSwitcherPresentation.State
    /// The row's caption (with a not started session's age), else the
    /// state's own.
    var caption: String?

    var body: some View {
        let text = caption ?? SessionStatePresentation.caption(for: state)
        HStack(spacing: 3) {
            if let glyph = SessionStatePresentation.glyph(for: state) {
                Image(systemName: glyph)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(SessionStatePresentation.color(for: state).color)
                // The ask count beside `questionmark` / `checklist`, never a 0 beside `person.2.fill`.
                if state.kind == .working || (state.kind == .background && state.openAsks > 0) {
                    Text("\(state.openAsks)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(SessionStatePresentation.color(for: state).color)
                }
            }
            Text(text)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

extension SessionStatePresentation.Tone {
    /// The system colour of a state's tone, light and dark.
    var color: Color {
        switch self {
        case .green: .green
        case .orange: .orange
        case .blue: .blue
        case .red: .red
        case .purple: .purple
        case .secondary: .secondary
        }
    }
}
