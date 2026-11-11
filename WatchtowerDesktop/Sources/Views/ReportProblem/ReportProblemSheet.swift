import AppKit
import DesignKit
import SwiftUI
import UniformTypeIdentifiers
import WatchtowerCore

/// Presents Help → Report a Problem…'s one sheet on the main window (#1527).
/// Every way it goes away — Cancel/Done, Esc, the binding cleared by
/// SwiftUI, the window closing under it — ends in `closeReportProblem`.
struct ReportProblemSheetHost: ViewModifier {
    @Bindable var appState: AppState

    func body(content: Content) -> some View {
        content.sheet(item: presented) { model in
            Self.sheet(for: model, appState: appState)
        }
    }

    /// The presented sheet with both of its close paths: the Cancel/Done
    /// button (Esc presses it) and `onDisappear` when the window goes away
    /// under it. Internal so the dismissal tests host exactly this view.
    static func sheet(for model: ReportProblemModel, appState: AppState) -> some View {
        ReportProblemSheet(model: model) { appState.closeReportProblem(model) }
            // The mockups' width; the buttons stack when it is narrower.
            .frame(minWidth: 360, idealWidth: 600, maxWidth: 600)
            .onDisappear { appState.closeReportProblem(model) }
    }

    /// Internal for the dismissal test.
    var presented: Binding<ReportProblemModel?> {
        Binding(
            get: { appState.reportProblemModel },
            set: { next in
                guard next == nil, let shown = appState.reportProblemModel else { return }
                appState.closeReportProblem(shown)
            }
        )
    }
}

/// The Report a Problem sheet: renders `ReportProblemModel`, owns no logic.
/// Every string comes from `ReportProblemCopy` or the model.
struct ReportProblemSheet: View {
    let model: ReportProblemModel
    let close: () -> Void
    /// The window's link gate (`AllowedURLSchemes`), as `Link`s use it.
    @Environment(\.openURL) private var openURL

    private typealias Copy = ReportProblemCopy

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.large) {
            VStack(alignment: .leading, spacing: Spacing.small) {
                Text(Copy.title).font(.title3.weight(.semibold))
                Text(model.isCorp ? Copy.corpIntro : Copy.intro)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            field
            diagnostics
            notice
            if !model.isCorp {
                VStack(alignment: .leading, spacing: Spacing.small) {
                    Text(Copy.publicNote).font(.caption).foregroundStyle(.secondary)
                    Button(Copy.discussionsLink) { openURL(ReleaseLinks.discussions) }
                    .buttonStyle(.kitQuiet)
                }
            }
            buttons
        }
        .controlSize(.small)
        .padding(Spacing.page)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .detailBackground()
        // No start here: `AppState.reportProblem()` starts the one run, and a
        // failed run collects again only on Retry.
    }

    // MARK: - What happened?

    private var field: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: Spacing.small) {
            Text(Copy.fieldLabel).font(.headline)
            ZStack(alignment: .topLeading) {
                TextEditor(text: $model.text)
                    .font(.body)
                    .accessibilityLabel(Copy.fieldLabel)
                    .scrollContentBackground(.hidden)
                    .frame(height: 72)
                if model.text.isEmpty {
                    Text(model.isCorp ? Copy.corpFieldPlaceholder : Copy.fieldPlaceholder)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, Spacing.small)
                        .allowsHitTesting(false)
                }
            }
            .padding(Spacing.regular)
            .card()
            if model.showsFieldRequired {
                Text(Copy.fieldRequired).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Diagnostics block

    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Text(Copy.blockTitle).font(.headline)
            Text(Copy.blockCaption).font(.caption).foregroundStyle(.secondary)
            Group {
                switch model.phase {
                case .collecting:
                    HStack(spacing: Spacing.regular) {
                        ProgressView().controlSize(.small)
                        Text(Copy.loading).font(.caption).foregroundStyle(.secondary)
                    }
                case .failed(let reason):
                    VStack(alignment: .leading, spacing: Spacing.regular) {
                        HStack(alignment: .top, spacing: Spacing.regular) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Tone.warning)
                            Text(Copy.failed(reason)).font(.caption).fixedSize(horizontal: false, vertical: true)
                        }
                        Text(model.diagnosticsText).font(.caption.monospaced()).textSelection(.enabled)
                        Button(Copy.retry) { model.retry() }.buttonStyle(.kitSecondary)
                    }
                case .ready:
                    Text(model.diagnosticsText)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(Spacing.medium)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
        }
    }

    // MARK: - Notice

    @ViewBuilder private var notice: some View {
        if let text = model.noticeText {
            VStack(alignment: .leading, spacing: Spacing.regular) {
                HStack(alignment: .top, spacing: Spacing.regular) {
                    Image(systemName: noticeIcon).foregroundStyle(noticeIsGood ? Tone.success : Tone.warning)
                    Text(text).font(.caption).fixedSize(horizontal: false, vertical: true)
                }
                if model.offersCopyReport || model.offersCopyLink {
                    HStack(spacing: Spacing.regular) {
                        if model.offersCopyReport {
                            Button(Copy.copyReport) { model.copyReport() }.buttonStyle(.kitSecondary)
                        }
                        if model.offersCopyLink {
                            Button(Copy.copyLink) { model.copyLink() }.buttonStyle(.kitSecondary)
                        }
                    }
                }
            }
        }
    }

    private var noticeIsGood: Bool {
        switch model.notice {
        case .opened, .copied: true
        case .none, .tooLong, .browserFailed, .saveFailed: false
        }
    }

    private var noticeIcon: String {
        switch model.notice {
        case .opened, .copied: "checkmark.circle.fill"
        case .tooLong: "doc.on.clipboard"
        case .none, .browserFailed, .saveFailed: "exclamationmark.triangle.fill"
        }
    }

    // MARK: - Buttons

    private var buttons: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Spacing.regular) {
                Spacer(minLength: 0)
                buttonSet
            }
            VStack(alignment: .trailing, spacing: Spacing.regular) {
                buttonSet
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    @ViewBuilder private var buttonSet: some View {
        Button(model.afterOpen ? Copy.done : Copy.cancel, action: close)
            .buttonStyle(.kitQuiet)
            .keyboardShortcut(.cancelAction)
        if model.isCorp {
            Button(Copy.saveDiagnostics, action: save)
                .buttonStyle(.kitPrimary)
                .disabled(!model.canSave)
        } else {
            Button(Copy.saveDiagnostics, action: save)
                .buttonStyle(.kitSecondary)
                .disabled(!model.canSave)
            Button(Copy.openIssue) { model.openIssue() }
                .buttonStyle(.kitPrimary)
                .disabled(!model.canOpen)
        }
    }

    /// Save Diagnostics…: the system save panel, then one atomic write.
    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = ReportProblemModel.saveFileName(on: Date())
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.save(to: url)
    }
}
