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
                    now: context.date,
                    startsTurnedOn: env.deviceSettings.startSessions
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
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.medium) {
                SheetField(label: "Workbench") { Text(model.workbenchName) }
                SheetField(label: "Target") {
                    if fixedTargetID != nil {
                        Text(model.targetLabel ?? "").lineLimit(2)
                    } else {
                        Picker("Target", selection: targetBinding(model)) {
                            Text("Choose a target").tag(Int64?.none)
                            ForEach(model.targetOptions) { Text($0.label).tag(Int64?.some($0.id)) }
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if model.target != nil {
                    SheetField(label: "Brief the session gets") {
                        TextEditor(text: $draft.brief)
                            .frame(minHeight: PhoneMetrics.minTouch * 3)
                            .scrollContentBackground(.hidden)
                            .disabled(!model.grant.typingAllowed)
                            .foregroundStyle(model.grant.typingAllowed ? .primary : .secondary)
                            .accessibilityLabel("Brief the session gets")
                    }
                    if let caption = model.briefCaption {
                        Text(caption).font(TypeScale.meta).foregroundStyle(.secondary).padding(.horizontal, Spacing.small)
                    }
                }
                optionsCard(model)
                if let existing = model.existing {
                    SectionHeader("This target has a session")
                    VStack(alignment: .leading, spacing: Spacing.tight) {
                        Text(existing.title).font(TypeScale.rowTitle)
                        Text(existing.caption).font(TypeScale.meta).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .card()
                }
            }
            .padding(Spacing.large)
        }
        .background(Color(.systemBackground))
        .safeAreaInset(edge: .bottom, spacing: 0) { formButtons(model) }
    }

    /// Agent, and the two switches, on one card (mockup 12).
    private func optionsCard(_ model: StartSessionFormModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow(title: "Agent") { Text(model.agent) }
                .accessibilityHint("The only agent in this version")
            if model.target != nil {
                CardRowDivider()
                SettingsRow(title: "Bring the window forward on the Mac") {
                    Toggle("", isOn: $draft.bringForward).toggleStyle(SmallSwitchStyle())
                }
                CardRowDivider()
                SettingsRow(title: "Plan first, then ask me") {
                    Toggle("", isOn: $draft.planFirst).toggleStyle(SmallSwitchStyle())
                }
            }
        }
        .card(.plain, padding: EdgeInsets(top: Spacing.tight, leading: Spacing.medium, bottom: Spacing.tight, trailing: Spacing.medium))
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

    @ViewBuilder
    private func formButtons(_ model: StartSessionFormModel) -> some View {
        if model.existing == nil, model.startCaption == nil {
            PrimaryActionBar(primary: BarAction(title: "Start session", isEnabled: model.canStart) { start(.new, model) })
        } else {
            pairedButtons(model)
        }
    }

    private func pairedButtons(_ model: StartSessionFormModel) -> some View {
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
        .buttonStyle(SecondaryActionStyle())
    }

    // MARK: - Progress

    private func progressView(_ progress: StartProgressModel, _ model: StartSessionFormModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.regular) {
                SectionHeader(model.progressHeader)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(progress.steps) { step in
                        StepRow(state: Self.stepState(step.state), text: step.title)
                            .accessibilityElement(children: .combine)
                            .accessibilityValue(Self.stepValue(step.state))
                    }
                    if let waiting = progress.waitingLine {
                        Label(waiting, systemImage: "clock")
                            .font(TypeScale.meta)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, Spacing.regular)
                    }
                    if let failure = progress.failure {
                        Text(failure)
                            .font(.subheadline)
                            .foregroundStyle(PhoneTone.red.color)
                            .padding(.vertical, Spacing.regular)
                    }
                    if progress.isEnded {
                        Text(SessionStartText.ended)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, Spacing.regular)
                    }
                }
                .card()
                if progress.failure == nil && !progress.isEnded {
                    Text(SessionStartText.leaveHint)
                        .font(TypeScale.meta)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, Spacing.small)
                }
            }
            .padding(Spacing.large)
        }
        .background(Color(.systemBackground))
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
