import DesignKit
import SwiftUI

// The Patterns pages (spec §2.3): the kit's components composed the way a
// real screen composes them, on the app's own surfaces.

// MARK: - Settings

struct SettingsPatternPage: View {
    @State private var launchAtLogin = true
    @State private var showInMenuBar = true
    @State private var notifyRuns = true
    @State private var digest = false
    @State private var cadence = "Daily"
    @State private var email = "owner@example.com"
    @State private var workspace = "acme"

    var body: some View {
        Sample("A settings page of a new window: titled sections on soft cards, no dividers, the one primary action trailing",
               usage: "SettingsSection(title: \"Notifications\", footer: …) { SettingRow(title:caption:) { control } }") {
            VStack(alignment: .leading, spacing: Spacing.wide) {
                SettingsSection(title: "General") {
                    SettingRow(title: "Launch at login") {
                        Toggle("Launch at login", isOn: $launchAtLogin).labelsHidden()
                    }
                    SettingRow(title: "Show in the menu bar", caption: "The tray shows sync state and the next meeting") {
                        Toggle("Show in the menu bar", isOn: $showInMenuBar).labelsHidden()
                    }
                }
                SettingsSection(title: "Notifications", footer: "Applies to the acme workspace only.") {
                    SettingRow(title: "Notify when a run finishes") {
                        Toggle("Notify when a run finishes", isOn: $notifyRuns).labelsHidden()
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
                SettingsSection(title: "Account") {
                    SettingRow(title: "Workspace", caption: "Shown in the window title") {
                        TextField("Workspace", text: $workspace).textFieldStyle(.kit).frame(width: 200)
                    }
                    SettingRow(title: "Email") {
                        TextField("Email", text: $email).textFieldStyle(.kit).frame(width: 200)
                    }
                    SettingRow(title: "Signed in as owner@example.com", caption: "Disconnecting removes the local token") {
                        Button("Disconnect") {}.buttonStyle(.kitDestructive)
                    }
                }
                HStack(spacing: Spacing.regular) {
                    Spacer()
                    Button("Revert") {}.buttonStyle(.kitSecondary)
                    Button("Save") {}.buttonStyle(.kitPrimary)
                }
            }
            .frame(maxWidth: 560)
        }
    }
}

// MARK: - Panels

struct PanelsPage: View {
    private static let sessions = ["acme setup", "Billing export", "Login redirect", "Invoice PDF layout", "Weekly sync notes"]
    private static let targets = ["CSV columns", "Nightly schedule", "Retry failed rows", "Email the report"]

    @AppStorage("gallery.sessionsPanelWidth") private var sessionsWidth = 220.0
    @State private var liveSessionsWidth: Double?
    @State private var session = "Billing export"
    @State private var target: String? = "Nightly schedule"

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.hero) {
            Sample("A tabbed side panel (drag its edge), the content on the detail backdrop, and a detail panel "
                   + "beside it (drag its edge; pick a target to open it, Close to hide it)",
                   usage: "PanelSplit(isPanelShown:width: PanelSplitWidth(key:range:ideal:)) { main } panel: { detail }") {
                HStack(spacing: 0) {
                    sessionsPanel
                        .frame(width: liveSessionsWidth ?? min(max(sessionsWidth, 160), 320))
                        .panelSurface()
                    PanelResizeHandle(width: $sessionsWidth, liveWidth: $liveSessionsWidth, range: 160...320)
                        .detailBackground()
                    PanelSplit(isPanelShown: target != nil,
                               width: PanelSplitWidth(key: "gallery.detailPanelWidth", range: 220...360, ideal: 260)) {
                        board
                    } panel: {
                        detailPanel
                    }
                    .detailBackground()
                }
                .frame(height: 380)
                .gallerySampleFrame()
            }
            Sample("panelListStyle(): a hand-built split's list over the window colour, never the sidebar material",
                   usage: "List { … }.panelListStyle()") {
                List(Self.targets, id: \.self) { Label($0, systemImage: "circle") }
                    .panelListStyle()
                    .frame(width: 280, height: 130)
                    .gallerySampleFrame()
            }
        }
    }

