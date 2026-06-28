import SwiftUI

/// Add/edit/enable/delete the observers attached to a target.
struct ObserverManagementSheet: View {
    @State var viewModel: ObserverTimelineViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var request = ""
    @State private var draftName = ""
    @State private var draftInstruction = ""
    @State private var hasDraft = false
    @State private var isGenerating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Observers").font(.title3).bold()

            List {
                ForEach(viewModel.observers) { observer in
                    ObserverEditRow(observer: observer, viewModel: viewModel)
                }
            }
            .frame(minHeight: 160)

            Divider()
            Text("Add observer").font(.headline)
            Text("Describe what to watch for — AI turns it into a focused instruction and names it.")
                .font(.caption).foregroundColor(.secondary)
            TextField("e.g. the HashBank refund decision and who owns it", text: $request, axis: .vertical)
                .lineLimit(2...4)
                .disabled(isGenerating)
            HStack {
                if let err = viewModel.errorMessage {
                    Text(err).font(.caption).foregroundColor(.red).lineLimit(2)
                }
                Spacer()
                Button {
                    Task { await generate() }
                } label: {
                    if isGenerating {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Generating…") }
                    } else {
                        Label("Generate with AI", systemImage: "sparkles")
                    }
                }
                .disabled(isGenerating || request.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if hasDraft {
                draftPreview
            }

            Divider()
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding()
        .frame(width: 460)
    }

    private var draftPreview: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Review").font(.subheadline).foregroundColor(.secondary)
            TextField("Name", text: $draftName)
            TextField("Instruction", text: $draftInstruction, axis: .vertical).lineLimit(2...5)
            HStack {
                Spacer()
                Button("Add observer") {
                    viewModel.createObserver(name: draftName, instruction: draftInstruction)
                    resetDraft()
                }
                .disabled(draftInstruction.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func generate() async {
        isGenerating = true
        viewModel.errorMessage = nil
        defer { isGenerating = false }
        if let draft = await viewModel.compose(input: request) {
            draftName = draft.name
            draftInstruction = draft.instruction
            hasDraft = true
        }
    }

    private func resetDraft() {
        request = ""
        draftName = ""
        draftInstruction = ""
        hasDraft = false
    }
}

private struct ObserverEditRow: View {
    let observer: Observer
    let viewModel: ObserverTimelineViewModel
    @State private var name: String
    @State private var instruction: String
    @State private var editing = false

    init(observer: Observer, viewModel: ObserverTimelineViewModel) {
        self.observer = observer
        self.viewModel = viewModel
        _name = State(initialValue: observer.name)
        _instruction = State(initialValue: observer.instruction)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Toggle("", isOn: Binding(get: { observer.enabled },
                                         set: { _ in viewModel.toggleObserver(observer) }))
                    .labelsHidden()
                if editing {
                    TextField("Name", text: $name)
                } else {
                    Text(observer.name).font(.body)
                }
                Spacer()
                Button(editing ? "Save" : "Edit") {
                    if editing { viewModel.updateObserver(observer, name: name, instruction: instruction) }
                    editing.toggle()
                }
                .controlSize(.small)
                Button(role: .destructive) { viewModel.deleteObserver(observer) } label: {
                    Image(systemName: "trash")
                }
                .controlSize(.small).buttonStyle(.borderless)
            }
            if editing {
                TextField("Instruction", text: $instruction, axis: .vertical).lineLimit(2...4)
            } else if !observer.instruction.isEmpty {
                Text(observer.instruction).font(.caption).foregroundColor(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}
