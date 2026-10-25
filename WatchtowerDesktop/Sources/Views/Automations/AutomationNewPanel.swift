import SwiftUI
import WatchtowerCore

/// The right panel's New automation (spec A2): "What is it for?" — Personal
/// or one workbench, chosen once and never changed (ask #469) — and "How do
/// you want to start?" — **Describe it in words** (the default) or one of the
/// templates of that scope (`AutomationNewChoice`). A set `flow.fixedScope`
/// (a workbench's **New Automation…**) skips the first choice. **Continue**
/// hands both picks to the tab.
struct AutomationNewPanel: View {
    let flow: AutomationNewFlow
    /// Personal and one choice per workbench, folder as its full path.
    let scopes: [AutomationScopeChoice]
    let templates: [AutomationTemplate]
    /// `automations templates --json` still running: a small progress row.
    var templatesLoading = false
    let onContinue: (AutomationScopeChoice, AutomationStart) -> Void

    @State private var pickedScope: AutomationScopeChoice?
    @State private var start: AutomationStart = .words

    private static let scopeCaption =
        "This decides what it can see and where its recipe lives. It can't be moved later."

    private var scope: AutomationScopeChoice {
        flow.fixedScope ?? pickedScope ?? scopes.first ?? .personal
    }

    private var starts: [AutomationStart] {
        AutomationNewChoice.starts(templates: templates, scope: scope)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.wide) {
                if flow.fixedScope == nil { scopeBlock }
                startBlock
                HStack {
                    Spacer()
                    Button("Continue") { onContinue(scope, starts.contains(start) ? start : .words) }
                        .buttonStyle(.kitPrimary)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .controlSize(.small)
            .frame(maxWidth: 760, alignment: .leading)
            .padding(Spacing.page)
            .frame(maxWidth: .infinity)
        }
        .onChange(of: scope) { _, _ in
            if !starts.contains(start) { start = .words }
        }
    }

    private var scopeBlock: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            VStack(alignment: .leading, spacing: Spacing.small) {
                Text("What is it for?").font(.headline)
                Text(Self.scopeCaption).font(.caption).foregroundStyle(.secondary)
            }
            grid {
                ForEach(scopes, id: \.self) { choice in
                    tile(title: Self.title(choice), systemImage: Self.icon(choice), line: Self.line(choice),
                         isSelected: choice == scope) { pickedScope = choice }
                }
            }
        }
    }

    private var startBlock: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            Text("How do you want to start?").font(.headline)
            grid {
                ForEach(starts, id: \.self) { item in
                    startTile(item)
                }
            }
            if templatesLoading {
                HStack(spacing: Spacing.regular) {
                    ProgressView().controlSize(.small)
                    Text("Loading templates…").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private func startTile(_ item: AutomationStart) -> some View {
        switch item {
        case .words:
            tile(title: "Describe it in words", systemImage: "sparkles",
                 line: "Opens the chat; the assistant drafts the recipe as you talk.",
                 isSelected: start == item) { start = item }
        case .watch:
            tile(title: "Watch for something", systemImage: "eye",
                 line: "Opens the chat; tell it what to watch for, and each new event lands on the track's card "
                     + "in your Inbox.",
                 isSelected: start == item) { start = item }
        case let .template(name):
            if let template = templates.first(where: { $0.name == name }) {
                tile(title: template.title, systemImage: "doc.text",
                     line: AutomationTemplateGallery.summaryLine(template),
                     isSelected: start == item) { start = item }
            }
        }
    }

    private func grid<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: Spacing.medium, alignment: .top)],
                  alignment: .leading, spacing: Spacing.medium, content: content)
    }

    private func tile(
        title: String,
        systemImage: String,
        line: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Spacing.small) {
                Label(title, systemImage: systemImage)
                    .font(.callout.weight(.semibold))
                if !line.isEmpty {
                    Text(line)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(Spacing.medium)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .card(selected: isSelected)
            .contentShape(RoundedRectangle(cornerRadius: Radius.row))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private static func title(_ choice: AutomationScopeChoice) -> String {
        switch choice {
        case .personal: "Personal"
        case let .workbench(_, name, _): name
        }
    }

    private static func icon(_ choice: AutomationScopeChoice) -> String {
        switch choice {
        case .personal: "person"
        case .workbench: "square.grid.2x2"
        }
    }

    private static func line(_ choice: AutomationScopeChoice) -> String {
        switch choice {
        case .personal:
            "Your mail, Slack, calendar and trackers. Results go to your Inbox and briefing."
        case let .workbench(_, _, folder):
            "Its board, agent sessions and shell in \((folder as NSString).abbreviatingWithTildeInPath)."
        }
    }
}
