import DesignKit
import SwiftUI

// The Components pages (spec §2.3): every kit component in each state that
// can be shown without the mouse, then in a realistic composition. Hover
// and press are live.

// MARK: - Actions

struct ActionsPage: View {
    @State private var splitOn = true

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.hero) {
            styles
            sizes
            inPlace
        }
    }

    private var styles: some View {
        PageSection("Styles") {
            Sample("kitPrimary: the one prominent action; disabled, it keeps a legible label",
                   usage: ".buttonStyle(.kitPrimary)") {
                HStack(spacing: Spacing.cozy) {
                    Button("Save") {}.buttonStyle(.kitPrimary)
                    Button("Save") {}.buttonStyle(.kitPrimary).disabled(true)
                }
            }
            Sample("kitSecondary: the action beside the main one", usage: ".buttonStyle(.kitSecondary)") {
                HStack(spacing: Spacing.cozy) {
                    Button("Cancel") {}.buttonStyle(.kitSecondary)
                    Button("Cancel") {}.buttonStyle(.kitSecondary).disabled(true)
                }
            }
            Sample("kitQuiet: a low-emphasis text action, a plate under the pointer only",
                   usage: ".buttonStyle(.kitQuiet)") {
                HStack(spacing: Spacing.cozy) {
                    Button("Show more") {}.buttonStyle(.kitQuiet)
                    Button("Show more") {}.buttonStyle(.kitQuiet).disabled(true)
                }
            }
            Sample("kitQuiet in the text colour: a name that opens something (a session title)",
                   usage: ".buttonStyle(KitQuietButtonStyle(label: .primary))") {
                Button("Fix the record capsule overlap") {}
                    .buttonStyle(KitQuietButtonStyle(label: .primary))
                    .font(.headline)
            }
            Sample("kitDestructive: stop or discard, white on red in every state",
                   usage: ".buttonStyle(.kitDestructive)") {
                HStack(spacing: Spacing.cozy) {
                    Button("Stop") {}.buttonStyle(.kitDestructive)
                    Button("Stop") {}.buttonStyle(.kitDestructive).disabled(true)
                }
            }
            Sample("kitIcon: off, on (click to toggle) and disabled", usage: ".buttonStyle(.kitIcon(isOn: isSplit))") {
                HStack(spacing: Spacing.cozy) {
                    Button {} label: { Image(systemName: "ellipsis") }.buttonStyle(.kitIcon(isOn: false))
                    Button { splitOn.toggle() } label: { Image(systemName: "rectangle.split.2x1") }
                        .buttonStyle(.kitIcon(isOn: splitOn))
                    Button {} label: { Image(systemName: "ellipsis") }.buttonStyle(.kitIcon(isOn: false)).disabled(true)
                }
            }
            Sample("FloatingButtonLabel in a plain button",
                   usage: "Button { … } label: { FloatingButtonLabel(title:systemImage:) }.buttonStyle(.plain)") {
                Button {} label: { FloatingButtonLabel(title: "Jump to latest", systemImage: "arrow.down") }
                    .buttonStyle(.plain)
                    .padding(Spacing.small)
            }
        }
    }

    private var sizes: some View {
        PageSection("Sizes") {
            Sample("Every control size beside the stock bordered button: one height per row",
                   usage: ".controlSize(.small)") {
                VStack(alignment: .leading, spacing: Spacing.regular) {
                    ForEach(GalleryControlSize.allCases) { size in
                        HStack(spacing: Spacing.cozy) {
                            Text(size.title).font(.caption).foregroundStyle(.secondary).frame(width: 56, alignment: .leading)
                            Button("Stock") {}.buttonStyle(.bordered)
                            Button("Save") {}.buttonStyle(.kitPrimary)
                            Button("Cancel") {}.buttonStyle(.kitSecondary)
                            Button("Show more") {}.buttonStyle(.kitQuiet)
                            Button("Stop") {}.buttonStyle(.kitDestructive)
                        }
                        .controlSize(size.controlSize)
                    }
                }
            }
        }
    }

    private var inPlace: some View {
        PageSection("In place") {
            Sample("A form's footer: secondary, then the one primary action, trailing") {
                HStack(spacing: Spacing.regular) {
                    Button("Show details") {}.buttonStyle(.kitQuiet)
                    Spacer()
                    Button("Cancel") {}.buttonStyle(.kitSecondary)
                    Button("Connect") {}.buttonStyle(.kitPrimary)
                }
                .padding(Spacing.medium)
                .frame(width: 440)
                .card()
            }
            Sample("The recorder's capsule: Stop stays readable in a crowded row") {
                HStack(spacing: Spacing.regular) {
                    Circle().fill(Tone.status("red")).frame(width: 8, height: 8)
                    Text("Recording · 12:04").font(.callout.monospacedDigit())
                    Button("Pause") {}.buttonStyle(.kitSecondary)
                    Button("Stop") {}.buttonStyle(.kitDestructive)
                }
                .controlSize(.small)
                .padding(.horizontal, Spacing.medium)
                .padding(.vertical, Spacing.regular)
                .background(Fill.card, in: Capsule())
            }
        }
    }
}

