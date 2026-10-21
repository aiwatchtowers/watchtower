import SwiftUI
import WatchtowerCore

/// The editor panel's **Form** (spec A4): name, **Runs** and the schedule
/// picker, **Each run may spend**, **It may** and the outputs, the Auto
/// toggles, and the notes on why the form is paused. Every control writes
/// into the draft's recipe text (`AutomationFormModel`); the panel's draft
/// column and footer show and save it. `locked` turns every control off
/// while a save runs, so nothing typed then is dropped.
struct AutomationFormFields: View {
    @Bindable var form: AutomationFormModel
    @Bindable var editor: AutomationEditorCenter
    @Bindable var vm: AutomationsViewModel
    let locked: Bool
    /// Switches the panel to **Script** (an unreadable recipe is fixed there).
    let onOpenScript: () -> Void

    @State private var schedule = ScheduleChoice(cron: "0 9 * * 1-5")
    @State private var newPermission = ""
    @State private var addingPermission = false

    private var id: Int64 { form.detail.id }
    /// The controls write the frontmatter only while the form describes it.
    private var controlsEnabled: Bool { !form.paused && !locked }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.page) {
                notes
                Group {
                    nameField
                    runsSection
                    spendSection
                    mayDoSection
                }
                .disabled(!controlsEnabled)
                if !AutomationEditorCenter.isNewDraft(id), !form.detail.autoTools.isEmpty {
                    autoSection.disabled(locked)
                }
                problems
            }
            .controlSize(.small)
            .padding(Spacing.page)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear(perform: syncSchedule)
        .onChange(of: schedule) { old, new in
            // Only the owner's picks write: the picker reading the recipe's
            // cron (on appear) must not rewrite it.
            guard case let .schedule(expr) = form.fields.trigger, new != ScheduleChoice(cron: expr) else { return }
            if new.repeats == .custom, old.repeats != .custom {
                schedule.custom = old.cron
                return
            }
            form.fields.trigger = .schedule(new.cron)
        }
    }

    private func syncSchedule() {
        if case let .schedule(expr) = form.fields.trigger { schedule = ScheduleChoice(cron: expr) }
    }

    // MARK: - Notes

    @ViewBuilder private var notes: some View {
        if form.recipeUnparsed {
            // #582: the fields are column defaults, not the file's settings;
            // the form stays off so it never writes them over the recipe.
            unparsedNote
        } else if form.lostFormEdit {
            note("Your last change in the form did not land: the recipe was edited in Script at the same moment. "
                + "The form is paused until you save.", systemImage: "exclamationmark.triangle", tone: Tone.warning)
        } else if form.frontmatterEditedInRecipe {
            note("The settings were changed in the chat or in Script, so the form is paused until you save.",
                 systemImage: "info.circle", tone: Color.secondary)
        }
    }

    /// The loaded recipe does not parse: its error as checked now, or that
    /// the fixed text reads (the form stays off until it is saved).
    @ViewBuilder private var unparsedNote: some View {
        if form.currentParseError.isEmpty {
            note("The recipe reads now. Save it; the form stays off until then.", systemImage: "checkmark.circle",
                 tone: Color.secondary)
        } else {
            VStack(alignment: .leading, spacing: Spacing.compact) {
                note("The recipe can't be read, so the form is off: \(form.currentParseError)",
                     systemImage: "exclamationmark.triangle", tone: Tone.warning)
                    .textSelection(.enabled)
                Button("Open in Script", action: onOpenScript)
                    .buttonStyle(.kitSecondary)
            }
        }
    }

    private func note(_ text: String, systemImage: String, tone: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(.callout)
            .foregroundStyle(tone)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var nameField: some View {
        labeled("Name") {
            TextField("Name", text: $form.fields.name)
                .textFieldStyle(.kit)
                .frame(maxWidth: 360)
        }
    }

    // MARK: - Runs

    private enum TriggerChoice: CaseIterable, Hashable {
        case schedule, button, manual, event

        var title: String {
            switch self {
            case .schedule: "On a schedule"
            case .button: "When I press a button"
            case .manual: "Only when I run it"
            case .event: "On an event"
            }
        }
    }

    private var currentChoice: TriggerChoice {
        switch form.fields.trigger {
        case .schedule: .schedule
        case .button: .button
        case .event: .event
        case .manual: .manual
        }
    }

    private func choose(_ choice: TriggerChoice) {
        guard choice != currentChoice else { return }
        switch choice {
        case .schedule: form.fields.trigger = .schedule(schedule.cron)
        case .button: form.fields.trigger = .button(label: "Run", confirm: false)
        case .manual: form.fields.trigger = .manual
        case .event: form.fields.trigger = AutomationFormModel.defaultEventTrigger
        }
    }

    private var runsSection: some View {
        labeled("Runs") {
            KitSegmentedPicker(
                title: "Runs",
                selection: Binding(get: { currentChoice }, set: choose),
                segments: TriggerChoice.allCases.map { KitSegment(value: $0, title: $0.title) }
            )
            switch form.fields.trigger {
            case .schedule:
                schedulePicker
            case let .button(label, confirm):
                HStack(spacing: Spacing.medium) {
                    TextField("Button label", text: Binding(
                        get: { label },
                        set: { form.fields.trigger = .button(label: $0, confirm: confirm) }
                    ))
                    .textFieldStyle(.kit)
                    .frame(width: 220)
                    Toggle("Ask before running", isOn: Binding(
                        get: { confirm },
                        set: { form.fields.trigger = .button(label: label, confirm: $0) }
                    ))
                    .toggleStyle(.checkbox)
                }
            case let .event(type, filter):
                eventEditor(type: type, filter: filter)
            case .manual:
                EmptyView()
            }
        }
    }

    private var schedulePicker: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            HStack(spacing: Spacing.regular) {
                Picker("Repeats", selection: $schedule.repeats) {
                    ForEach(ScheduleChoice.Repeat.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                scheduleTime
            }
            Text(schedule.nextLine(now: Date()))
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("If the Mac was asleep at that time, run once when it wakes", isOn: Binding(
                get: { form.fields.missed != "skip" },
                set: { form.fields.missed = $0 ? "run_once" : "skip" }
            ))
            .toggleStyle(.checkbox)
        }
    }

    @ViewBuilder private var scheduleTime: some View {
        switch schedule.repeats {
        case .custom:
            TextField("minute hour day month weekday", text: $schedule.custom)
                .textFieldStyle(.kit)
                .font(.body.monospaced())
                .frame(width: 260)
        case .hourly:
            Text("at minute")
            Picker("Minute", selection: $schedule.minute) {
                ForEach(0..<60, id: \.self) { Text(String(format: ":%02d", $0)).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
        case .weekly, .weekdays, .daily:
            if schedule.repeats == .weekly {
                Picker("Day", selection: $schedule.weekday) {
                    ForEach(0..<7, id: \.self) { Text(Calendar.current.weekdaySymbols[$0]).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            Text("at")
            Picker("Hour", selection: $schedule.hour) {
                ForEach(0..<24, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            Picker("Minute", selection: $schedule.minute) {
                ForEach(0..<60, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
        }
    }

    private func eventEditor(type: String, filter: [String: String]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.compact) {
            Picker("Event", selection: Binding(
                get: { type },
                set: { form.fields.trigger = AutomationFormModel.eventTrigger(type: $0, keeping: filter) }
            )) {
                ForEach(AutomationFormModel.eventTypes, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            if type == "slack.reaction_added" {
                ReactionCommandsOffNote(text: "Reaction events need Reaction commands on")
            }
            ForEach(filter.keys.sorted(), id: \.self) { key in
                HStack(spacing: Spacing.regular) {
                    Text(key).font(.callout.monospaced())
                    TextField("value or glob", text: Binding(
                        get: { filter[key] ?? "" },
                        set: { value in
                            var next = filter
                            next[key] = value
                            form.fields.trigger = .event(type: type, where: next)
                        }
                    ))
                    .textFieldStyle(.kit)
                    Button {
                        var next = filter
                        next[key] = nil
                        form.fields.trigger = .event(type: type, where: next)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.kitQuiet)
                    .accessibilityLabel("Remove filter \(key)")
                }
            }
            Text(type == "slack.reaction_added"
                ? "Runs after you react to a Slack message, at most once per sync cycle. "
                + "Narrow it with a where filter in Script."
                : "Runs after a sync brings something new, at most once per sync cycle. "
                + "Narrow it with a where filter in Script.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Spend

    private var spendSection: some View {
        labeled("Each run may spend") {
            HStack(spacing: Spacing.cozy) {
                TextField("Tokens", value: $form.fields.budgetTokens, format: .number)
                    .textFieldStyle(.kit)
                    .frame(width: 110)
                Text("tokens")
                TextField("Minutes", value: $form.fields.budgetMinutes, format: .number)
                    .textFieldStyle(.kit)
                    .frame(width: 60)
                Text("minutes")
            }
            HStack(spacing: Spacing.page) {
                Stepper("Runs at a time: \(form.fields.concurrency)", value: $form.fields.concurrency,
                        in: AutomationFormModel.concurrencyRange)
                Stepper("Waits for you up to \(form.fields.pauseTimeoutHours) h",
                        value: $form.fields.pauseTimeoutHours, in: AutomationFormModel.pauseTimeoutRange)
            }
        }
    }

    // MARK: - It may

    private var mayDoSection: some View {
        labeled("It may") {
            FlowLayout(spacing: Spacing.compact) {
                ForEach(form.fields.permissions, id: \.self) { permission in
                    permissionChip(permission)
                }
                Button("+ Add") { addingPermission = true }
                    .buttonStyle(.kitQuiet)
                    .popover(isPresented: $addingPermission) { addPermissionPopover.popoverSurface() }
            }
            HStack(spacing: Spacing.medium) {
                Text("Outputs").foregroundStyle(.secondary)
                ForEach(AutomationFormModel.outputKinds, id: \.self) { kind in
                    Toggle(kind, isOn: Binding(
                        get: { form.fields.outputs.contains(kind) },
                        set: { on in
                            if on {
                                form.fields.outputs.append(kind)
                            } else {
                                form.fields.outputs.removeAll { $0 == kind }
                            }
                        }
                    ))
                    .toggleStyle(.checkbox)
                }
            }
        }
    }

    private func permissionChip(_ permission: String) -> some View {
        HStack(spacing: Spacing.small) {
            Text(AutomationCardPresentation.permissionLine(permission))
            Button {
                form.fields.permissions.removeAll { $0 == permission }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
            }
            .buttonStyle(.kitQuiet)
            .accessibilityLabel("Remove \(permission)")
        }
        .help(permission)
        .padding(.horizontal, Spacing.regular)
        .padding(.vertical, Spacing.small)
        .background(Fill.card, in: Capsule())
    }

    private var addPermissionPopover: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            Text("One permission, as in the recipe: gmail:read@work, llm:light, tool:create_jira_issue")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("capability:verb@scope", text: $newPermission)
                .textFieldStyle(.kit)
                .font(.body.monospaced())
                .onSubmit(addPermission)
            HStack {
                Spacer()
                Button("Add", action: addPermission)
                    .buttonStyle(.kitPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(newPermission.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(Spacing.medium)
        .frame(width: 340)
    }

    private func addPermission() {
        let entry = newPermission.trimmingCharacters(in: .whitespaces)
        guard !entry.isEmpty else { return }
        if !form.fields.permissions.contains(entry) { form.fields.permissions.append(entry) }
        newPermission = ""
        addingPermission = false
    }

    // MARK: - Auto

    /// Auto for each write tool, bound to the recipe as it is indexed (the
    /// grant binds the loaded approval hash, not this draft's).
    private var autoSection: some View {
        labeled("Auto") {
            Text("Runs these tools without asking you each time")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(form.detail.autoTools.filter(\.alwaysAsks), id: \.tool) { entry in
                HStack(spacing: Spacing.regular) {
                    Toggle(entry.tool, isOn: .constant(false))
                        .toggleStyle(.checkbox)
                        .disabled(true)
                    Text("Always asks")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(form.detail.autoTools.filter { !$0.alwaysAsks }.map(\.tool), id: \.self) { tool in
                Toggle(tool, isOn: Binding(
                    get: {
                        vm.grants[id]?.contains { $0.tool == tool && $0.isActive(approvalHash: form.detail.approvalHash) }
                            ?? false
                    },
                    set: { on in Task { await editor.setAuto(id, tool: tool, on: on) } }
                ))
                .toggleStyle(.checkbox)
                .disabled(form.detail.needsConfirmation)
                .help(form.detail.needsConfirmation ? "Confirm the recipe first" : "")
            }
            if let line = AutomationLLMWarning.line(
                feedsSourcesToLLM: form.detail.feedsSourcesToLLM,
                tools: form.detail.autoTools.filter { $0.external && !$0.alwaysAsks }.map(\.tool)
            ) {
                LLMWarningLabel(text: line)
            }
            if let error = editor.autoErrors[id] {
                Text(error).font(.caption).foregroundStyle(Tone.error)
            }
        }
    }

    @ViewBuilder private var problems: some View {
        ForEach(form.problems, id: \.self) { problem in
            Label(problem, systemImage: "exclamationmark.circle")
                .font(.callout)
                .foregroundStyle(Tone.error)
        }
    }

    private func labeled(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            Text(title).font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The #559 warning line (`AutomationLLMWarning.line`), shared by the
/// form's Auto section and the confirmation sheet.
struct LLMWarningLabel: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle")
            .foregroundStyle(Tone.warning)
            .fixedSize(horizontal: false, vertical: true)
    }
}
