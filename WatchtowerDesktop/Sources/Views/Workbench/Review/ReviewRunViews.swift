import SwiftUI
import WatchtowerCore

/// A failed AI step (a chapter, the summary, the whole run; board #1025): the
/// owner's sentence, optional lines under it, the provider's own text behind a
/// **Provider's message** disclosure (folded by default) and **Retry**.
struct ReviewFailureNotice: View {
    let text: String
    var lines: [String] = []
    var detail: String?
    let retry: () -> Void
    /// The disclosure's state when the caller holds it (a test); nil = the view's own.
    var expanded: Binding<Bool>?
    @State private var ownExpanded = false

    private var isExpanded: Binding<Bool> { expanded ?? $ownExpanded }

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.compact) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Tone.warning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.small) {
                Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
                ForEach(lines, id: \.self) { line in
                    Text(line).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let detail, !detail.isEmpty {
                    Button {
                        withAnimation(Motion.toggle) { isExpanded.wrappedValue.toggle() }
                    } label: {
                        Label("Provider's message", systemImage: isExpanded.wrappedValue ? "chevron.down" : "chevron.right")
                            .font(.caption)
                    }
                    .buttonStyle(.kitQuiet)
                    .accessibilityHint(isExpanded.wrappedValue ? "Hides the provider's own text" : "Shows the provider's own text")
                    if isExpanded.wrappedValue {
                        Text(detail)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Spacer(minLength: Spacing.small)
            Button("Retry", action: retry).buttonStyle(.kitSecondary).controlSize(.small)
        }
    }
}

/// A chapter's or a file's danger mark from the map: Breaking red, Significant
/// orange; `text` replaces the level's word (a file's signal); normal shows nothing.
struct ReviewDangerBadge: View {
    let level: ReviewDangerLevel
    var text: String?

    var body: some View {
        if let word = text ?? ReviewMapPresentation.levelTitle(level) {
            Chip(text: word, color: level == .breaking ? Tone.error : Tone.warning)
                .lineLimit(1)
                .fixedSize()
                .accessibilityLabel(text.map { "\($0), \(ReviewMapPresentation.levelTitle(level) ?? "")" } ?? word)
        }
    }
}

/// The progress / summary card of the streamed run (mockup frames 1, 1b, 2b):
/// the whole run's failure with Retry, the summary's failure with its own
/// Retry, or how far the run is with **Describe N remaining** once it settled.
struct ReviewRunCard: View {
    let model: ReviewChangesModel
    /// On its own card (the chapter list); false inside a card already (Meaning).
    var framed = true

    var body: some View {
        if case let .failed(text, detail) = model.overview {
            ReviewFailureNotice(text: text, detail: detail) { model.retryOverview() }
                .modifier(RunCardFrame(framed: framed))
        } else if case let .failed(text, detail) = model.summaryState {
            ReviewFailureNotice(text: text, lines: [model.summaryFailedLine], detail: detail) { model.retrySummary() }
                .modifier(RunCardFrame(framed: framed))
        } else if let progress {
            VStack(alignment: .leading, spacing: Spacing.small) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.compact) {
                    if progress.running {
                        ProgressView().controlSize(.mini)
                    }
                    Text(progress.title).font(.callout.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                }
                if let body = progress.body {
                    Text(body).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if progress.remaining > 0 {
                    Button(ReviewMapPresentation.describeRemainingTitle(progress.remaining)) { model.describeRemaining() }
                        .buttonStyle(.kitSecondary)
                        .controlSize(.small)
                        .help("Describe only the chapters the run did not reach, then remake the summary")
                }
            }
            .modifier(RunCardFrame(framed: framed))
        }
    }

    private var progress: ReviewMapPresentation.Progress? {
        ReviewMapPresentation.progress(keys: model.describableKeys, states: model.chapterStates,
                                       summary: model.summaryState, waiting: model.waitingText)
    }
}

private struct RunCardFrame: ViewModifier {
    let framed: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if framed {
            content
                .padding(Spacing.cozy)
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
        } else {
            content
        }
    }
}

