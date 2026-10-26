import DesignKit
import SwiftUI

// The Foundations pages (spec §2.3): the kit's tokens, each drawn at its
// true size and set in the place the app uses it.

// MARK: - Colour & surfaces

struct ColoursPage: View {
    private let surfaces: [(String, Color, String)] = [
        ("detail", Surface.detail, "the backdrop of every tab's content"),
        ("window", Surface.window, "side panels and the sidebar"),
        ("text", Surface.text, "text wells: fields, editors"),
        ("control", Surface.control, "stock control backgrounds")
    ]
    private let fills: [(String, Color, Double)] = [
        ("rest", Fill.rest, Fill.restOpacity), ("card", Fill.card, Fill.cardOpacity),
        ("hover", Fill.hover, Fill.hoverOpacity), ("selected", Fill.selected, Fill.selectedOpacity),
        ("on", Fill.on, Fill.onOpacity)
    ]
    private let statuses = ["blue", "teal", "red", "green", "gray", "purple", "unknown"]
    private let priorities = ["high", "medium", "low"]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.hero) {
            PageSection("Surfaces") {
                Sample("A side panel beside a tab's content, as in AI Chat and the Workbench",
                       usage: "panel.panelBackground()  ·  content.detailBackground()") {
                    HStack(spacing: 0) {
                        VStack(alignment: .leading, spacing: Spacing.compact) {
                            Text("History").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                            ForEach(["acme onboarding", "Billing export", "Weekly sync notes"], id: \.self) {
                                Label($0, systemImage: "bubble.left").font(.callout)
                            }
                        }
                        .padding(Spacing.medium)
                        .frame(width: 200, alignment: .topLeading)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .panelBackground()
                        Divider()
                        VStack(alignment: .leading, spacing: Spacing.regular) {
                            Text("Billing export").font(.headline)
                            Text("The export gained two columns and now runs nightly for acme.")
                                .foregroundStyle(.secondary)
                            Text("invoice_id, paid_at").font(.callout).padding(Spacing.medium).card()
                        }
                        .padding(Spacing.medium)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .detailBackground()
                    }
                    .frame(height: 150)
                    .gallerySampleFrame()
                }
                Sample("The four roles", usage: "Surface.detail  ·  Surface.window  ·  Surface.text  ·  Surface.control") {
                    HStack(spacing: Spacing.medium) {
                        ForEach(surfaces, id: \.0) { name, color, role in
                            swatch(color, name: name, note: role, width: 150)
                        }
                    }
                }
            }
            PageSection("Fills") {
                Sample("Neutral fills (primary) and accent fills, on the page's surface",
                       usage: "Fill.card  ·  Fill.selected") {
                    HStack(spacing: Spacing.medium) {
                        ForEach(fills, id: \.0) { name, color, opacity in
                            swatch(color, name: name, note: String(format: "%.2f", opacity), width: 96)
                        }
                    }
                }
            }
            PageSection("Tones") {
                Sample("Status, by the name a target's status carries", usage: "Tone.status(\"blue\")") {
                    HStack(spacing: Spacing.compact) {
                        ForEach(statuses, id: \.self) { tint($0, Tone.status($0)) }
                    }
                }
                Sample("Priority", usage: "Tone.priority(\"high\")") {
                    HStack(spacing: Spacing.compact) {
                        ForEach(priorities, id: \.self) { tint($0, Tone.priority($0)) }
                    }
                }
                Sample("Shared states: a warning, an all-clear, an error, the current moment, readable yellow",
                       usage: "Tone.warning  ·  Tone.success  ·  Tone.error  ·  Tone.now  ·  Tone.amber") {
                    HStack(spacing: Spacing.compact) {
                        tint("warning", Tone.warning)
                        tint("success", Tone.success)
                        tint("error", Tone.error)
                        tint("now", Tone.now)
                        tint("amber", Tone.amber)
                    }
                }
                Sample("A tinted capsule: the tone under a thin outline of itself",
                       usage: "tone.opacity(ChipTint.fillOpacity)  ·  ChipTint.strokeOpacity  ·  ChipTint.strokeWidth") {
                    tint("In review", Tone.status("purple"))
                }
            }
        }
    }

    private func swatch(_ color: Color, name: String, note: String, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                .fill(color)
                .overlay(RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                    .strokeBorder(Stroke.hairlineColor, lineWidth: Stroke.hairline))
                .frame(width: width, height: 52)
            Text(name).font(.caption.weight(.medium))
            Text(note).font(.caption2).foregroundStyle(.secondary).frame(width: width, alignment: .leading)
        }
    }

    private func tint(_ name: String, _ color: Color) -> some View {
        Text(name)
            .font(.caption)
            .padding(.horizontal, Spacing.regular)
            .padding(.vertical, Spacing.small)
            .background(color.opacity(ChipTint.fillOpacity), in: Capsule())
            .overlay(Capsule().strokeBorder(color.opacity(ChipTint.strokeOpacity), lineWidth: ChipTint.strokeWidth))
    }
}

