import DesignKit
import SwiftUI
import WatchtowerCore

/// Settings → Watchman's edits (phase 2), each a `WatchmanCenter` call over
/// the CLI. The view keeps only the open draft; the center keeps the lines.
struct WatchmanEditActions {
    var saveProfile: @MainActor (_ workbench: Int64, _ key: String, _ text: String) async -> Bool = { _, _, _ in false }
    var unpin: @MainActor (_ workbench: Int64, _ key: String) async -> Void = { _, _ in }
    var addLimit: @MainActor (WatchmanLimitKind, _ pattern: String) async -> Bool = { _, _ in false }
    var removeLimit: @MainActor (_ id: Int64) async -> Void = { _ in }
    var clearError: @MainActor (WatchmanEditSlot) -> Void = { _ in }
}

/// The one editor open on the screen: a profile entry (a category's text or
/// the sleep window) or the add-limit form.
enum WatchmanSettingsDraft: Equatable {
    case entry(workbench: Int64, key: String, text: String)
    case limit(kind: WatchmanLimitKind, pattern: String)

    func isEntry(workbench: Int64, key: String) -> Bool {
        if case let .entry(open, openKey, _) = self { return open == workbench && openKey == key }
        return false
    }
}

/// The text of the open entry draft for `workbench`/`key`; nil while
/// another editor (or none) is open.
@MainActor
func entryDraftText(_ draft: Binding<WatchmanSettingsDraft?>, workbench: Int64, key: String) -> Binding<String>? {
    guard case let .entry(open, openKey, _)? = draft.wrappedValue, open == workbench, openKey == key else { return nil }
    return Binding(
        get: {
            if case let .entry(_, _, text)? = draft.wrappedValue { return text }
            return ""
        },
        set: { draft.wrappedValue = .entry(workbench: workbench, key: key, text: $0) }
    )
}

/// An entry's editor in place: the text, its error line, the pinned note,
/// **Save** / **Cancel**.
struct WatchmanInlineEditor: View {
    @Binding var text: String
    let multiline: Bool
    var placeholder = ""
    let note: String
    let error: String?
    let saving: Bool
    let onSave: () -> Void
    let onCancel: () -> Void

    private typealias Copy = WatchmanSettingsCopy

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            if multiline {
                TextEditor(text: $text)
                    .disabled(saving)
                    .font(.callout)
                    .scrollContentBackground(.hidden)
                    .padding(Spacing.small)
                    .frame(minHeight: ListLayout.rowMinHeight * 4)
                    .background(Surface.text, in: RoundedRectangle(cornerRadius: Radius.control))
            } else {
                TextField(placeholder, text: $text)
                    .textFieldStyle(.kit)
                    .font(.body.monospacedDigit())
                    .frame(width: ListLayout.textColumn)
                    .disabled(saving)
                    .onSubmit(onSave)
            }
            if let error { WatchmanErrorLine(text: error) }
            Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Spacing.regular) {
                Button(Copy.save, action: onSave).buttonStyle(.kitSecondary).disabled(saving)
                Button(Copy.cancel, action: onCancel).buttonStyle(.kitQuiet)
                if saving { ProgressView().controlSize(.small) }
            }
        }
    }
}

struct WatchmanErrorLine: View {
    let text: String

