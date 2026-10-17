import SwiftUI
import WatchtowerCore

/// "Edit “<name>”" (spec §12.2, approved mockup 4): name, **Runs**, the
/// schedule picker, **Each run may spend**, **It may**, outputs, Enabled and
/// Auto, and the whole recipe in Monaco. The draft lives in the
/// `AppState`-owned `AutomationEditorCenter`: the form's controls write its
/// fields into the recipe text (`AutomationFormModel`), Monaco edits the same
/// text, and a save started here finishes after the form closes.
struct AutomationFormView: View {
    @Bindable var editor: AutomationEditorCenter
    @Bindable var vm: AutomationsViewModel
    let automationID: Int64
    let onChangeInWords: ((Int64) -> Void)?
    /// Set for the "New automation" sheet's **Form** tab: the directory a new
    /// personal recipe is saved in (`automationID` is then `newRecipeID`).
    var newRecipeDir: String?
    let onClose: () -> Void

    @State private var confirmingDiscard = false

    private var saveState: AutomationEditorCenter.SaveState? { editor.saving[automationID] }

    var body: some View {
        Group {
            switch editor.formContent(automationID) {
            case let .editing(form):
                AutomationFormContent(form: form, editor: editor, vm: vm, onChangeInWords: onChangeInWords) {
                    cancel(form)
                }
                // A reload replaces the form: start its view state afresh.
                .id(ObjectIdentifier(form))
            case let .loadFailed(message), let .finished(message):
                VStack(spacing: 12) {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                    Button("Close") {
                        editor.discard(automationID)
                        onClose()
                    }
                    .keyboardShortcut(.cancelAction)
                }
                .padding(24)
                .frame(minWidth: 420)
            case .loading:
                ProgressView()
                    .frame(width: 720, height: 300)
            }
        }
        .task {
            if let newRecipeDir {
                editor.beginNew(automationsDir: newRecipeDir)
            } else {
                await editor.beginEdit(automationID)
            }
        }
        .onChange(of: saveState) { _, new in
            if new == .done { onClose() }
        }
        .sheet(isPresented: reviewPresented) {
            if case let .review(plan) = saveState {
                AutomationSaveSheet(
                    plan: plan,
                    name: editor.drafts[automationID]?.form.fields.name ?? "",
                    onCancel: { editor.cancelReview(automationID) },
                    onSave: { checked in
                        let id = automationID
                        Task { await editor.commit(id, plan: checked) }
                    }
                )
            }
        }
        .confirmationDialog("Discard your changes?", isPresented: $confirmingDiscard) {
            Button("Discard Changes", role: .destructive) {
                editor.discard(automationID)
                onClose()
            }
            Button("Keep Editing", role: .cancel) {}
        }
    }

    private var reviewPresented: Binding<Bool> {
        Binding(
            get: {
                if case .review = saveState { return true }
                return false
            },
            set: { shown in
                if !shown { editor.cancelReview(automationID) }
            }
        )
    }

    /// Unsaved edits are never dropped without asking; a save in flight keeps
    /// going in the center when the form closes.
    private func cancel(_ form: AutomationFormModel) {
        if saveState == .saving {
            onClose()
        } else if form.buffer.isDirty {
            confirmingDiscard = true
        } else {
            editor.discard(automationID)
            onClose()
        }
    }
}

/// The form itself, for a loaded draft.
private struct AutomationFormContent: View {
    @Bindable var form: AutomationFormModel
    @Bindable var editor: AutomationEditorCenter
    @Bindable var vm: AutomationsViewModel
    let onChangeInWords: ((Int64) -> Void)?
    let onCancel: () -> Void

    @State private var schedule = ScheduleChoice(cron: "0 9 * * 1-5")
    @State private var newPermission = ""
    @State private var addingPermission = false