    /// The Workbench sessions panel: a plain list of tab rows, the selected
    /// one running into the content beside it.
    private var sessionsPanel: some View {
        List {
            ForEach(Self.sessions, id: \.self) { title in
                HStack(spacing: Spacing.regular) {
                    Image(systemName: "terminal").foregroundStyle(.secondary)
                    Text(title).lineLimit(1)
                    Spacer(minLength: 0)
                    if title == "Billing export" { CountBadge(text: "#42") }
                }
                .panelTab(isSelected: session == title)
                .onTapGesture { session = title }
            }
        }
        .clearPlainList()
    }

    /// The content: the selected session's targets on the detail backdrop.
    private var board: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            Text(session).font(.headline).padding([.horizontal, .top], Spacing.medium)
            List(Self.targets, id: \.self) { title in
                HStack {
                    Text(title)
                    Spacer()
                    Chip(text: title == Self.targets[1] ? "In progress" : "To do",
                         color: Tone.status(title == Self.targets[1] ? "blue" : "gray"), dot: true)
                }
                .kitRow(isSelected: target == title)
                .onTapGesture { target = title }
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 1, leading: Spacing.regular, bottom: 1, trailing: Spacing.regular))
            }
            .workspaceListStyle()
        }
    }

    private var detailPanel: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            HStack {
                Text(target ?? "").font(.headline)
                Spacer()
                Button("Close") { target = nil }.buttonStyle(.kitQuiet)
            }
            HStack(spacing: Spacing.regular) {
                MenuLabel(text: "In progress", systemImage: "circle.lefthalf.filled", color: Tone.status("blue"))
                MenuLabel(text: "Medium", systemImage: "flag.fill", color: Tone.priority("medium"))
            }
            SectionHeader(title: "Description", systemImage: "text.alignleft")
            Text("Run the acme billing export every night at 02:00 and keep the last seven files.")
                .font(.callout)
                .foregroundStyle(.secondary)
            SectionHeader(title: "Comments", systemImage: "text.bubble", count: 2)
        }
        .padding(Spacing.medium)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .panelBackground()
    }
}

// MARK: - Popover

struct PopoverPage: View {
    @State private var isOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.hero) {
            Sample("A real popover: click the button", usage: ".popover(isPresented: $isOpen) { body.popoverSurface() }") {
                Button("New target…") { isOpen = true }
                    .buttonStyle(.kitSecondary)
                    .popover(isPresented: $isOpen, arrowEdge: .bottom) {
                        NewTargetForm { isOpen = false }
                            .popoverSurface()
                    }
            }
            Sample("The same body drawn in place over the popover material, so it shows without a click") {
                NewTargetForm {}
                    .popoverSurface()
                    .background(PopoverMaterial())
                    .gallerySampleFrame()
            }
        }
    }
}

/// A popover's body: a title, a field, a few picks, and the one action,
/// enabled once the field has text.
private struct NewTargetForm: View {
    let onDone: () -> Void
    @State private var title = ""
    @State private var picked = "Billing export"

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            Text("New target").font(.headline)
            TextField("What needs doing in acme?", text: $title).textFieldStyle(.kit)
            VStack(alignment: .leading, spacing: Spacing.tight) {
                Text("Under").font(.caption).foregroundStyle(.secondary)
                ForEach(["Billing export", "Login redirect", "No parent"], id: \.self) { name in
                    Label(name, systemImage: name == "No parent" ? "tray" : "folder")
                        .kitRow(isSelected: picked == name)
                        .onTapGesture { picked = name }
                }
            }
            HStack(spacing: Spacing.regular) {
                Spacer()
                Button("Cancel", action: onDone).buttonStyle(.kitSecondary)
                Button("Create", action: onDone)
                    .buttonStyle(.kitPrimary)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(Spacing.large)
        .frame(width: 320)
    }
}