// MARK: - Selection

struct SelectionPage: View {
    @State private var views: [String: Bool] = [
        "Board": true, "Terminal": true, "Workchat": false, "Files": false, "Today": true, "Week": false
    ]
    @State private var hovered: String?
    @State private var chevronHovered = false
    @State private var range = "Week"
    @State private var mode = "List"
    @State private var notify = true
    @State private var digest = false
    @State private var splitOn = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.hero) {
            PageSection("Header capsule") {
                Sample("SegmentedToggleStyle, the Workbench header: independent view toggles; Terminal and Workchat "
                       + "are a joined twin (joinsRight / joinsLeft), and Workchat runs on into the sessions chevron (joinsChevron)",
                       usage: ".toggleStyle(SegmentedToggleStyle(joinsLeft: true, joinsChevron: true, isHovered: …) { … })") {
                    HStack(spacing: Spacing.regular) {
                        HStack(spacing: Spacing.tight) {
                            segment("Board", image: "rectangle.split.3x1")
                            HStack(spacing: 0) {
                                segment("Terminal", image: "terminal", joinsRight: true)
                                segment("Workchat", image: "bubble.left.and.bubble.right", joinsLeft: true, joinsChevron: true)
                                sessionsChevron
                            }
                            segment("Files", image: "folder")
                        }
                        .segmentCapsule()
                        Button { splitOn.toggle() } label: { Image(systemName: "rectangle.split.2x1") }
                            .buttonStyle(.kitIcon(isOn: splitOn))
                        Button {} label: { Image(systemName: "ellipsis") }.buttonStyle(.kitIcon(isOn: false))
                    }
                }
                Sample("Title-only segments (showsIcon: false): no icon, so no gap before the title",
                       usage: ".toggleStyle(SegmentedToggleStyle(showsIcon: false, isHovered: …) { … })") {
                    HStack(spacing: Spacing.tight) {
                        segment("Today", image: nil)
                        segment("Week", image: nil)
                    }
                    .segmentCapsule()
                }
                Sample("KitSegmentedPicker: exactly one of a few values",
                       usage: "KitSegmentedPicker(title: \"Range\", selection: $range, segments: [KitSegment(value: \"Day\", title: \"Day\"), …])") {
                    HStack(spacing: Spacing.large) {
                        KitSegmentedPicker(title: "Range", selection: $range, segments: [
                            KitSegment(value: "Day", title: "Day"),
                            KitSegment(value: "Week", title: "Week"),
                            KitSegment(value: "Month", title: "Month")
                        ])
                        KitSegmentedPicker(title: "Layout", selection: $mode, segments: [
                            KitSegment(value: "List", title: "List", systemImage: "list.bullet"),
                            KitSegment(value: "Board", title: "Board", systemImage: "rectangle.split.3x1"),
                            KitSegment(value: "Calendar", title: "Calendar", systemImage: "calendar")
                        ])
                    }
                }
                Sample("segmentCapsule(): the capsule alone, around your own controls", usage: "HStack { … }.segmentCapsule()") {
                    HStack(spacing: Spacing.small) {
                        Image(systemName: "arrow.triangle.branch").foregroundStyle(.secondary)
                        Text("main").font(.callout.weight(.medium))
                    }
                    .padding(.horizontal, Spacing.regular)
                    .segmentCapsule()
                }
            }
            PageSection("Switches") {
                Sample("A Toggle in a SettingRow becomes a small switch: on and off",
                       usage: "SettingRow(title:caption:) { Toggle(\"\", isOn: $on).labelsHidden() }") {
                    VStack(alignment: .leading, spacing: Spacing.regular) {
                        SettingRow(title: "Notify when a run finishes") {
                            Toggle("Notify when a run finishes", isOn: $notify).labelsHidden()
                        }
                        SettingRow(title: "Morning digest", caption: "A summary of the night's activity in acme") {
                            Toggle("Morning digest", isOn: $digest).labelsHidden()
                        }
                    }
                    .frame(width: 440)
                }
            }
        }
    }

    /// One view toggle of the capsule; `image: nil` is a title-only segment.
    private func segment(
        _ title: String, image: String?, joinsRight: Bool = false, joinsLeft: Bool = false, joinsChevron: Bool = false
    ) -> some View {
        Toggle(isOn: Binding(get: { views[title] == true }, set: { views[title] = $0 })) {
            if let image {
                Label(title, systemImage: image)
            } else {
                Label { Text(title) } icon: { EmptyView() }
            }
        }
        .toggleStyle(SegmentedToggleStyle(
            joinsRight: joinsRight, joinsLeft: joinsLeft, joinsChevron: joinsChevron, showsIcon: image != nil,
            isHovered: hovered == title || (joinsChevron && chevronHovered)
        ) { inside in
            if inside { hovered = title } else if hovered == title { hovered = nil }
        })
    }

    /// The twin's sessions menu, drawn as the Workbench header draws it: a
    /// hairline, then the chevron, on the fill of the segment it continues.
    private var sessionsChevron: some View {
        let isOn = views["Workchat"] == true
        let isLit = isOn || views["Terminal"] == true
        return Menu {
            ForEach(["acme setup", "Billing export", "Login redirect"], id: \.self) { Button($0) {} }
            Divider()
            Button("New Session") {}
        } label: {
            HStack(spacing: Spacing.small) {
                Rectangle().fill(Stroke.hairlineColor).frame(width: 1, height: 14)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isLit ? Color.accentColor : Color.secondary)
            }
            .padding(.trailing, Spacing.regular)
            .frame(height: 22)
            .background(
                SegmentedToggleStyle.fill(isOn: isOn, isHovered: hovered == "Workchat" || chevronHovered),
                in: UnevenRoundedRectangle(bottomTrailingRadius: 6, topTrailingRadius: 6, style: .continuous)
            )
            .contentShape(Rectangle())
            .onHover { chevronHovered = $0 }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Sessions")
    }
}

