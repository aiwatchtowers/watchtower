import SwiftUI
import WatchtowerKit
import WatchtowerSync

/// "New session on the Mac" (spec §6.5, §13 B6): the workbench, the target
/// (fixed from a target's detail, picked from the Workbench header), the
/// agent, the brief, "Bring the window forward on the Mac" (off) and "Plan
/// first, then ask me" (on). A target that already has a session offers
/// Open it or Start a new one. Once sent, the sheet follows the Mac:
/// Sent to your Mac → Mac picked it up → Starting Claude Code → Open
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
                        Text(model.targetLabel ?? "").font(.callout.monospaced()).lineLimit(2)
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
        .safeAreaInset(edge: .bottom) { formButtons(model) }
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
        VStack(spacing: 8) {
            if let caption = model.startCaption {
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
            if let existing = model.existing {
                Button {
                    openIt(model)
                } label: {
                    Text("Open it").frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!existing.isLive && !model.canStart)
                .accessibilityHint(existing.isLive ? "Opens the running session" : "Resumes the session on the Mac")
                Button {
                    start(.new, model)
                } label: {
                    Text("Start a new one").frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .disabled(!model.canStart)
            } else {
                Button {
                    start(.new, model)
                } label: {
                    Label("Start session", systemImage: "play.fill").frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canStart)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    // MARK: - Progress

    private func progressView(_ progress: StartProgressModel, _ model: StartSessionFormModel) -> some View {
        List {
            Section {
                ForEach(progress.steps) { step in
                    HStack(spacing: 12) {
                        StepDot(state: step.state)
                        Text(step.title).foregroundStyle(step.state == .todo ? .secondary : .primary)
                    }
                    .frame(minHeight: 44)
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
        .safeAreaInset(edge: .bottom) { progressButtons(progress, model) }
    }

    private static func stepValue(_ state: StartProgressModel.Step.State) -> String {
        switch state {
        case .done: "Done"
        case .current: "In progress"
        case .todo: "Not yet"
        }
    }

    private func progressButtons(_ progress: StartProgressModel, _ model: StartSessionFormModel) -> some View {
        VStack(spacing: 8) {
            if let row = progress.failedRow {
                Button {
                    retry(row)
                } label: {
                    Text("Try again").frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canStart)
                Button {
                    clear(model)
                } label: {
                    Text("Dismiss").frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
            } else if progress.isEnded {
                Button {
                    clear(model)
                    start(.new, model)
                } label: {
                    Text("Start a new one").frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canStart)
                Button {
                    clear(model)
                } label: {
                    Text("Dismiss").frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
            } else {
                Button {
                    if let id = progress.openSessionID {
                        clear(model)
                        dismiss()
                        onOpenSession(id)
                    }
                } label: {
                    Text(SessionStartText.openSession).frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.borderedProminent)
                .disabled(progress.openSessionID == nil)
                // Done always ends the sheet's hold on the start; a save the
                // Mac has not answered yet still shows from its overlay row.
                Button {
                    clear(model)
                    dismiss()
                } label: {
                    Text("Done").frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
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

/// One progress step's dot: filled when done, a ring while current, faint
/// before.
private struct StepDot: View {
    let state: StartProgressModel.Step.State

    var body: some View {
        Group {
            switch state {
            case .done: Circle().fill(PhoneTone.green.color)
            case .current: Circle().strokeBorder(PhoneTone.green.color, lineWidth: 2)
            case .todo: Circle().strokeBorder(PhoneTone.secondary.color, lineWidth: 1.5)
            }
        }
        .frame(width: 12, height: 12)
        .accessibilityHidden(true)
    }
}
