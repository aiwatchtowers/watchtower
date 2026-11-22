import SwiftUI
import WatchtowerCore

/// The arm sheet (spec 2026-11-16 §2, §5, D21; tuning spec 2026-11-21 §2):
/// every hand-over opens it so the owner can give the session an
/// instruction. A first hand-over shows what turns on and what learning
/// costs, what stays the owner's, what is not caught and the warnings to arm
/// knowing; later ones only the session and the field; the tray's lists the
/// sessions; Instruction… edits the text (Save). The field has focus,
/// Return confirms, ⌥Return adds a line. A short blocking flow, so a sheet.
struct WatchmanArmSheet: View {
    let content: WatchmanArmSheetContent
    /// The confirm runs (the check again, the arm, the save): the field and
    /// the buttons wait, the confirm shows a spinner.
    var busy = false
    /// The last confirm's failure: `Could not save: …` with Retry.
    var error: String?
    let onCancel: () -> Void
    let onConfirm: (String) -> Void

    @State private var text: String
    @FocusState private var fieldFocused: Bool

    init(
        content: WatchmanArmSheetContent,
        instruction: String = "",
        busy: Bool = false,
        error: String? = nil,
        onCancel: @escaping () -> Void,
        onConfirm: @escaping (String) -> Void
    ) {
        self.content = content
        self.busy = busy
        self.error = error
        self.onCancel = onCancel
        self.onConfirm = onConfirm
        _text = State(initialValue: WatchmanArmingCopy.clipped(instruction))
    }

    /// At most six rows show; more scroll.
    static let visibleRows = 6

    static func listHeight(rows: Int) -> CGFloat {
        CGFloat(min(rows, visibleRows)) * ListLayout.lineMinHeight
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.large) {
            VStack(alignment: .leading, spacing: Spacing.small) {
                Text(content.title).font(.title3.weight(.semibold))
                if let notice = content.notice {
                    line(icon: "arrow.triangle.2.circlepath", tone: Tone.warning, text: notice)
                }
                if let body = content.body {
                    Text(body).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                if let subject = content.subject {
                    Label(subject, systemImage: "terminal").font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                if !content.sessions.isEmpty { sessionList }
            }
            if !content.lines.isEmpty {
                VStack(alignment: .leading, spacing: Spacing.medium) {
                    ForEach(content.lines, id: \.self) { line(icon: $0.icon, tone: .secondary, text: $0.text) }
                }
                .padding(Spacing.medium)
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
            }
            ForEach(content.warnings, id: \.self) { warning in
                line(icon: "exclamationmark.triangle.fill", tone: Tone.warning, text: warning)
                    .padding(Spacing.medium)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Tone.warning.opacity(ChipTint.fillOpacity), in: RoundedRectangle(cornerRadius: Radius.row))
            }
            field
            HStack(spacing: Spacing.regular) {
                Spacer()
                Button(content.cancel, action: onCancel)
                    .buttonStyle(.kitSecondary)
                    .keyboardShortcut(.cancelAction)
                    .disabled(busy)
                Button(action: confirm) {
                    HStack(spacing: Spacing.small) {
                        if busy { ProgressView().controlSize(.mini) }
                        Text(content.confirm)
                    }
                }
                .buttonStyle(.kitPrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(busy)
            }
        }
        .controlSize(.small)
        .padding(Spacing.page)
        .frame(width: PaneWidth.narrowPage + Spacing.hero, alignment: .topLeading)
        .interactiveDismissDisabled(busy)
        .onAppear { fieldFocused = true }
        // A failed save gives the field back (it was disabled while busy).
        .onChange(of: busy) { _, running in if !running, error != nil { fieldFocused = true } }
    }

    private var sessionList: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Text(WatchmanArmingCopy.sessionsHeader(content.sessions.count)).font(.callout.weight(.semibold))
            // A long list scrolls (about six rows); the buttons stay on screen.
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(content.sessions, id: \.self) { session in
                        Text(session).font(.callout).lineLimit(1).frame(minHeight: ListLayout.lineMinHeight)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: Self.listHeight(rows: content.sessions.count))
        }
    }

    /// The instruction: Return confirms, ⌥Return adds a line; at most 2000
    /// characters, the count past 1800; the failure line with Retry.
    private var field: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Text(content.fieldLabel).font(.headline)
            ZStack(alignment: .topLeading) {
                TextField("", text: Binding(get: { text }, set: { text = WatchmanArmingCopy.clipped($0) }),
                          axis: .vertical)
                    .textFieldStyle(.kit)
                    .lineLimit(3...8)
                    .focused($fieldFocused)
                    .onSubmit(confirm)
                    .disabled(busy)
                if text.isEmpty {
                    Text(content.placeholder)
                        .font(.body)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, Spacing.compact)
                        .padding(.vertical, Spacing.small)
                        .allowsHitTesting(false)
                }
            }
            if let counter = WatchmanArmingCopy.counter(for: text) {
                Text(counter)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            if let error {
                HStack(spacing: Spacing.small) {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Tone.warning)
                        .lineLimit(2)
                        .help(error)
                    Button(WatchmanArmingCopy.retry, action: confirm)
                        .buttonStyle(.kitQuiet)
                        .fixedSize()
                        .disabled(busy)
                }
            }
        }
    }

    private func confirm() {
        guard !busy else { return }
        onConfirm(text)
    }

    private func line(icon: String, tone: Color, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
            Image(systemName: icon).foregroundStyle(tone).frame(width: IconSize.composer)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Presents the arm sheet over the main window, whichever screen is on it:
/// a strip, a target panel or the tray asked for it (`WatchmanCenter.sheet`).
struct WatchmanArmSheetHost: ViewModifier {
    let center: WatchmanCenter?

    func body(content: Content) -> some View {
        content.sheet(item: Binding(get: { center?.sheet }, set: { if $0 == nil { center?.sheet = nil } })) { request in
            WatchmanArmSheet(
                content: request.content,
                instruction: request.instruction,
                busy: center?.confirming ?? false,
                error: center?.sheetError,
                onCancel: { center?.sheet = nil },
                onConfirm: { [token = request.token] text in
                    Task { await center?.confirmSheet(token: token, instruction: text) }
                }
            )
        }
    }
}