/// A chapter row's run line (mockup frames 1, 1b, 2b): Describing…, Queued,
/// Described, Not described yet, or the failure's sentence with Retry.
struct ReviewChapterRunLine: View {
    let model: ReviewChangesModel
    let key: String

    var body: some View {
        let line = ReviewMapPresentation.runLine(model.chapterStates[key], summary: model.summaryState,
                                                 waitingFor: model.waitingFor)
        switch line {
        case .none:
            EmptyView()
        case .described:
            Label(ReviewMapPresentation.text(line), systemImage: "checkmark")
                .font(.caption2)
                .foregroundStyle(Tone.success)
        case .failed:
            HStack(alignment: .firstTextBaseline, spacing: Spacing.small) {
                Text(ReviewMapPresentation.text(line)).font(.caption2).foregroundStyle(Tone.warning)
                Button("Retry") { model.retry(chapter: key) }
                    .buttonStyle(.kitQuiet)
                    .font(.caption2)
                    .help("Describe this chapter again, then remake the summary")
            }
        default:
            Text(ReviewMapPresentation.text(line)).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

/// The current chapter's head over its diff (Deep's Chapters, mockup frames 1
/// and 2b): title, danger, lane, then its description, its failure with
/// **Retry** and the provider's message folded, or where the run stands; the
/// map's signals under it.
struct ReviewChapterHeader: View {
    let model: ReviewChangesModel
    let chapter: ReviewMap.Chapter
    let map: ReviewMap

    /// The head's height before it scrolls, so the diff keeps the pane.
    private static let maxHeight: CGFloat = 180

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.compact) {
                Text(chapter.title).font(.headline).lineLimit(1).truncationMode(.middle)
                ReviewDangerBadge(level: chapter.level)
                Text(ReviewMapPresentation.laneCaption(chapter, files: map.files))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                if let title = laneTitle {
                    Text("“\(title)”").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if chapter.core {
                    Label("core", systemImage: "star.fill").font(.caption2).foregroundStyle(Tone.warning)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.small) { content }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: Self.maxHeight)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Spacing.medium)
        .padding(.vertical, Spacing.regular)
    }

    @ViewBuilder private var content: some View {
        let line = ReviewMapPresentation.runLine(model.chapterStates[chapter.key], summary: model.summaryState,
                                                 waitingFor: model.waitingFor)
        let signals = ReviewMapPresentation.signalsLine(chapter)
        switch line {
        case let .failed(text, detail):
            ReviewFailureNotice(text: failureSentence(text), detail: detail) { model.retry(chapter: chapter.key) }
            Text(notDescribedNote(signals)).font(.caption).foregroundStyle(.secondary)
        case .notDescribed:
            Text(ReviewMapPresentation.notDescribedText).font(.callout).foregroundStyle(.secondary)
            Text(notDescribedNote(signals)).font(.caption).foregroundStyle(.secondary)
        default:
            if let what = model.chapterDescription(chapter.key) {
                Text("What it does").font(.caption.weight(.semibold))
                Text(what).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            } else if line != .none {
                Text(ReviewMapPresentation.text(line)).font(.callout).foregroundStyle(.secondary)
            }
            if !signals.isEmpty {
                Text("Signals: \(signals)").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// The lane's ticket title, when the map found one other than its name.
    private var laneTitle: String? {
        guard let lane = chapter.lane, let found = map.lanes.first(where: { $0.name == lane }),
              found.title != lane, found.title != chapter.title else { return nil }
        return found.title
    }

    /// Once the summary is in, a failed chapter says it does not cover it.
    private func failureSentence(_ text: String) -> String {
        guard text == ReviewMapPresentation.notCoveredText,
              case let .failed(original, _)? = model.chapterStates[chapter.key] else { return text }
        return "\(text). \(original)"
    }

    private func notDescribedNote(_ signals: String) -> String {
        let lead = signals.isEmpty ? "No signals without AI." : "Signals without AI: \(signals)."
        return lead + " The summary saw this chapter's title, files and signals only. "
            + "Read it yourself, or hand it to the author with a design comment."
    }
}
