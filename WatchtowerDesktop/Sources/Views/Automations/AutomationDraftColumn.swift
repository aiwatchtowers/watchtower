import SwiftUI
import WatchtowerCore

/// The draft column beside the editor chat and the form (spec A4): every
/// field the save confirms, from `AutomationDraftColumnModel`. The footer
/// (Save and Turn On / Save Turned Off, `AutomationDraftFooter`) sits under
/// it in the editor panel, and is off unless `model.showsAllFields`. The
/// paused auto grants start unchecked (AUTO-03).
struct AutomationDraftColumn: View {
    let model: AutomationDraftColumnModel
    @Binding var keepAuto: Set<String>
    /// **Dry Run Again**; nil hides it (no chat, or a busy one).
    let onDryRunAgain: (() -> Void)?
    /// Names the read-only recipe page's model; unique on screen.
    var recipeModelID: Int64 = -1
    /// True inside a page that scrolls and pads itself (the template
    /// panel's file columns): no scroll view and no padding of its own.
    var embedded = false
    /// False where nothing is dry-run (a template's rendered file).
    var showsDryRun = true

    var body: some View {
        if embedded {
            content
        } else {
            ScrollView { content.padding(Spacing.large) }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            statusLine
            box(title: "When", systemImage: "clock") {
                Text(model.when).fontWeight(.semibold)
                if let detail = model.whenDetail { secondary(detail) }
            }
            box(title: "It may", systemImage: "checkmark.shield") {
                if let placeholder = model.placeholder {
                    secondary(placeholder)
                } else if model.mayDo.isEmpty {
                    secondary("Nothing beyond its own state")
                }
                ForEach(Array(model.mayDo.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
                        Text(line.text).fixedSize(horizontal: false, vertical: true)
                        if line.isNew {
                            Chip(text: AutomationDraftColumnModel.newMark, color: Tone.warning)
                        }
                    }
                }
            }
            box(title: "Sends", systemImage: "paperplane") {
                if let placeholder = model.placeholder {
                    secondary(placeholder)
                } else if model.sends.isEmpty {
                    secondary("Nothing")
                }
                ForEach(Array(model.sends.enumerated()), id: \.offset) { _, line in Text(line) }
            }
            HStack(alignment: .top, spacing: Spacing.medium) {
                box(title: "Each run", systemImage: "gauge.with.dots.needle.33percent") {
                    Text(model.eachRun)
                }
                box(title: "Missed and Concurrency", systemImage: "arrow.triangle.2.circlepath") {
                    Text(model.missedAndConcurrency).fixedSize(horizontal: false, vertical: true)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            if !model.changes.isEmpty {
                box(title: "Changed", systemImage: "arrow.left.arrow.right") {
                    ForEach(Array(model.changes.enumerated()), id: \.offset) { _, line in
                        Text(line).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if showsDryRun { dryRunBox }
            if !model.sessions.isEmpty { AutomationSessionPromptsBlock(sessions: model.sessions) }
            recipe
            if !model.pausedGrants.isEmpty { pausedGrants }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var statusLine: some View {
        switch model.status {
        case .checking:
            HStack(spacing: Spacing.regular) {
                ProgressView().controlSize(.small)
                Text("Checking…").font(.caption).foregroundStyle(.secondary)
            }
        case .invalid:
            VStack(alignment: .leading, spacing: Spacing.small) {
                Label("The draft has errors", systemImage: "exclamationmark.octagon")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Tone.error)
                ForEach(Array(model.errors.enumerated()), id: \.offset) { _, error in
                    Text(error).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.medium)
            .card()
        case .ready:
            EmptyView()
        }
    }

    private var dryRunBox: some View {
        box(title: "Dry run · nothing was written", systemImage: "play.circle") {
            ForEach(Array(model.dryRunLines.enumerated()), id: \.offset) { _, line in
                Text(line).fixedSize(horizontal: false, vertical: true)
            }
            if let note = model.dryRunNote { secondary(note) }
            if let onDryRunAgain {
                Button("Dry Run Again", action: onDryRunAgain)
                    .buttonStyle(.kitSecondary)
                    .controlSize(.small)
            }
        }
    }

    /// **Show recipe**, in place: the whole text read-only for a new recipe,
    /// the lines changed since the confirmed one for an edit.
    @ViewBuilder private var recipe: some View {
        if let diff = model.recipeDiff {
            DisclosureGroup("Show recipe") {
                VStack(alignment: .leading, spacing: 0) {
                    if diff.isIdentical { secondary("No change to the recipe text") }
                    ForEach(Array(diff.lines.enumerated()), id: \.offset) { _, line in diffRow(line) }
                }
                .padding(.top, Spacing.small)
            }
        } else {
            RecipeTextDisclosure(title: "Show recipe", text: model.recipeText, modelID: recipeModelID,
                                 contentHash: "draft-\(model.recipeText.hashValue)", slug: "recipe")
        }
    }

    private var pausedGrants: some View {
        box(title: "Auto paused by this change", systemImage: "pause.circle") {
            secondary("These tools ran without asking. After this change they ask first, unless you keep auto.")
            ForEach(model.pausedGrants, id: \.self) { tool in
                Toggle("Keep auto for \(tool)", isOn: keepBinding(tool))
                    .toggleStyle(.checkbox)
            }
            if let warning = model.llmWarning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Tone.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func box(title: String, systemImage: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Spacing.compact) {
            SectionHeader(title: title, systemImage: systemImage)
            content()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(Spacing.medium)
        .card()
    }

    private func secondary(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func diffRow(_ line: OwnerAskSnapshotDiff.Line) -> some View {
        let (mark, text, tint): (String, String, Color?) = switch line {
        case let .same(text): (" ", text, nil)
        case let .added(text): ("+", text, Tone.success)
        case let .removed(text): ("−", text, Tone.error)
        }
        return HStack(alignment: .top, spacing: Spacing.compact) {
            Text(mark).foregroundStyle(tint ?? .secondary)
            Text(text.isEmpty ? " " : text).foregroundStyle(tint == nil ? .secondary : .primary)
        }
        .font(.system(.caption, design: .monospaced))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.map { $0.opacity(ChipTint.fillOpacity) } ?? .clear)
        .textSelection(.enabled)
    }

    private func keepBinding(_ tool: String) -> Binding<Bool> {
        Binding(
            get: { keepAuto.contains(tool) },
            set: { on in
                if on { keepAuto.insert(tool) } else { keepAuto.remove(tool) }
            }
        )
    }
}

/// "Sessions it starts": every `session()`/`agent()` call of a dry run with
/// the prompt it hands over, so an instruction hidden there is seen before
/// the save (the draft column and the `save_automation` card).
struct AutomationSessionPromptsBlock: View {
    static let title = "Sessions it starts"

    let sessions: [AutomationSessionPrompt]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            SectionHeader(title: Self.title, systemImage: "terminal", count: sessions.count)
            ForEach(Array(sessions.enumerated()), id: \.offset) { offset, session in
                // Identity from content as well as position: a changed draft
                // must not carry one session's expanded state onto another.
                AutomationSessionPromptRow(session: session)
                    .id("\(offset)|\(session.title)|\(session.prompt?.hashValue ?? 0)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.medium)
        .card()
    }
}

/// One session: its title, then its prompt in two lines; **Show all** when
/// the two lines cut it (measured, so no prompt is cut without a way to
/// read the rest).
private struct AutomationSessionPromptRow: View {
    static let unavailable = "(prompt not available)"

    let session: AutomationSessionPrompt
    @State private var expanded = false
    @State private var truncated = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            Text(session.title).font(.callout.weight(.semibold))
            if let prompt = session.prompt {
                Text(prompt)
                    .lineLimit(expanded ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .background { if !expanded { measure(prompt) } }
                if truncated || expanded {
                    Button(expanded ? "Show less" : "Show all") { expanded.toggle() }
                        .buttonStyle(.kitQuiet)
                        .controlSize(.small)
                }
                if session.isCut {
                    Text(AutomationCardPresentation.cutInstructionLine).foregroundStyle(.secondary)
                }
            } else {
                Text(Self.unavailable).foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }

    /// The whole prompt laid out at the shown width, hidden: taller than the
    /// two shown lines means they cut it.
    private func measure(_ prompt: String) -> some View {
        GeometryReader { shown in
            Text(prompt)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: shown.size.width, alignment: .leading)
                .hidden()
                .background {
                    GeometryReader { full in
                        let cut = full.size.height > shown.size.height + 1
                        Color.clear
                            .onAppear { truncated = cut }
                            .onChange(of: cut) { _, now in truncated = now }
                    }
                }
        }
    }
}