// MARK: - Spacing

/// A named step of a scale, for the token pages.
struct Step: Hashable {
    let name: String
    let value: CGFloat
}

struct SpacingPage: View {
    static let steps = [
        Step(name: "tight", value: Spacing.tight), Step(name: "small", value: Spacing.small),
        Step(name: "compact", value: Spacing.compact), Step(name: "regular", value: Spacing.regular),
        Step(name: "cozy", value: Spacing.cozy), Step(name: "medium", value: Spacing.medium),
        Step(name: "large", value: Spacing.large), Step(name: "page", value: Spacing.page),
        Step(name: "wide", value: Spacing.wide), Step(name: "hero", value: Spacing.hero)
    ]

    static let paneWidths = [
        Step(name: "sideListMin", value: PaneWidth.sideListMin), Step(name: "sideListIdeal", value: PaneWidth.sideListIdeal),
        Step(name: "sideListMax", value: PaneWidth.sideListMax), Step(name: "detailMin", value: PaneWidth.detailMin),
        Step(name: "narrowPage", value: PaneWidth.narrowPage)
    ]

    static let listLayout = [
        Step(name: "rowMinHeight", value: ListLayout.rowMinHeight),
        Step(name: "lineMinHeight", value: ListLayout.lineMinHeight),
        Step(name: "markColumn", value: ListLayout.markColumn),
        Step(name: "numberColumn", value: ListLayout.numberColumn),
        Step(name: "dateColumn", value: ListLayout.dateColumn),
        Step(name: "textColumn", value: ListLayout.textColumn),
        Step(name: "progressBar", value: ListLayout.progressBar)
    ]

