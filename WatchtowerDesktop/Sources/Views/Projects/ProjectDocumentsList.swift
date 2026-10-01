import SwiftUI
import WatchtowerCore

/// The Documents pane's list (#81): a title/file-name search, collapsible
/// groups by kind (`ProjectDocumentGrouping`) with their markers, and
/// Add Document…. Selecting a row opens it in the pane.
struct ProjectDocumentsList: View {
    @Bindable var vm: ProjectsViewModel
    let onAdd: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search titles and file names", text: $vm.documentQuery)
                    .textFieldStyle(.plain)
                if !vm.documentQuery.isEmpty {
                    Button {
                        vm.documentQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .help("Clear the search")
                }
            }
            .padding(8)
            if !vm.documentQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                let shown = vm.documentSections.reduce(0) { $0 + $1.items.count }
                Text("Showing \(shown) of \(vm.documents.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding([.horizontal, .bottom], 8)
            }
            Divider()
            documentList
            Divider()
            HStack {
                Button {
                    onAdd()
                } label: {
                    Label("Add Document…", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .help("Attach a .md or .txt file from the project folder")
                Spacer()
            }
            .padding(8)
            if let notice = vm.attachNotice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding([.horizontal, .bottom], 8)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var documentList: some View {
        List(selection: Binding(
            get: { vm.documentViewModel?.document.id },
            set: { id in
                guard let item = vm.documents.first(where: { $0.id == id }) else { return }
                Task { await vm.openDocument(item.document) }
            }
        )) {
            let sections = vm.documentSections
            if sections.isEmpty, !vm.documents.isEmpty {
                Text("No title or file name matches.").foregroundStyle(.secondary)
            }
            ForEach(sections) { section in
                Section(isExpanded: expandedBinding(section.group)) {
                    ForEach(section.items) { documentRow($0) }
                } header: {
                    sectionHeader(section)
                }
            }
        }
        .panelListStyle()
    }

    private func expandedBinding(_ group: ProjectDocumentGrouping.Group) -> Binding<Bool> {
        Binding(
            get: { !vm.isDocumentGroupCollapsed(group) },
            set: { vm.setDocumentGroup(group, collapsed: !$0) }
        )
    }

    /// A button, not the list style's disclosure (a plain list draws none).
    /// A folded group still shows that it holds a changed document or open
    /// comments, so the badge always has a visible counterpart.
    private func sectionHeader(_ section: ProjectDocumentGrouping.Section) -> some View {
        let collapsed = vm.isDocumentGroupCollapsed(section.group)
        let comments = section.items.reduce(0) { $0 + $1.openComments }
        return Button {
            vm.setDocumentGroup(section.group, collapsed: !collapsed)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down").font(.caption2)
                Text("\(section.group.title) (\(section.items.count))")
                Spacer()
                if collapsed, section.items.contains(where: { vm.isRevised($0.document) }) {
                    Circle().fill(Color.blue).frame(width: 7, height: 7).help("Holds a document changed since you last viewed it")
                }
                if collapsed, comments > 0 {
                    Label("\(comments)", systemImage: "text.bubble").labelStyle(.titleAndIcon).foregroundStyle(.orange)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func documentRow(_ item: ProjectDocumentListItem) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.document.displayTitle)
                Text([item.document.relPath, item.targetTitle].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if vm.isRevised(item.document) {
                Circle().fill(Color.blue).frame(width: 7, height: 7).help("Changed since you last viewed it")
            }
            if item.openComments > 0 {
                Label("\(item.openComments)", systemImage: "text.bubble")
                    .labelStyle(.titleAndIcon)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .help(item.openComments == 1 ? "1 open comment" : "\(item.openComments) open comments")
            }
        }
        .tag(Optional(item.id))
    }
}
