import SwiftUI
import WatchtowerKit
import WatchtowerSync

/// "New session on the Mac" (spec §6.5, §13 B6): the workbench, the target
/// (fixed from a target's detail, picked from the Workbench header), the
/// agent, the brief, "Bring the window forward on the Mac" (off) and "Plan
/// first, then ask me" (on). A target that already has a session offers
/// Open it or Start a new one. Once sent, the sheet follows the Mac:
/// Sent to your Mac → Mac picked it up → Starting <agent> → Open
/// session. The progress lives in `SessionStarter`, so the sheet can be
/// left and reopened.
struct StartSessionSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let workbenchID: Int64
    /// Set from a target's detail; nil from the Workbench header.
    let fixedTargetID: Int64?
    let onOpenSession: (Int64) -> Void
    @State private var draft: StartSessionDraft
    @State private var sendError: String?

    init(workbenchID: Int64, target: WorkbenchTarget?, fixed: Bool, onOpenSession: @escaping (Int64) -> Void) {
        self.workbenchID = workbenchID
        fixedTargetID = fixed ? target?.id : nil
        self.onOpenSession = onOpenSession
        _draft = State(initialValue: StartSessionDraft(target: target))
    }

    private var starter: SessionStarter { env.sessionStarts }

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                if let model = StartSessionFormModel(
                    workbenchID: workbenchID,
                    targetID: draft.targetID,
                    snapshot: env.workbenchReplica.snapshot,
                    grant: env.workbenchReplica.snapshot.grant(for: env.linkedDevice?.deviceID),
                    attempt: draft.targetID.flatMap { starter.attempts[$0] },
                    inFlight: starter.inFlight,
                    now: context.date
                ) {
                    content(model)
                } else {
                    ContentUnavailableView(
                        "Workbench not found",
                        systemImage: "hammer",
                        description: Text("It was removed on your Mac.")
                    )
                }
            }
            .navigationTitle(SessionStartText.sheetTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .alert("Couldn't send", isPresented: Binding(get: { sendError != nil }, set: { if !$0 { sendError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(sendError ?? "")
            }
        }
    }

    @ViewBuilder
    private func content(_ model: StartSessionFormModel) -> some View {
        if let progress = model.progress {
            progressView(progress, model)
        } else {
            form(model)
        }
    }

    // MARK: - Form

    private func form(_ model: StartSessionFormModel) -> some View {
        Form {
            Section {
                LabeledContent("Workbench", value: model.workbenchName)
                if fixedTargetID != nil {
                    LabeledContent("Target") {
                        Text(model.targetLabel ?? "").font(.callout).lineLimit(2)
                    }
                } else {
                    Picker("Target", selection: targetBinding(model)) {
                        Text("Choose a target").tag(Int64?.none)
                        ForEach(model.targetOptions) { Text($0.label).tag(Int64?.some($0.id)) }
                    }
                    .frame(minHeight: 44)
                }
                LabeledContent("Agent", value: model.agent)
                    .accessibilityHint("The only agent in this version")
            }
            if model.target != nil {
                Section {
                    TextEditor(text: $draft.brief)
                        .frame(minHeight: 128)
                        .font(.callout)
                        .disabled(!model.grant.typingAllowed)
                        .foregroundStyle(model.grant.typingAllowed ? .primary : .secondary)
                        .accessibilityLabel("Brief the session gets")
                } header: {
                    Text("Brief the session gets")
                } footer: {
                    if let caption = model.briefCaption { Text(caption) }
                }
                Section {
                    Toggle("Bring the window forward on the Mac", isOn: $draft.bringForward)
                        .frame(minHeight: 44)
                    Toggle("Plan first, then ask me", isOn: $draft.planFirst)
                        .frame(minHeight: 44)
                }
            }
            if let existing = model.existing {
                Section("This target has a session") {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(existing.title).font(.subheadline)
                        Text(existing.caption).font(.caption).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { formButtons(model) }
    }

    private func targetBinding(_ model: StartSessionFormModel) -> Binding<Int64?> {
        Binding(
            get: { draft.targetID },
            set: { id in
                if let target = id.flatMap({ id in env.workbenchReplica.snapshot.targets.first { $0.id == id } }) {
                    draft.pick(target)
                } else {
                    draft.targetID = nil
                }
            }
        )
    }

    private func formButtons(_ model: StartSessionFormModel) -> some View {
        BottomActionBar {
            VStack(spacing: Spacing.regular) {
                if let caption = model.startCaption {
                    Text(caption).font(TypeScale.meta).foregroundStyle(.secondary)
                }
                if let existing = model.existing {
                    Button("Open it") { openIt(model) }
                        .buttonStyle(ProminentActionStyle())
                        .disabled(!existing.isLive && !model.canStart)
                        .accessibilityHint(existing.isLive ? "Opens the running session" : "Resumes the session on the Mac")
                    secondaryButton("Start a new one") { start(.new, model) }
                        .disabled(!model.canStart)
                } else {
                    Button { start(.new, model) } label: {
                        Label("Start session", systemImage: "play.fill")
                    }
                    .buttonStyle(ProminentActionStyle())
                    .disabled(!model.canStart)
                }
            }
        }
    }

    /// The secondary button of a bar's pair.
    private func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    // MARK: - Progress

    private func progressView(_ progress: StartProgressModel, _ model: StartSessionFormModel) -> some View {
        List {
            Section {
                ForEach(progress.steps) { step in
                    StepRow(state: Self.stepState(step.state), text: step.title)
                        .accessibilityElement(children: .combine)
                        .accessibilityValue(Self.stepValue(step.state))
                }
                if let waiting = progress.waitingLine {
                    Label(waiting, systemImage: "clock").font(.caption).foregroundStyle(.secondary)
                }
                if let failure = progress.failure {
                    Text(failure).font(.subheadline).foregroundStyle(PhoneTone.red.color)
                }
                if progress.isEnded {
                    Text(SessionStartText.ended).font(.subheadline).foregroundStyle(.secondary)
                }
            } header: {
                Text(model.progressHeader)
            } footer: {
                if progress.failure == nil && !progress.isEnded { Text(SessionStartText.leaveHint) }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { progressButtons(progress, model) }
    }

    private static func stepValue(_ state: StartProgressModel.Step.State) -> String {
        switch state {
        case .done: "Done"
        case .current: "In progress"
        case .todo: "Not yet"
        }
    }

    private static func stepState(_ state: StartProgressModel.Step.State) -> StepRow.State {
        switch state {
        case .done: .done
        case .current: .current
        case .todo: .todo
        }
    }

    private func progressButtons(_ progress: StartProgressModel, _ model: StartSessionFormModel) -> some View {
        BottomActionBar {
            VStack(spacing: Spacing.regular) {
                if let row = progress.failedRow {
                    Button("Try again") { retry(row) }
                        .buttonStyle(ProminentActionStyle())
                        .disabled(!model.canStart)
                    secondaryButton("Dismiss") { clear(model) }
                } else if progress.isEnded {
                    Button("Start a new one") {
                        clear(model)
                        start(.new, model)
                    }
                    .buttonStyle(ProminentActionStyle())
                    .disabled(!model.canStart)
                    secondaryButton("Dismiss") { clear(model) }
                } else {
                    Button(SessionStartText.openSession) {
                        if let id = progress.openSessionID {
                            clear(model)
                            dismiss()
                            onOpenSession(id)
                        }
                    }
                    .buttonStyle(ProminentActionStyle())
                    .disabled(progress.openSessionID == nil)
                    // Done always ends the sheet's hold on the start; a save the
                    // Mac has not answered yet still shows from its overlay row.
                    secondaryButton("Done") {
                        clear(model)
                        dismiss()
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func openIt(_ model: StartSessionFormModel) {
        switch model.openIt {
        case let .show(sessionID)?:
            dismiss()
            onOpenSession(sessionID)
        case .resume?:
            start(.openExisting, model)
        case nil:
            break
        }
    }

    private func start(_ mode: SessionStartParams.Mode, _ model: StartSessionFormModel) {
        guard let target = model.target else { return }
        let params = draft.params(workbenchID: model.workbenchID, mode: mode, grant: model.grant)
        run { try await starter.start(targetID: target.id, params: params) }
    }

    private func retry(_ row: PendingAction) {
        run { try await starter.retry(row) }
    }

    private func clear(_ model: StartSessionFormModel) {
        guard let target = model.target else { return }
        do {
            try starter.clear(targetID: target.id)
        } catch {
            sendError = BoardWriteText.sendError(error)
        }
    }

    private func run(_ work: @escaping @MainActor () async throws -> Bool) {
        Task {
            do {
                _ = try await work()
            } catch {
                sendError = BoardWriteText.sendError(error)
            }
        }
    }
}