    @State private var chosen = Step(name: "regular", value: Spacing.regular)

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.hero) {
            PageSection("Scale") {
                Sample("Each bar is the step's true width", usage: ".padding(Spacing.medium)") {
                    VStack(alignment: .leading, spacing: Spacing.compact) {
                        ForEach(Self.steps, id: \.self) { step in
                            HStack(spacing: Spacing.regular) {
                                Text(step.name).font(.caption).frame(width: 64, alignment: .leading)
                                Text("\(Int(step.value))")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 24, alignment: .trailing)
                                Rectangle().fill(Color.accentColor).frame(width: step.value, height: Spacing.regular)
                            }
                        }
                    }
                }
            }
            PageSection("Live") {
                Sample("Pick a step: the cards below are spaced and padded by it",
                       usage: "VStack(spacing: Spacing.\(chosen.name)) { … }.padding(Spacing.\(chosen.name))") {
                    VStack(alignment: .leading, spacing: Spacing.medium) {
                        Picker("Step", selection: $chosen.animation(Motion.toggle)) {
                            ForEach(Self.steps, id: \.self) { Text("\($0.name) \(Int($0.value))").tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        VStack(alignment: .leading, spacing: chosen.value) {
                            ForEach(["Fix the login redirect", "Invoice PDF layout", "CSV columns"], id: \.self) {
                                Text($0).padding(chosen.value).frame(width: 280, alignment: .leading).card()
                            }
                        }
                    }
                }
            }
            PageSection("Pane widths") {
                Sample("A side list beside its detail, and a narrow centred page; each bar is the true width",
                       usage: ".frame(minWidth: PaneWidth.sideListMin, idealWidth: PaneWidth.sideListIdeal, maxWidth: PaneWidth.sideListMax)") {
                    VStack(alignment: .leading, spacing: Spacing.compact) {
                        ForEach(Self.paneWidths, id: \.name) { item in
                            HStack(spacing: Spacing.regular) {
                                Text(item.name).font(.caption).frame(width: 110, alignment: .leading)
                                Text("\(Int(item.value))")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 30, alignment: .trailing)
                                Rectangle().fill(Color.accentColor).frame(width: item.value, height: Spacing.regular)
                            }
                        }
                    }
                }
            }
            PageSection("List layout") {
                Sample("A column list's row and line heights, column widths and progress bar; each bar is the true size",
                       usage: ".frame(width: ListLayout.textColumn, alignment: .leading)") {
                    VStack(alignment: .leading, spacing: Spacing.compact) {
                        ForEach(Self.listLayout, id: \.name) { item in
                            HStack(spacing: Spacing.regular) {
                                Text(item.name).font(.caption).frame(width: 110, alignment: .leading)
                                Text("\(Int(item.value))")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 30, alignment: .trailing)
                                Rectangle().fill(Color.accentColor).frame(width: item.value, height: Spacing.regular)
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Radius

struct RadiusPage: View {
    private let radii: [(Step, String)] = [
        (Step(name: "mark", value: Radius.mark), "small marks"),
        (Step(name: "control", value: Radius.control), "buttons, fields"),
        (Step(name: "row", value: Radius.row), "rows, cards"),
        (Step(name: "container", value: Radius.container), "settings cards, panes"),
        (Step(name: "bubble", value: Radius.bubble), "chat bubbles"),
        (Step(name: "pill", value: Radius.pill), "pills")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.hero) {
            PageSection("Roles") {
                Sample("Each radius on a card-filled shape", usage: "RoundedRectangle(cornerRadius: Radius.row, style: .continuous)") {
                    HStack(alignment: .top, spacing: Spacing.large) {
                        ForEach(radii, id: \.0) { step, role in
                            VStack(spacing: Spacing.small) {
                                RoundedRectangle(cornerRadius: step.value, style: .continuous)
                                    .fill(Fill.card)
                                    .overlay(RoundedRectangle(cornerRadius: step.value, style: .continuous)
                                        .strokeBorder(Stroke.hairlineColor, lineWidth: Stroke.hairline))
                                    .frame(width: 72, height: 56)
                                Text("\(step.name) \(Int(step.value))").font(.caption.weight(.medium))
                                Text(role).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            PageSection("In place") {
                Sample("A field (control), a card (row), a bubble and a capsule chip side by side",
                       usage: "Chip(text:color:) draws a Capsule, not a radius") {
                    HStack(alignment: .center, spacing: Spacing.medium) {
                        TextField("Search acme", text: .constant("")).textFieldStyle(.kit).frame(width: 160)
                        Text("Billing export").padding(Spacing.medium).card()
                        Text("Runs nightly now")
                            .padding(.horizontal, Spacing.medium)
                            .padding(.vertical, Spacing.regular)
                            .background(Fill.selected, in: RoundedRectangle(cornerRadius: Radius.bubble, style: .continuous))
                        Chip(text: "HIGH", color: Tone.priority("high"))
                    }
                }
            }
        }
    }
}

// MARK: - Strokes

struct StrokesPage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.hero) {
            PageSection("Widths") {
                Sample("hairline: the separator colour at 0.5 pt  ·  selection: the accent at 1.5 pt",
                       usage: "Stroke.hairline  ·  Stroke.hairlineColor  ·  Stroke.selection") {
                    HStack(spacing: Spacing.medium) {
                        Text("Resting card").padding(Spacing.medium).frame(width: 180, alignment: .leading).card()
                        Text("Selected card")
                            .padding(Spacing.medium)
                            .frame(width: 180, alignment: .leading)
                            .card(selected: true)
                    }
                }
            }
            PageSection("Between panes") {
                Sample("A hairline separates panes, never rows", usage: ".overlay(alignment: .leading) { Divider() }") {
                    HStack(spacing: 0) {
                        Text("Board").frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .padding(Spacing.medium)
                        Rectangle().fill(Stroke.hairlineColor).frame(width: Stroke.hairline)
                        Text("Target").frame(width: 200, alignment: .topLeading)
                            .frame(maxHeight: .infinity, alignment: .top)
                            .padding(Spacing.medium)
                    }
                    .frame(height: 90)
                    .gallerySampleFrame()
                }
            }
        }
    }
}

// MARK: - Typography

struct TypographyPage: View {
    @Environment(\.galleryFrozenDate) private var frozenDate
    private let roles: [(String, Font, String)] = [
        ("Headline: a card's or a panel's title", .headline, ".font(.headline)"),
        ("Body: running text", .body, ".font(.body)"),
        ("Callout: a summary under a title", .callout, ".font(.callout)"),
        ("Section header", .subheadline.weight(.semibold), ".font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)"),
        ("Meta: secondary text, times, counts", .caption, ".font(.caption).foregroundStyle(.secondary)"),
        ("Badge: chips and count badges", .caption2.weight(.semibold), ".font(.caption2.weight(.semibold))")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.hero) {
            PageSection("Roles") {
                ForEach(roles, id: \.0) { name, font, usage in
                    Sample(name, usage: usage) {
                        Text("Billing export for acme runs nightly").font(font)
                    }
                }
                Sample("Caps label: Home's zone titles",
                       usage: ".textCase(.uppercase).tracking(Tracking.caps).font(.caption.weight(.bold))") {
                    Text("Waiting on you")
                        .textCase(.uppercase)
                        .tracking(Tracking.caps)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
            }
            PageSection("Numbers") {
                Sample("Changing numbers keep their width: monospaced digits (left) against proportional (right)",
                       usage: ".font(.caption.monospacedDigit())") {
                    if let frozenDate {
                        counter(at: frozenDate)
                    } else {
                        TimelineView(.periodic(from: .now, by: 0.1)) { counter(at: $0.date) }
                    }
                }
            }
            PageSection("Emphasis") {
                Sample("Semantic colours only", usage: ".foregroundStyle(.secondary)") {
                    HStack(spacing: Spacing.large) {
                        Text("primary").foregroundStyle(.primary)
                        Text("secondary").foregroundStyle(.secondary)
                        Text("tertiary").foregroundStyle(.tertiary)
                        Text("accent").foregroundStyle(Color.accentColor)
                    }
                }
                Sample("Together on a card") {
                    VStack(alignment: .leading, spacing: Spacing.small) {
                        HStack {
                            Text("Fix the login redirect").font(.headline)
                            Spacer()
                            Chip(text: "LOW", color: Tone.priority("low"))
                        }
                        Text("Sign-in returns to the home page instead of the last tab.").foregroundStyle(.secondary)
                        Text("Updated 2 h ago · 3 comments").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .padding(Spacing.medium)
                    .frame(width: 360)
                    .card()
                }
            }
        }
    }

    /// A count that changes ten times a second, in both digit styles.
    private func counter(at date: Date) -> some View {
        let value = Int(date.timeIntervalSinceReferenceDate * 10) % 100_000
        return HStack(spacing: Spacing.wide) {
            Text("\(value) tokens").font(.body.monospacedDigit())
            Text("\(value) tokens").font(.body)
        }
    }
}

// MARK: - Icons

struct IconsPage: View {
    private let sizes: [(Step, String, String)] = [
        (Step(name: "chevron", value: IconSize.chevron), "chevron.down", "a menu label's chevron"),
        (Step(name: "header", value: IconSize.header), "rectangle.split.2x1", "header and toolbar glyphs"),
        (Step(name: "composer", value: IconSize.composer), "paperclip", "the composer's buttons"),
        (Step(name: "composerLarge", value: IconSize.composerLarge), "arrow.up.circle.fill", "the composer's send")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.hero) {
            PageSection("Sizes") {
                Sample("Each glyph at its size, in a box of that size", usage: ".font(.system(size: IconSize.header))") {
                    HStack(alignment: .bottom, spacing: Spacing.wide) {
                        ForEach(sizes, id: \.0) { step, symbol, role in
                            VStack(spacing: Spacing.small) {
                                Image(systemName: symbol)
                                    .font(.system(size: step.value))
                                    .frame(width: step.value, height: step.value)
                                    .padding(Spacing.regular)
                                    .card()
                                Text("\(step.name) \(Int(step.value))").font(.caption.weight(.medium))
                                Text(role).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            PageSection("In place") {
                Sample("A composer row: attach, the field, send") {
                    HStack(spacing: Spacing.regular) {
                        Image(systemName: "paperclip").font(.system(size: IconSize.composer)).foregroundStyle(.secondary)
                        TextField("Ask about acme", text: .constant("")).textFieldStyle(.kit)
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: IconSize.composerLarge))
                            .foregroundStyle(Color.accentColor)
                    }
                    .frame(width: 420)
                }
            }
        }
    }
}

// MARK: - Motion & shadow

struct MotionPage: View {
    @State private var toggled = false
    @State private var panelShown = true

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.hero) {
            PageSection("Motion") {
                Sample("toggle: hover, on and off states", usage: ".animation(Motion.toggle, value: isOn)") {
                    HStack(spacing: Spacing.medium) {
                        Button("Play") { toggled.toggle() }.buttonStyle(.kitSecondary)
                        Toggle(isOn: $toggled) { Label("Board", systemImage: "rectangle.split.3x1") }
                            .toggleStyle(SegmentedToggleStyle(isHovered: false) { _ in })
                            .segmentCapsule()
                        RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                            .fill(toggled ? Fill.on : Fill.card)
                            .frame(width: toggled ? 120 : 60, height: 26)
                            .animation(Motion.toggle, value: toggled)
                    }
                }
                Sample("panel: a side panel sliding in and out", usage: ".animation(Motion.panel, value: isPanelShown)") {
                    VStack(alignment: .leading, spacing: Spacing.regular) {
                        Button(panelShown ? "Hide panel" : "Show panel") { panelShown.toggle() }.buttonStyle(.kitSecondary)
                        HStack(spacing: 0) {
                            Text("Board").padding(Spacing.medium)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            if panelShown {
                                Text("Target").padding(Spacing.medium)
                                    .frame(width: 180, alignment: .topLeading)
                                    .frame(maxHeight: .infinity, alignment: .top)
                                    .panelBackground()
                                    .overlay(alignment: .leading) { Divider() }
                                    .transition(.move(edge: .trailing).combined(with: .opacity))
                            }
                        }
                        .clipped()
                        .animation(Motion.panel, value: panelShown)
                        .frame(height: 90)
                        .gallerySampleFrame()
                    }
                }
            }
            PageSection("Shadow") {
                Sample("Only floating buttons cast a shadow",
                       usage: ".shadow(color: FloatingShadow.color, radius: FloatingShadow.radius, y: FloatingShadow.y)") {
                    FloatingButtonLabel(title: "Jump to latest", systemImage: "arrow.down")
                        .padding(Spacing.regular)
                }
            }
        }
    }
}

extension View {
    /// A composed sample's frame: clipped to a container-radius shape under
    /// a hairline, so it reads as a window cut-out on the page.
    func gallerySampleFrame() -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.container, style: .continuous)
        return clipShape(shape).overlay(shape.strokeBorder(Stroke.hairlineColor, lineWidth: Stroke.hairline))
    }
}
