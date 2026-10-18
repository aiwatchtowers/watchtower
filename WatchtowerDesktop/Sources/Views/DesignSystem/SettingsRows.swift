import SwiftUI

/// A titled group of settings (style guide #719): the title, then the rows
/// on one soft card, spaced apart with no dividers, and an optional footer
/// note under the card.
struct SettingsSection<Content: View>: View {
    let title: String
    var footer: String?
    @ViewBuilder let content: Content

    init(title: String, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.compact) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: Spacing.regular) { content }
                .padding(Spacing.medium)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Fill.card, in: RoundedRectangle(cornerRadius: Radius.container, style: .continuous))
            if let footer {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// One setting: its title and an optional caption on the left, the control
/// trailing. The row makes a `Toggle` a small switch (and the control small).
/// It is one accessibility element labelled by the title (the caption is its
/// hint), so the control's own label may be empty.
struct SettingRow<Control: View>: View {
    let title: String
    var caption: String?
    @ViewBuilder let control: Control

    init(title: String, caption: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.caption = caption
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.medium) {
            VStack(alignment: .leading, spacing: Spacing.tight) {
                Text(title).font(.body)
                if let caption {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: Spacing.medium)
            control
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityHint(caption ?? "")
    }
}
