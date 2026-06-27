import SwiftUI

/// Add/edit/enable/delete the observers attached to a target.
struct ObserverManagementSheet: View {
    @State var viewModel: ObserverTimelineViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var newName = ""
    @State private var newInstruction = ""

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
            TextField("Name", text: $newName)
            TextField("What should it watch for?", text: $newInstruction, axis: .vertical)
                .lineLimit(2...4)
            HStack {
                Spacer()
                Button("Add") {
                    let name = newName.isEmpty ? "Observer" : newName
                    viewModel.createObserver(name: name, instruction: newInstruction)
                    newName = ""; newInstruction = ""
                }
                .disabled(newInstruction.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            Divider()
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding()
        .frame(width: 460)
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
