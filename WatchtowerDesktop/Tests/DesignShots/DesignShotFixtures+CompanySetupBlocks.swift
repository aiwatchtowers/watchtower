import AppKit
import DesignKit
import SwiftUI
import WatchtowerCore
@testable import WatchtowerDesktop

// Building blocks of the company setup mockups (#1887, spec
// `docs/superpowers/specs/2026-11-18-company-setup-screens-design.md`).
// Design only: every scene is a list of these values drawn by one renderer,
// so a frame is data, not a hand-made view. Nothing here is wired into the app.

enum MockKind { case primary, secondary, quiet, destructive }

struct MockButton {
    let title: String
    var kind = MockKind.secondary
    var disabled = false
}

enum MockMark { case done, running, waiting, failed, skipped }

struct MockStep {
    let title: String
    let mark: MockMark
    var detail: String?
}

struct MockChoice {
    let title: String
    let detail: String
    let selected: Bool
}

struct MockCheck {
    let title: String
    var detail: String?
    var checked = true
    var disabled = false
    var trailing: String?
}

struct MockField {
    let label: String
    let value: String
    var secure = false
    var readOnly = false
}

struct MockNotice {
    let icon: String
    let tone: Color
    var title: String?
    let body: String
}

struct MockAccount {
    let title: String
    let status: String
    let tone: Color
    var tag: String?
    var button: MockButton?
    var note: String?
    var statusIsProblem = false
}

struct MockValue {
    let label: String
    let value: String
    let button: String
}

/// One piece of a scene.
enum MockBlock {
    case title(String, String?)
    case text(String, secondary: Bool)
    case notice(MockNotice)
    case steps([MockStep], caption: String?)
    case guide([String], extras: [Int: String])
    case fields([MockField], error: String?)
    case choices([MockChoice])
    case checks([MockCheck])
    case drop(String?)
    case values([MockValue])
    case buttons(leading: [MockButton], trailing: [MockButton])
    case problem(String, MockButton?)
    case busy(String)
    case account(MockAccount)
    case managedBadge
}

extension MockBlock {
    static func caption(_ text: String) -> MockBlock { .text(text, secondary: true) }
    static func body(_ text: String) -> MockBlock { .text(text, secondary: false) }
    static func warning(_ text: String, title: String? = nil) -> MockBlock {
        .notice(MockNotice(icon: "exclamationmark.triangle.fill", tone: Tone.warning, title: title, body: text))
    }
    static func success(_ title: String?, _ text: String) -> MockBlock {
        .notice(MockNotice(icon: "checkmark.circle.fill", tone: Tone.success, title: title, body: text))
    }
}

/// Draws one block with the design kit.
struct MockBlockView: View {
    let block: MockBlock

    var body: some View {
        switch block {
        case let .title(title, intro):
            VStack(alignment: .leading, spacing: Spacing.small) {
                Text(title).font(.title3.weight(.semibold))
                if let intro { wrapped(Text(intro).font(.caption).foregroundStyle(.secondary)) }
            }
        case let .text(text, secondary):
            if secondary {
                wrapped(Text(text).font(.caption).foregroundStyle(.secondary))
            } else {
                wrapped(Text(text).font(.callout))
            }
        case let .notice(notice):
            MockNoticeView(notice: notice)
        case let .steps(steps, caption):
            MockStepsView(steps: steps, caption: caption)
        case let .buttons(leading, trailing):
            HStack(spacing: Spacing.regular) {
                ForEach(Array(leading.enumerated()), id: \.offset) { _, button in MockButtonView(button: button) }
                Spacer(minLength: Spacing.regular)
                ForEach(Array(trailing.enumerated()), id: \.offset) { _, button in MockButtonView(button: button) }
            }
        case let .problem(text, button):
            MockProblemView(text: text, button: button)
        case let .busy(text):
            HStack(spacing: Spacing.regular) {
                ProgressView().controlSize(.small)
                wrapped(Text(text).font(.caption).foregroundStyle(.secondary))
            }
        case .managedBadge:
            ManagedByOrganizationBadge()
        default:
            MockFormBlockView(block: block)
        }
    }

    private func wrapped(_ text: some View) -> some View {
        text.fixedSize(horizontal: false, vertical: true)
    }
}

/// The form-like half of the blocks (kept apart so neither switch grows long).
struct MockFormBlockView: View {
    let block: MockBlock

    var body: some View {
        switch block {
        case let .guide(lines, extras):
            MockGuideView(lines: lines, extras: extras)
        case let .fields(fields, error):
            MockFieldsView(fields: fields, error: error)
        case let .choices(choices):
            MockChoicesView(choices: choices)
        case let .checks(checks):
            MockChecksView(checks: checks)
        case let .drop(file):
            MockDropView(file: file)
        case let .values(values):
            MockValuesView(values: values)
        case let .account(account):
            MockAccountRow(account: account)
        default:
            EmptyView()
        }
    }
}

struct MockButtonView: View {
    let button: MockButton

    var body: some View {
        switch button.kind {
        case .primary: Button(button.title) {}.buttonStyle(.kitPrimary).disabled(button.disabled)
        case .secondary: Button(button.title) {}.buttonStyle(.kitSecondary).disabled(button.disabled)
        case .quiet: Button(button.title) {}.buttonStyle(.kitQuiet).disabled(button.disabled)
        case .destructive: Button(button.title) {}.buttonStyle(.kitDestructive).disabled(button.disabled)
        }
    }
}