    var body: some View {
        Text(text).font(.caption).foregroundStyle(Tone.error).fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - What Watchman learned

/// One learned workbench's category texts: each with **Edit**, and
/// **Unpin** on a text the owner pinned.
struct WatchmanProfileSection: View {
    let row: WatchmanWorkbenchStatus
    let several: Bool
    let editing: WatchmanEditingData
    let actions: WatchmanEditActions
    @Binding var draft: WatchmanSettingsDraft?

    private typealias Copy = WatchmanSettingsCopy

    var body: some View {
        SettingsSection(title: Copy.profileTitle(name: row.name, several: several), caption: Copy.profileCaption) {
            if let readError = editing.profileReadErrors[row.workbench] {
                Text(Copy.profileReadFailed(readError))
                    .font(.caption)
                    .foregroundStyle(Tone.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let profile = editing.profiles[row.workbench] {
                if profile.categories.isEmpty {
                    Text(Copy.profileEmpty).font(.callout).foregroundStyle(.secondary)
                }
                ForEach(profile.categories, id: \.key) { entry($0) }
            } else if editing.isLoadingProfile(row.workbench) {
                HStack(spacing: Spacing.regular) {
                    ProgressView().controlSize(.small)
                    Text(Copy.profileLoading).font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func entry(_ entry: WatchmanProfileEntry) -> some View {
        let slot = WatchmanEditSlot.profile(workbench: row.workbench, key: entry.key)
        let saving = editing.saving.contains(slot)
        let text = entryDraftText($draft, workbench: row.workbench, key: entry.key)
        return VStack(alignment: .leading, spacing: Spacing.small) {
            HStack(spacing: Spacing.regular) {
                Text(entry.key).font(.callout.weight(.semibold))
                OutlineTag(text: entry.pinned ? Copy.profilePinned : Copy.profileLearned(entry.updatedAt))
                Spacer(minLength: Spacing.regular)
                if text == nil {
                    Button(Copy.edit) {
                        actions.clearError(slot)
                        draft = .entry(workbench: row.workbench, key: entry.key, text: entry.text)
                    }
                    .buttonStyle(.kitSecondary)
                    .disabled(saving)
                    if entry.pinned {
                        Button(Copy.unpin) { Task { await actions.unpin(row.workbench, entry.key) } }
                            .buttonStyle(.kitQuiet)
                            .disabled(saving)
                    }
                }
            }
            .frame(minHeight: ListLayout.rowMinHeight)
            if let text {
                WatchmanInlineEditor(
                    text: text, multiline: true, note: Copy.profilePinnedNote, error: editing.errors[slot],
                    saving: saving,
                    onSave: { save(entry.key, text.wrappedValue) },
                    onCancel: {
                        actions.clearError(slot)
                        draft = nil
                    }
                )
            } else {
                ForEach(Array(entry.lines.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
                        Text(Copy.bullet).foregroundStyle(.secondary)
                        Text(line).fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.callout)
                }
                if let error = editing.errors[slot] { WatchmanErrorLine(text: error) }
            }
        }
        .padding(.bottom, Spacing.small)
    }

    private func save(_ key: String, _ text: String) {
        let workbench = row.workbench
        Task {
            if await actions.saveProfile(workbench, key, text), draft?.isEntry(workbench: workbench, key: key) == true {
                draft = nil
            }
        }
    }
}

// MARK: - Your hard limits

/// The owner's limits with **Remove** (confirmed), **Add a Limit…** and its
/// form, then the built-in rows on one read-only line.
struct WatchmanLimitsSection: View {
    let editing: WatchmanEditingData
    let actions: WatchmanEditActions
    @Binding var draft: WatchmanSettingsDraft?
    /// The owner's row whose **Remove** waits for confirmation.
    @State private var removing: WatchmanLimitRow?

    private typealias Copy = WatchmanSettingsCopy

    var body: some View {
        let rows = editing.limits?.rows ?? []
        let saving = editing.saving.contains(.limits)
        SettingsSection(title: Copy.limitsTitle, caption: Copy.limitsCaption) {
            if let readError = editing.limitsReadError {
                Text(Copy.limitsReadFailed(readError))
                    .font(.caption)
                    .foregroundStyle(Tone.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(rows.filter { !$0.isBuiltin }, id: \.removableID) { ownerRow($0, saving: saving) }
            if case let .limit(kind, pattern)? = draft {
                form(kind: kind, pattern: pattern, saving: saving)
            } else {
                if let error = editing.errors[.limits] { WatchmanErrorLine(text: error) }
                Button(Copy.addLimit) {
                    actions.clearError(.limits)
                    draft = .limit(kind: .command, pattern: "")
                }
                .buttonStyle(.kitSecondary)
                .disabled(editing.limits == nil)
            }
            if let builtin = editing.limits?.builtin, !builtin.isEmpty {
                HStack(spacing: Spacing.regular) {
                    Image(systemName: "lock").foregroundStyle(.secondary)
                    Text(Copy.builtinSummary(builtin)).font(.caption).foregroundStyle(.secondary)
                }
                .help(Copy.builtinHelp(builtin))
                .padding(.top, Spacing.small)
            }
        }
        .confirmationDialog(
            removing.map { Copy.removeConfirmTitle($0.text) } ?? "",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            presenting: removing
        ) { row in
            Button(Copy.remove, role: .destructive) {
                if let id = row.removableID { Task { await actions.removeLimit(id) } }
            }
            Button(Copy.cancel, role: .cancel) {}
        } message: { _ in
            Text(Copy.removeConfirmMessage)
        }
    }

    private func ownerRow(_ row: WatchmanLimitRow, saving: Bool) -> some View {
        HStack(spacing: Spacing.regular) {
            Image(systemName: "hand.raised").foregroundStyle(.secondary)
            Text(row.text).font(.callout.monospaced())
            if let kind = row.kind { OutlineTag(text: Copy.limitKind(kind)) }
            Spacer(minLength: Spacing.regular)
            if row.removableID != nil {
                Button(Copy.remove) { removing = row }
                    .buttonStyle(.kitQuiet)
                    .disabled(saving)
            }
        }
        .frame(minHeight: ListLayout.rowMinHeight)
    }

    private func form(kind: WatchmanLimitKind, pattern: String, saving: Bool) -> some View {
        let kindBinding = Binding(
            get: { kind },
            set: { draft = .limit(kind: $0, pattern: pattern) }
        )
        let patternBinding = Binding(
            get: { pattern },
            set: { draft = .limit(kind: kind, pattern: $0) }
        )
        return VStack(alignment: .leading, spacing: Spacing.small) {
            HStack(spacing: Spacing.regular) {
                KitSegmentedPicker(
                    title: Copy.limitKindTitle, selection: kindBinding,
                    segments: WatchmanLimitKind.allCases.map { KitSegment(value: $0, title: Copy.limitKind($0)) }
                )
                TextField(Copy.limitPlaceholder(kind), text: patternBinding)
                    .textFieldStyle(.kit)
                    .font(.body.monospaced())
                    .onSubmit { add(kind, pattern) }
            }
            .disabled(saving)
            Text(Copy.limitHint(kind)).font(.caption).foregroundStyle(.secondary)
            if let error = editing.errors[.limits] { WatchmanErrorLine(text: error) }
            HStack(spacing: Spacing.regular) {
                Button(Copy.add) { add(kind, pattern) }.buttonStyle(.kitSecondary).disabled(saving)
                Button(Copy.cancel) {
                    actions.clearError(.limits)
                    draft = nil
                }
                .buttonStyle(.kitQuiet)
                if saving { ProgressView().controlSize(.small) }
            }
        }
        .padding(.vertical, Spacing.small)
    }

    private func add(_ kind: WatchmanLimitKind, _ pattern: String) {
        Task {
            if await actions.addLimit(kind, pattern), case .limit? = draft { draft = nil }
        }
    }
}
