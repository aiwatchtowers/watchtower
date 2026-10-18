import SwiftUI

/// The gallery samples of the kit's soft buttons, field, settings rows, row
/// and panel split (style guide #719, Task 6). The `kit-new-components`
/// design shot renders them together (`GalleryNewComponents`).

/// The secondary and quiet buttons at two control sizes, enabled and not.
struct GallerySoftButtons: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            ForEach([ControlSize.small, .regular], id: \.self) { size in
                HStack(spacing: Spacing.cozy) {
                    Button("Cancel") {}.buttonStyle(.kitSecondary)
                    Button("Cancel") {}.buttonStyle(.kitSecondary).disabled(true)
                    Button("Show more") {}.buttonStyle(.kitQuiet)
                    Button("Show more") {}.buttonStyle(.kitQuiet).disabled(true)
                }
                .controlSize(size)
            }
        }
    }
}

/// An empty field and a filled one.
struct GalleryFields: View {
    @State private var empty = ""
    @State private var filled = "billing@example.com"

    var body: some View {
        HStack(spacing: Spacing.medium) {
            TextField("Search acme", text: $empty).textFieldStyle(.kit)
            TextField("Email", text: $filled).textFieldStyle(.kit)
        }
        .frame(maxWidth: 480)
    }
}

/// A settings section with a switch, a captioned switch and a picker.
struct GallerySettings: View {
    @State private var notify = true
    @State private var digest = false
    @State private var cadence = "Daily"

    var body: some View {
        SettingsSection(title: "Notifications", footer: "Applies to the acme workspace only.") {
            SettingRow(title: "Notify when a run finishes") {
                Toggle("Notify when a run finishes", isOn: $notify).labelsHidden()
            }
            SettingRow(title: "Morning digest", caption: "A summary of the night's activity") {
                Toggle("Morning digest", isOn: $digest).labelsHidden()
            }
            SettingRow(title: "Cadence") {
                Picker("Cadence", selection: $cadence) {
                    ForEach(["Hourly", "Daily", "Weekly"], id: \.self) { Text($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
        .frame(maxWidth: 480)
    }
}

/// Three rows, the middle one selected.
struct GalleryRows: View {
    var body: some View {
        VStack(spacing: Spacing.tight) {
            ForEach(Array(["acme setup", "Billing export", "Login redirect"].enumerated()), id: \.offset) { index, title in
                Label(title, systemImage: "doc.text").kitRow(isSelected: index == 1)
            }
        }
        .frame(maxWidth: 280)
    }
}

/// A main area with its side panel, which a quiet button shows and hides.
struct GalleryPanelSplit: View {
    @State private var isPanelShown = true

    var body: some View {
        PanelSplit(isPanelShown: isPanelShown,
                   width: PanelSplitWidth(key: "designGallery.panelWidth", range: 160...320, ideal: 200)) {
            VStack(alignment: .leading, spacing: Spacing.regular) {
                Text("Billing export for acme").font(.headline)
                Button(isPanelShown ? "Hide panel" : "Show panel") { isPanelShown.toggle() }
                    .buttonStyle(.kitQuiet)
            }
            .padding(Spacing.medium)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } panel: {
            Text("Details")
                .padding(Spacing.medium)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .panelBackground()
        }
        .frame(maxWidth: 560)
        .frame(height: 120)
        .clipShape(RoundedRectangle(cornerRadius: Radius.container, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.container, style: .continuous)
            .strokeBorder(Stroke.hairlineColor, lineWidth: Stroke.hairline))
    }
}

/// Every Task 6 sample in gallery order, for the `kit-new-components` shot.
struct GalleryNewComponents: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.wide) {
            GallerySection(title: "Buttons") { GallerySoftButtons() }
            GallerySection(title: "Fields") { GalleryFields() }
            GallerySection(title: "Settings") { GallerySettings() }
            GallerySection(title: "Rows") { GalleryRows() }
            GallerySection(title: "Panel split") { GalleryPanelSplit() }
        }
    }
}