struct MockNoticeView: View {
    let notice: MockNotice

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.regular) {
            Image(systemName: notice.icon).foregroundStyle(notice.tone)
            VStack(alignment: .leading, spacing: Spacing.small) {
                if let title = notice.title { Text(title).font(.headline).fixedSize(horizontal: false, vertical: true) }
                Text(notice.body).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

struct MockProblemView: View {
    let text: String
    let button: MockButton?

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.regular) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Tone.warning)
            Text(text).font(.caption).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Spacing.regular)
            if let button { MockButtonView(button: button) }
        }
    }
}

struct MockMarkView: View {
    let mark: MockMark

    var body: some View {
        Group {
            switch mark {
            case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(Tone.success)
            case .running: ProgressView().controlSize(.small)
            case .waiting: Image(systemName: "circle").foregroundStyle(.tertiary)
            case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(Tone.status("gray"))
            case .skipped: Image(systemName: "minus.circle").foregroundStyle(.tertiary)
            }
        }
        .frame(width: ListLayout.markColumn)
    }
}

struct MockStepsView: View {
    let steps: [MockStep]
    let caption: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
                    MockMarkView(mark: step.mark)
                    VStack(alignment: .leading, spacing: Spacing.tight) {
                        Text(step.title).font(.callout).foregroundStyle(step.mark == .waiting ? .secondary : .primary)
                        if let detail = step.detail {
                            Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            if let caption {
                Text(caption).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

/// Numbered deep links into a vendor's console, each with **Open** and an
/// optional extra button (Copy scopes, Copy callback URLs).
struct MockGuideView: View {
    let lines: [String]
    let extras: [Int: String]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
                    Text("\(index + 1).").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    Text(line).font(.callout).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: Spacing.regular)
                    if let extra = extras[index] { Button(extra) {}.buttonStyle(.kitQuiet) }
                    Button(CompanySetupMockCopy.open) {}.buttonStyle(.kitSecondary)
                }
            }
        }
        .padding(Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

struct MockFieldsView: View {
    let fields: [MockField]
    let error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.compact) {
            ForEach(Array(fields.enumerated()), id: \.offset) { _, field in
                VStack(alignment: .leading, spacing: Spacing.tight) {
                    Text(field.label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    if field.secure {
                        SecureField(field.label, text: .constant(field.value)).textFieldStyle(.kit)
                    } else {
                        TextField(field.label, text: .constant(field.value)).textFieldStyle(.kit).disabled(field.readOnly)
                    }
                }
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(Tone.error).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct MockChoicesView: View {
    let choices: [MockChoice]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            ForEach(Array(choices.enumerated()), id: \.offset) { _, choice in
                HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
                    Image(systemName: choice.selected ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(choice.selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                    VStack(alignment: .leading, spacing: Spacing.tight) {
                        Text(choice.title).font(.callout)
                        Text(choice.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(Spacing.regular)
                .kitRow(isSelected: choice.selected)
            }
        }
    }
}

struct MockChecksView: View {
    let checks: [MockCheck]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.compact) {
            ForEach(Array(checks.enumerated()), id: \.offset) { _, check in
                HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
                    Image(systemName: check.checked ? "checkmark.square.fill" : "square")
                        .foregroundStyle(check.checked && !check.disabled ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                    VStack(alignment: .leading, spacing: Spacing.tight) {
                        Text(check.title).font(.callout).foregroundStyle(check.disabled ? .secondary : .primary)
                        if let detail = check.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer(minLength: Spacing.regular)
                    if let trailing = check.trailing {
                        if check.disabled {
                            Chip(text: trailing, color: Tone.success, dot: true)
                        } else {
                            Button(trailing) {}.buttonStyle(.kitQuiet)
                        }
                    }
                }
            }
        }
        .padding(Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

struct MockDropView: View {
    let file: String?

    var body: some View {
        HStack(spacing: Spacing.regular) {
            Image(systemName: file == nil ? "square.and.arrow.down" : "doc.text")
                .foregroundStyle(file == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Tone.success))
            Text(file ?? CompanySetupMockCopy.dropJSON)
                .font(.callout)
                .foregroundStyle(file == nil ? .secondary : .primary)
            Spacer(minLength: 0)
        }
        .padding(Spacing.large)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

struct MockValuesView: View {
    let values: [MockValue]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                VStack(alignment: .leading, spacing: Spacing.tight) {
                    if !value.label.isEmpty {
                        Text(value.label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    HStack(spacing: Spacing.regular) {
                        Text(value.value).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: Spacing.regular)
                        Button(value.button) {}.buttonStyle(.kitSecondary)
                    }
                }
            }
        }
        .padding(Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

/// An account row in a Connections detail: dot, name, optional tag, the
/// status line (in `Tone.error` when it needs the owner), an optional note
/// and one action.
struct MockAccountRow: View {
    let account: MockAccount

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
            Circle().fill(account.tone).frame(width: IconSize.stateDot, height: IconSize.stateDot)
            VStack(alignment: .leading, spacing: Spacing.tight) {
                HStack(spacing: Spacing.small) {
                    Text(account.title).font(.callout)
                    if let tag = account.tag { OutlineTag(text: tag) }
                }
                Text(account.status)
                    .font(.caption)
                    .foregroundStyle(account.statusIsProblem ? AnyShapeStyle(Tone.error) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
                if let note = account.note {
                    Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Spacing.regular)
            if let button = account.button { MockButtonView(button: button) }
        }
        .padding(.vertical, Spacing.small)
    }
}