// MARK: - Inputs

struct InputsPage: View {
    private enum Field: Hashable { case focused }

    @State private var empty = ""
    @State private var filled = "billing@example.com"
    @State private var focusable = "acme"
    @State private var onPopover = ""
    @FocusState private var focus: Field?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.hero) {
            PageSection("States") {
                Sample("Empty, with its placeholder", usage: "TextField(\"Search acme\", text: $query).textFieldStyle(.kit)") {
                    TextField("Search acme", text: $empty).textFieldStyle(.kit).frame(width: 320)
                }
                Sample("Filled") {
                    TextField("Email", text: $filled).textFieldStyle(.kit).frame(width: 320)
                }
                Sample("Focused: the edge turns accent (press Focus, or click the field)") {
                    HStack(spacing: Spacing.regular) {
                        TextField("Workspace", text: $focusable)
                            .textFieldStyle(.kit)
                            .frame(width: 320)
                            .focused($focus, equals: .focused)
                        Button("Focus") { focus = .focused }.buttonStyle(.kitSecondary)
                        Button("Clear focus") { focus = nil }.buttonStyle(.kitQuiet)
                    }
                }
            }
            PageSection("On a popover") {
                Sample("Over the popover material the well turns translucent", usage: "content.popoverSurface()") {
                    VStack(alignment: .leading, spacing: Spacing.regular) {
                        Text("Rename session").font(.headline)
                        TextField("Name", text: $onPopover).textFieldStyle(.kit)
                    }
                    .padding(Spacing.medium)
                    .frame(width: 320)
                    .popoverSurface()
                    .background(PopoverMaterial())
                    .gallerySampleFrame()
                }
            }
        }
    }
}

// MARK: - Display

