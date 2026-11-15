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
    /// The bar's merged share after the done share
    /// (`WorkbenchesViewModel.reportMergedProgress`, board #986); 0 = the
    /// plain bar.
    var reportMergedProgress: Double = 0
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
    /// The mode a workbench agent session opens in (#711): `.terminal` or
    /// `.chat` (Workchat); nil = no glyph (a standalone terminal or a shell).
    var opensIn: WorkspaceView?

    private var session: TerminalSession { row.session }

    /// The state dot's column; the details line starts under the title.
    private static let dotColumn: CGFloat = 16
    private static let dotGap = Spacing.compact

    /// The details line has text to show. A running standalone terminal has
    /// none: its row stays one line, the controls beside the title. Lists
    /// the fields `opener` draws; a new one there is added here too.
    private var hasDetailText: Bool {
        row.caption != nil || row.place != nil || row.badge != nil || row.agentTag != nil || opensIn != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            HStack(spacing: Spacing.small) {
                titleLine
                if !hasDetailText { trailingControls }
            }
            if hasDetailText {
                HStack(spacing: Spacing.small) {
                    opener
                        .padding(.leading, Self.dotColumn + Self.dotGap)
                        .opensSession(session, row: row, actions: actions)
                        .accessibilityHidden(true)
                    trailingControls
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
        .contextMenu { contextMenu }
    }

    /// The dot and the title across the row's whole width; VoiceOver reads
    /// it as the row's one named open control (`accessibleOpener`).
    private var titleLine: some View {
        HStack(spacing: Self.dotGap) {
            SessionLiveDot(state: row.state)
                .frame(width: Self.dotColumn)
                // The state label reads the state out.
                .accessibilityHidden(row.showsStateLabel)
            Text(session.title)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .opensSession(session, row: row, actions: actions)
        .accessibilityRepresentation { accessibleOpener }
    }

    /// The ask counts, Review Branch and the ✕: buttons of their own, outside
    /// the open click.
    @ViewBuilder private var trailingControls: some View {
        if openAsks > 0 {
            Text("\(openAsks)")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, Spacing.small)
                .background(Fill.on, in: Capsule())
                .help("\(openAsks) open ask\(openAsks == 1 ? "" : "s")")
                .accessibilityLabel("\(openAsks) open ask\(openAsks == 1 ? "" : "s")")
        }
        closedAsks
        if showsDelete {
            hoverButtons
        } else {
            // Laid out unseen with no width: the line keeps the buttons'
            // height, so hovering never grows the row under the pointer.
            HStack(spacing: Spacing.small) { hoverButtons }
                .fixedSize()
                .hidden()
                .frame(width: 0)
        }
    }

    /// Review Branch on a Ready-to-check row and the ✕, shown on hover.
    @ViewBuilder private var hoverButtons: some View {
        if row.state.kind == .readyToCheck, session.projectID != nil, let reviewChanges = actions.reviewChanges {
            Button("Review Branch") { reviewChanges(session) }
                .buttonStyle(.kitQuiet)
                .help("Review this session's branch")
        }
        if let quickDelete {
            SessionRowDeleteButton {
                deleteButtonTakesKeyboard?()
                quickDelete()
            }
        }
    }

    @ViewBuilder private var contextMenu: some View {
        Button("Rename…") { actions.rename(session) }
        if let projectID = session.projectID, session.kind.isAgent, let setTarget = actions.setTarget {
            Menu(SessionTargetMenu.title) {
                SessionTargetMenuItems(
                    items: SessionTargetMenu.items(roots: actions.targetRoots(projectID), current: session.targetID)
                ) { setTarget(session, $0) }
            }
        }
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
        if session.projectID != nil, let reviewChanges = actions.reviewChanges {
            Button("Review Branch") { reviewChanges(session) }
        }
        if session.projectID != nil, session.kind.isAgent, let openIn = actions.openIn {
            Button("Open in Terminal") { openIn(session, false) }
            Button("Open in Workchat") { openIn(session, true) }
        }
        Divider()
        Button("Delete…", role: .destructive) { actions.delete(session) }
    }

    /// The details under the title: the state label and report line (or a
    /// standalone terminal's caption), place, badge, agent tag and the mode
    /// glyph.
    private var opener: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                if row.showsStateLabel, let caption = row.caption {
                    SessionStateLabel(state: row.state, caption: caption)
                    if let reportLine {
                        HStack(spacing: 4) {
                            if let reportProgress, reportMergedProgress > 0 {
                                SessionProgressMiniBar(done: reportProgress, merged: reportMergedProgress)
                                    .frame(width: 32)
                                    .accessibilityLabel("Progress")
                            } else if let reportProgress {
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
                if let tag = row.agentTag { OutlineTag(text: tag) }
            }
            Spacer(minLength: 0)
            if let opensIn {
                Image(systemName: opensIn.icon)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("Opens in \(opensIn.title)")
                    .accessibilityLabel("Opens in \(opensIn.title)")
            }
        }
    }

    /// VoiceOver gets one named session control while the visible title
    /// and details open independently of the closed-asks button. The control
    /// sits on the title line; the details line is hidden from VoiceOver.
    private var accessibleOpener: some View {
        VStack(alignment: .leading) {
            SessionLiveDot(state: row.state)
                // The state label reads the state out.
                .accessibilityHidden(row.showsStateLabel)
            Text(session.title)
            if hasDetailText { opener }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(hasCursor ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { actions.open(session) }
        .accessibilityActions {
            if let quickDelete { Button("Delete session", action: quickDelete) }
        }
    }
}

private extension View {
    /// A click opens the session (a not running one starts); both lines of
    /// the row carry it, its buttons do not.
    func opensSession(
        _ session: TerminalSession,
        row: SessionSwitcherPresentation.Row,
        actions: SessionRowActions
    ) -> some View {
        contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded { actions.open(session) })
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
            .font(.system(size: IconSize.stateDot))
            .foregroundStyle(SessionStatePresentation.color(for: state).color)
            // Background agents run: the dot pulses; Reduce Motion keeps it still.
            .symbolEffect(.pulse, isActive: SessionStatePresentation.pulses(state) && !reduceMotion)
            .accessibilityLabel(SessionStatePresentation.caption(for: state))
    }
}

/// A session's state glyph and caption ("? Waiting for you · ask #12"),
/// where a site has room for more than the dot: the panel row, the session
/// strip, the header switcher button and its popover rows. One accessibility
/// element reading the caption; a session the Mac cannot watch ("Working ·
/// not watched", U6) names the reason in its tooltip.
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
        .help(SessionStatePresentation.watchIssueHelp(for: state) ?? "")
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

/// The submenu's items: a checkmark on the current one, a group as a
/// submenu whose first item is the group itself.
private struct SessionTargetMenuItems: View {
    let items: [SessionTargetMenu.Item]
    let choose: (Int64?) -> Void

    var body: some View {
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
            switch item {
            case let .none(checked):
                entry(SessionTargetMenu.noneTitle, checked: checked) { choose(nil) }
            case let .target(id, title, checked, children):
                if children.isEmpty {
                    entry(title, checked: checked) { choose(id) }
                } else {
                    Menu(title) { Self(items: children, choose: choose) }
                }
            }
        }
    }

    private func entry(_ title: String, checked: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if checked {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }
}

/// A session row's mini bar with a merged share (board #986): the done share
/// in the accent colour, then the merged share lighter, on the track.
private struct SessionProgressMiniBar: View {
    /// 0...1.
    let done: Double
    /// 0...1; done + merged is capped at the bar's end.
    let merged: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Fill.card)
                Capsule().fill(Fill.on)
                    .frame(width: geo.size.width * min(1, max(0, done + merged)))
                Capsule().fill(Color.accentColor)
                    .frame(width: geo.size.width * min(1, max(0, done)))
            }
        }
        .frame(height: 4)
        .accessibilityElement(children: .ignore)
        .accessibilityValue(SessionReportPresentation.miniBarValue(done: done, merged: merged))
    }
}