    private var id: Int64 { form.detail.id }
    private var saveState: AutomationEditorCenter.SaveState? { editor.saving[id] }
    private var isBusy: Bool { saveState == .saving || saveState == .validating }
    /// The controls write the frontmatter only while the form describes it.
    private var controlsEnabled: Bool { !form.frontmatterEditedInRecipe }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    notes
                    Group {
                        nameField
                        runsSection
                        spendSection
                        mayDoSection
                    }
                    .disabled(!controlsEnabled || isBusy)
                    if !form.detail.isNewRecipe { stateSection }
                    scriptSection
                    messages
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
                .padding(16)
        }
        .frame(width: 760, height: 820)
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

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(form.detail.isNewRecipe ? "New automation" : "Edit “\(form.detail.name)”")
                .font(.title2.weight(.semibold))
            Text(form.detail.isNewRecipe
                ? "Saved as " + ((form.detail.path as NSString).abbreviatingWithTildeInPath as NSString)
                    .appendingPathComponent(AutomationEditorCenter.slug(forName: form.fields.name) + ".md")
                : (form.detail.path as NSString).abbreviatingWithTildeInPath)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder private var notes: some View {
        if form.lostFormEdit {
            Label("Your last change in the form did not land: the recipe below was edited at the same moment. The "
                + "form is paused; save, or discard to use the form again.", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        } else if form.frontmatterEditedInRecipe {
            Label("The settings were changed in the recipe below, so the form is paused. Save, or discard to use "
                + "the form again.", systemImage: "info.circle")
                .foregroundStyle(.orange)
        }
    }

    private var nameField: some View {
        labeled("Name") {
            TextField("Name", text: $form.fields.name)
                .textFieldStyle(.roundedBorder)
        }
    }

    // MARK: - Runs

    private enum TriggerChoice: CaseIterable {
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
            HStack(spacing: 6) {
                ForEach(TriggerChoice.allCases, id: \.self) { choice in
                    if choice == currentChoice {
                        Button(choice.title) { choose(choice) }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button(choice.title) { choose(choice) }
                            .buttonStyle(.bordered)
                    }
                }
            }
            switch form.fields.trigger {
            case .schedule:
                schedulePicker
            case let .button(label, confirm):
                HStack {
                    TextField("Button label", text: Binding(
                        get: { label },
                        set: { form.fields.trigger = .button(label: $0, confirm: confirm) }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    Toggle("Ask before running", isOn: Binding(
                        get: { confirm },
                        set: { form.fields.trigger = .button(label: label, confirm: $0) }
                    ))
                }
            case let .event(type, filter):
                eventEditor(type: type, filter: filter)
            case .manual:
                EmptyView()
            }
        }
    }

    private var schedulePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Repeats", selection: $schedule.repeats) {
                ForEach(ScheduleChoice.Repeat.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            HStack(spacing: 8) {
                switch schedule.repeats {
                case .custom:
                    TextField("minute hour day month weekday", text: $schedule.custom)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                        .frame(width: 260)
                case .hourly:
                    Text("at minute")
                    Picker("Minute", selection: $schedule.minute) {
                        ForEach(0..<60, id: \.self) { Text(String(format: ":%02d", $0)).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 80)
                case .weekly, .weekdays, .daily:
                    if schedule.repeats == .weekly {
                        Picker("Day", selection: $schedule.weekday) {
                            ForEach(0..<7, id: \.self) { Text(Calendar.current.weekdaySymbols[$0]).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 140)
                    }
                    Text("at")
                    Picker("Hour", selection: $schedule.hour) {
                        ForEach(0..<24, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 70)
                    Picker("Minute", selection: $schedule.minute) {
                        ForEach(0..<60, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 70)
                }
            }
            Text(schedule.nextLine(now: Date()))
                .font(.callout)
                .foregroundStyle(.secondary)
            Toggle("If the Mac was asleep at that time, run once when it wakes", isOn: Binding(
                get: { form.fields.missed != "skip" },
                set: { form.fields.missed = $0 ? "run_once" : "skip" }
            ))
            .toggleStyle(.checkbox)
        }
    }

    private func eventEditor(type: String, filter: [String: String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Event", selection: Binding(
                get: { type },
                set: { form.fields.trigger = AutomationFormModel.eventTrigger(type: $0, keeping: filter) }
            )) {
                ForEach(AutomationFormModel.eventTypes, id: \.self) { Text($0).tag($0) }
            }
            .frame(width: 320)
            ForEach(filter.keys.sorted(), id: \.self) { key in
                HStack {
                    Text(key).font(.callout.monospaced())
                    TextField("value or glob", text: Binding(
                        get: { filter[key] ?? "" },
                        set: { value in
                            var next = filter
                            next[key] = value
                            form.fields.trigger = .event(type: type, where: next)
                        }
                    ))
                    .textFieldStyle(.roundedBorder)
                    Button {
                        var next = filter
                        next[key] = nil
                        form.fields.trigger = .event(type: type, where: next)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove filter \(key)")
                }
            }
            Text("Runs after a sync brings something new, at most once per sync cycle. "
                + "Narrow it with a where filter in the recipe text.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Spend

    private var spendSection: some View {
        labeled("Each run may spend") {
            HStack(spacing: 10) {
                TextField("Tokens", value: $form.fields.budgetTokens, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 110)
                Text("tokens")
                TextField("Minutes", value: $form.fields.budgetMinutes, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                Text("minutes")
            }
            HStack(spacing: 18) {
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
            FlowLayout(spacing: 6) {
                ForEach(form.fields.permissions, id: \.self) { permission in
                    permissionChip(permission)
                }
                Button("+ Add") { addingPermission = true }
                    .buttonStyle(.borderless)
                    .popover(isPresented: $addingPermission) { addPermissionPopover.popoverSurface() }
            }
            HStack(spacing: 14) {
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
        HStack(spacing: 4) {
            Text(AutomationCardPresentation.permissionLine(permission))
            Button {
                form.fields.permissions.removeAll { $0 == permission }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove \(permission)")
        }
        .help(permission)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(0.12), in: Capsule())
    }

    private var addPermissionPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("One permission, as in the recipe: gmail:read@work, llm:light, tool:create_jira_issue")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("capability:verb@scope", text: $newPermission)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
                .onSubmit(addPermission)
            HStack {
                Spacer()
                Button("Add", action: addPermission)
                    .keyboardShortcut(.defaultAction)
                    .disabled(newPermission.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(12)
        .frame(width: 340)
    }

    private func addPermission() {
        let entry = newPermission.trimmingCharacters(in: .whitespaces)
        guard !entry.isEmpty else { return }
        if !form.fields.permissions.contains(entry) { form.fields.permissions.append(entry) }
        newPermission = ""
        addingPermission = false
    }

    // MARK: - Enabled and Auto

    private var stateSection: some View {
        labeled("State") {
            Toggle("Enabled", isOn: Binding(
                get: { vm.items.first { $0.id == id }?.automation.enabled ?? form.detail.enabled },
                set: { on in Task { await vm.setEnabled(id, on) } }
            ))
            .toggleStyle(.switch)
            if !form.detail.autoTools.isEmpty {
                Text("Auto — runs these tools without asking you each time")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                ForEach(form.detail.autoTools.filter(\.alwaysAsks), id: \.tool) { entry in
                    HStack(spacing: 8) {
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
                if let error = editor.autoErrors[id] {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
        }
    }

    // MARK: - Script

    private var scriptSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Script")
                    .font(.headline)
                Spacer()
                if let onChangeInWords {
                    Button("Change it in words instead") { onChangeInWords(id) }
                        .buttonStyle(.link)
                }
            }
            if let error = form.buffer.pageError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            RecipeEditorView(buffer: form.buffer, readOnly: false, slug: form.detail.slug)
                .frame(height: 300)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    @ViewBuilder private var messages: some View {
        ForEach(form.problems, id: \.self) { problem in
            Label(problem, systemImage: "exclamationmark.circle")
                .foregroundStyle(.red)
        }
        if case let .failed(message) = saveState {
            Label(message, systemImage: "xmark.octagon")
                .foregroundStyle(.red)
                .textSelection(.enabled)
            if message == AutomationEditorCenter.changedOnDisk, !form.detail.isNewRecipe {
                Button("Reload the recipe (keeps your text aside)") { Task { await editor.reloadFromDisk(id) } }
                    .disabled(isBusy)
            }
        }
        if let aside = editor.keptAside[id] {
            HStack(spacing: 8) {
                Label("Reloaded from disk. Your previous text is kept aside.", systemImage: "doc.on.clipboard")
                    .foregroundStyle(.secondary)
                Button("Copy your text") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(aside, forType: .string)
                }
            }
        }
        switch vm.dryRuns[id] {
        case .running:
            Label("Dry run…", systemImage: "hourglass").foregroundStyle(.secondary)
        case let .done(_, lines, _, status):
            VStack(alignment: .leading, spacing: 4) {
                Text("Dry run · nothing was written · \(status)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in Text(line).font(.callout) }
            }
        case let .failed(message):
            Label(message, systemImage: "xmark.octagon").foregroundStyle(.red)
        case nil:
            EmptyView()
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Changing the schedule, budget, permissions or script needs your confirmation again.")
                Text("Comments in the settings block are not kept when the form rewrites it.")
                    .foregroundStyle(.tertiary)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Spacer()
            if isBusy {
                ProgressView().controlSize(.small)
            }
            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
            if !form.detail.isNewRecipe {
                Button("Dry run") { Task { await vm.dryRun(id) } }
                    .disabled(form.buffer.isDirty || vm.busy[id] != nil)
                    .help(form.buffer.isDirty ? "Save first: a dry run runs the saved recipe" : "")
            }
            Button("Save and confirm") { Task { await editor.save(id) } }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                // A new recipe saves as it is too: there is no file yet.
                .disabled(!(form.buffer.isDirty || form.detail.isNewRecipe)
                    || !form.problems.isEmpty || isBusy)
        }
    }

    private func labeled(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
