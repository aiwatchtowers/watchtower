import SwiftUI
import WatchtowerKit

/// Opens one ask's form, from a Waiting-for-you card, a session's or a
/// target's asks, or a closed ask.
struct AskRoute: Hashable {
    let id: Int64
}

/// One ask on the phone (spec §13 B4): the header, the summary and what to
/// look at, then the kind's form (question pages, the review snapshot with
/// its comments and verdict, the check steps), the note and Send. A closed
/// ask shows its stored answer read-only; one whose payload did not fit
/// says to open it on the Mac.
struct AskView: View {
    let replica: WorkbenchReplicaModel
    @State private var model: AskViewModel

    init(replica: WorkbenchReplicaModel, drafts: AskDraftStore, answerer: AskAnswerer, askID: Int64) {
        self.replica = replica
        _model = State(initialValue: AskViewModel(askID: askID, drafts: drafts, answerer: answerer))
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            if let form = model.form(snapshot: replica.snapshot, now: context.date),
               let ask = replica.snapshot.asks.first(where: { $0.id == model.askID }) {
                content(form, ask: ask)
                    .onChange(of: form.status) { model.followSuccessor(snapshot: replica.snapshot, now: context.date) }
                    .onAppear { model.followSuccessor(snapshot: replica.snapshot, now: context.date) }
            } else {
                ContentUnavailableView("Ask not found", systemImage: "questionmark.bubble", description: Text("It is no longer on your Mac."))
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    private func content(_ form: AskFormModel, ask: OwnerAsk) -> some View {
        List {
            Section {
                AskHeaderView(form: form)
            }
            if let notice = model.carriedNotice {
                Section { Text(notice).font(.callout).foregroundStyle(.secondary) }
            }
            if let openOnMac = form.openOnMac {
                Section {
                    Label(openOnMac, systemImage: "desktopcomputer").font(.headline)
                    Text(AskText.openOnMacReason).foregroundStyle(.secondary)
                }
            } else if let status = form.closedStatus {
                Section(status) {
                    if form.closedLines.isEmpty {
                        Text("No answer was stored").foregroundStyle(.secondary)
                    }
                    ForEach(form.closedLines, id: \.self) { Text($0) }
                }
            } else {
                if let page = form.question {
                    QuestionAskView(page: page, model: model, isEditable: form.isEditable)
                }
                if let review = form.review {
                    ReviewAskView(review: review, model: model, isEditable: form.isEditable)
                }
                if !form.checks.isEmpty {
                    CheckAskView(rows: form.checks, model: model, isEditable: form.isEditable)
                }
                if form.question?.isLast ?? true {
                    Section("Note") {
                        TextField("Anything else for the agent (optional)", text: noteBinding, axis: .vertical)
                            .lineLimit(2...8)
                            .disabled(!form.isEditable)
                    }
                }
            }
            if let status = AskStatusRow.Model(form.status) {
                Section { AskStatusRow(model: status) { dismiss(status) } }
            }
            if let error = model.sendError {
                Section { Text(error).foregroundStyle(PhoneTone.red.color) }
            }
        }
        .listStyle(.insetGrouped)
        .safeAreaInset(edge: .bottom) {
            if form.openOnMac == nil, form.closedStatus == nil {
                AskSendBar(form: form, ask: ask, model: model)
            }
        }
    }

    private var noteBinding: Binding<String> {
        Binding(get: { model.draft.note }, set: { model.setNote($0) })
    }

    private func dismiss(_ status: AskStatusRow.Model) {
        guard let rowID = status.rowID else { return }
        model.dismiss(rowID: rowID, snapshot: replica.snapshot)
    }
}

/// "ASK #109 · QUESTION · 1 OF 2", the title, where it came from, the
/// summary, what changed since the last round and what to look at.
private struct AskHeaderView: View {
    let form: AskFormModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(form.header)
                .font(.caption2.monospaced().weight(.semibold))
                .foregroundStyle(form.headerTone.color)
            Text(form.title).font(.title3.weight(.semibold))
            Text(form.subline).font(.caption).foregroundStyle(.secondary)
            if !form.summary.isEmpty {
                Text(form.summary).font(.callout)
            }
            if !form.changes.isEmpty {
                Text("Changed since the last round: \(form.changes)").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(Array(form.focus.enumerated()), id: \.offset) { index, focus in
                Text("\(index + 1) · \(focus)").font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The answer on its way, refused (with Dismiss), or applied.
struct AskStatusRow: View {
    struct Model: Equatable {
        let text: String
        let isFailure: Bool
        /// The overlay row Dismiss removes; nil when there is none to dismiss.
        let rowID: String?

        init?(_ status: AskFormModel.Status) {
            switch status {
            case .none: return nil
            case let .sending(text): (self.text, isFailure, rowID) = (text, false, nil)
            case let .failed(text, row): (self.text, isFailure, rowID) = (text, true, row)
            case let .notOpen(text, row, _): (self.text, isFailure, rowID) = (text, true, row)
            case let .applied(text): (self.text, isFailure, rowID) = (text, false, nil)
            }
        }
    }

    let model: Model
    let dismiss: () -> Void

    var body: some View {
        HStack {
            Text(model.text)
                .foregroundStyle(model.isFailure ? PhoneTone.red.color : Color.secondary)
            Spacer(minLength: 8)
            if model.rowID != nil {
                Button("Dismiss", action: dismiss)
                    .frame(minHeight: 44)
            }
        }
    }
}

/// Send (or Next question on a question page that is not the last), or
/// Approve and Request changes on a review; the footer.
private struct AskSendBar: View {
    let form: AskFormModel
    let ask: OwnerAsk
    let model: AskViewModel

    var body: some View {
        VStack(spacing: 8) {
            if form.review != nil {
                HStack(spacing: 8) {
                    Button(AskText.requestChanges) { verdict(.changes) }
                        .buttonStyle(.bordered)
                        .accessibilityHint("Sends the answer with changes requested")
                    Button(AskText.approve) { verdict(.approved) }
                        .buttonStyle(.borderedProminent)
                        .accessibilityHint("Sends the answer approved")
                }
                .controlSize(.large)
                .disabled(!form.canSendVerdict)
            } else if let page = form.question, !page.isLast {
                Button(AskText.next) { model.next(of: page.count) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
            } else {
                Button(AskText.send) { Task { await model.send(ask) } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!form.canSend)
                    .accessibilityLabel(AskText.send)
            }
            if let page = form.question, page.index > 0 {
                Button(AskText.previous) { model.previous() }
                    .frame(minHeight: 44)
            }
            Text(form.footer).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func verdict(_ verdict: OwnerAskAnswer.Verdict) {
        Task { await model.review(verdict, ask) }
    }
}