struct DisplayPage: View {
    private let priorities = ["high", "medium", "low"]
    private let statuses: [(String, String)] = [("To do", "gray"), ("In progress", "blue"), ("Blocked", "red"), ("Done", "green")]
    @State private var status = "In progress"

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.hero) {
            PageSection("Marks") {
                Sample("Chip: a priority (tinted text) and a status (dot)",
                       usage: "Chip(text: \"HIGH\", color: Tone.priority(\"high\"))  ·  Chip(text:color:dot: true)") {
                    HStack(spacing: Spacing.regular) {
                        ForEach(priorities, id: \.self) { Chip(text: $0.uppercased(), color: Tone.priority($0)) }
                        ForEach(statuses, id: \.0) { Chip(text: $0.0, color: Tone.status($0.1), dot: true) }
                    }
                }
                Sample("CountBadge: a session's #id, a count", usage: "CountBadge(text: \"#42\")") {
                    HStack(spacing: Spacing.regular) {
                        CountBadge(text: "#42")
                        CountBadge(text: "3")
                    }
                }
                Sample("OutlineTag: a quiet tag (a session's agent)", usage: "OutlineTag(text: \"Codex\")") {
                    OutlineTag(text: "Codex")
                }
                Sample("MenuLabel: a status menu (click it), and a read-only value without the chevron",
                       usage: "Menu { … } label: { MenuLabel(text:systemImage:color:) }.menuStyle(.borderlessButton).menuIndicator(.hidden)") {
                    HStack(spacing: Spacing.regular) {
                        Menu {
                            ForEach(statuses, id: \.0) { name, _ in
                                Toggle(name, isOn: Binding(get: { status == name }, set: { if $0 { status = name } }))
                            }
                        } label: {
                            MenuLabel(text: status, systemImage: "circle.lefthalf.filled", color: statusColor)
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        MenuLabel(text: "Done · from sub-tasks", systemImage: "checkmark.circle.fill",
                                  color: Tone.status("green"), isMenu: false)
                            .fixedSize()
                    }
                }
                Sample("SectionHeader: with a count, and without",
                       usage: "SectionHeader(title: \"Sub-tasks\", systemImage: \"checklist\", count: 3)") {
                    VStack(alignment: .leading, spacing: Spacing.medium) {
                        SectionHeader(title: "Sub-tasks", systemImage: "checklist", count: 3)
                        SectionHeader(title: "Description", systemImage: "text.alignleft")
                    }
                }
            }
            PageSection("In place") {
                Sample("The top of a target panel") {
                    VStack(alignment: .leading, spacing: Spacing.medium) {
                        HStack(spacing: Spacing.regular) {
                            CountBadge(text: "#42")
                            Text("Billing export for acme").font(.headline)
                            OutlineTag(text: "Codex")
                        }
                        HStack(spacing: Spacing.regular) {
                            MenuLabel(text: status, systemImage: "circle.lefthalf.filled", color: statusColor)
                            MenuLabel(text: "High", systemImage: "flag.fill", color: Tone.priority("high"))
                        }
                        SectionHeader(title: "Sub-tasks", systemImage: "checklist", count: 2)
                        VStack(alignment: .leading, spacing: Spacing.small) {
                            Label("CSV columns", systemImage: "checkmark.circle.fill").foregroundStyle(.secondary)
                            Label("Nightly schedule", systemImage: "circle")
                        }
                        .font(.callout)
                    }
                    .padding(Spacing.medium)
                    .frame(width: 380, alignment: .leading)
                    .panelBackground()
                    .gallerySampleFrame()
                }
            }
        }
    }

    private var statusColor: Color {
        Tone.status(statuses.first { $0.0 == status }?.1 ?? "gray")
    }
}

// MARK: - Containers

struct ContainersPage: View {
    private let cards = ["Billing export for acme", "Fix the login redirect", "Invoice PDF layout"]
    private let rows = ["acme setup", "Billing export", "Login redirect", "Weekly sync notes"]
    @State private var selectedCard = "Fix the login redirect"
    @State private var selectedRow = "Billing export"

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.hero) {
            PageSection("Card") {
                Sample("Resting, selected, and fill: nil (the caller keeps its own background)",
                       usage: ".card()  ·  .card(selected: true)  ·  .card(fill: nil)") {
                    HStack(spacing: Spacing.medium) {
                        Text("Resting").padding(Spacing.medium).frame(width: 150, alignment: .leading).card()
                        Text("Selected").padding(Spacing.medium).frame(width: 150, alignment: .leading).card(selected: true)
                        Text("Own fill")
                            .padding(Spacing.medium)
                            .frame(width: 150, alignment: .leading)
                            .background(Fill.selected, in: RoundedRectangle(cornerRadius: Radius.row))
                            .card(fill: nil)
                    }
                }
                Sample("A board column: click a card to select it") {
                    VStack(spacing: Spacing.compact) {
                        ForEach(cards, id: \.self) { title in
                            HStack {
                                Text(title)
                                Spacer()
                                Chip(text: title == cards[0] ? "HIGH" : "LOW",
                                     color: Tone.priority(title == cards[0] ? "high" : "low"))
                            }
                            .padding(Spacing.medium)
                            .card(selected: selectedCard == title)
                            .contentShape(Rectangle())
                            .onTapGesture { selectedCard = title }
                        }
                    }
                    .frame(width: 340)
                }
            }
            PageSection("Row") {
                Sample("kitRow: a selectable list row, hover under the pointer; click to select",
                       usage: "Label(title, systemImage: \"doc.text\").kitRow(isSelected: id == selection)") {
                    VStack(spacing: Spacing.tight) {
                        ForEach(rows, id: \.self) { title in
                            Label(title, systemImage: "doc.text")
                                .kitRow(isSelected: selectedRow == title)
                                .onTapGesture { selectedRow = title }
                        }
                    }
                    .frame(width: 300)
                }
            }
        }
    }
}
