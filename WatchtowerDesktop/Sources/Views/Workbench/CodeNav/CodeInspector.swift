import SwiftUI
import WatchtowerCore

/// The Files pane's inspector on the right (spec §2 decision 4): Usages
/// (§8.3) and the code questions (§9.4). The tab is per workbench and kept
/// by `CodeUsagesCenter`.
struct CodeInspector: View {
    let usages: CodeUsagesCenter
    let questions: CodeQuestionCenter?
    let project: Workbench

    var body: some View {
        let tab = usages.inspectorTab(workbenchID: project.id)
        VStack(spacing: 0) {
            Picker("Inspector", selection: Binding(
                get: { tab },
                set: { usages.selectInspectorTab($0, workbenchID: project.id) }
            )) {
                ForEach(CodeInspectorTab.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)
            Divider()
            switch tab {
            case .usages:
                UsagesView(usages: usages, project: project)
            case .questions:
                if let questions {
                    QuestionsView(questions: questions, project: project)
                } else {
                    ContentUnavailableView("No questions yet", systemImage: "bubble.left.and.text.bubble.right")
                }
            }
        }
    }
}

/// The button that shows and hides the inspector, at the end of the tab
/// strip.
struct CodeInspectorToggle: View {
    let usages: CodeUsagesCenter
    let project: Workbench

    var body: some View {
        let isShown = usages.isInspectorShown(workbenchID: project.id)
        Button {
            usages.setInspectorShown(!isShown, workbenchID: project.id)
        } label: {
            Image(systemName: "sidebar.trailing")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8)
        .help(isShown ? "Hide Usages and Questions" : "Show Usages and Questions")
        .accessibilityLabel(isShown ? "Hide Inspector" : "Show Inspector")
    }
}
