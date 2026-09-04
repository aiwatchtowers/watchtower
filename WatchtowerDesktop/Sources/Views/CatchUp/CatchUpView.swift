import SwiftUI
import WatchtowerCore

// MARK: - CatchUpView
//
// Catch-Up is an absence recap: pick a window on the left, build it, read the
// resulting document on the right. The left column keeps the window bar plus the
// history of recaps; the right pane renders whichever one is selected.
struct CatchUpView: View {
    @Bindable var vm: CatchUpViewModel

    /// Custom-range mode. View-local on purpose: it only decides WHICH control
    /// edits `vm.windowChoice`, and the choice itself — the state that has to
    /// survive navigation — lives on the ViewModel.
    @State private var rangeMode = false
    @State private var rangeFrom = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
    @State private var rangeTo = Date()

    var body: some View {
        HSplitView {
            leftColumn
                .frame(minWidth: 260, idealWidth: 300, maxWidth: 380)
            rightPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            vm.startObserving()
            // Restore the range controls from a choice that survived navigation.
            if case let .custom(from, to) = vm.windowChoice {
                rangeMode = true
                rangeFrom = from
                rangeTo = to
            }
        }
    }

    // MARK: - Left column

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            // A banner, not a full-screen state: a failed build must not hide the
            // older recaps, which stay perfectly readable.
            if let error = vm.error {
                errorBanner(error)
                Divider()
            }
            windowBar
            Divider()
            recapList
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .foregroundStyle(.secondary)
                .lineLimit(4)
            Spacer(minLength: 0)
            Button {
                vm.error = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Dismiss")
        }
        .font(.caption)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12))
    }

    private var windowBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if rangeMode {
                DatePicker("From", selection: $rangeFrom, displayedComponents: [.date, .hourAndMinute])
                DatePicker("To", selection: $rangeTo, displayedComponents: [.date, .hourAndMinute])
            } else {
                Picker("Window", selection: $vm.windowChoice) {
                    ForEach(CatchUpWindowChoice.presets, id: \.self) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            autoCaption

            HStack(spacing: 8) {
                Toggle("Range", isOn: $rangeMode)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                Spacer(minLength: 0)
                if vm.isBuilding {
                    ProgressView().controlSize(.small)
                }
                Button("Build recap") { vm.build() }
                    .buttonStyle(.borderedProminent)
                    .disabled(vm.isBuilding)
            }
        }
        .padding(10)
        .onChange(of: rangeMode) { _, on in
            vm.windowChoice = on ? .custom(from: rangeFrom, to: rangeTo) : .auto
        }
        .onChange(of: rangeFrom) { _, _ in applyRange() }
        .onChange(of: rangeTo) { _, _ in applyRange() }
    }

    /// Where an auto build would start. Nothing acknowledged yet means the CLI
    /// falls back to the last 24 hours, so the caption says so rather than
    /// leaving the window a mystery.
    @ViewBuilder
    private var autoCaption: some View {
        if vm.windowChoice == .auto {
            Text(vm.autoWindowStart.map { "since \(TimeFormatting.shortDateTime(from: $0))" }
                 ?? "since 24 hours ago")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func applyRange() {
        guard rangeMode else { return }
        vm.windowChoice = .custom(from: rangeFrom, to: rangeTo)
    }

    private var recapList: some View {
        // Plain ScrollView of buttons, not a List: the sidebar list style rides
        // an NSVisualEffectView that samples the desktop wallpaper behind the
        // window, so its selection fill reads as a wallpaper tint no opaque
        // SwiftUI background can cure (TargetsListView precedent).
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(vm.recaps) { recap in
                    Button {
                        vm.selected = recap
                    } label: {
                        CatchUpRecapRow(recap: recap)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                            .background(
                                vm.selected?.id == recap.id ? Color.accentColor.opacity(0.1) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 6)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Right pane

    @ViewBuilder
    private var rightPane: some View {
        if let recap = vm.selected {
            // Identity at the CONSTRUCTION site: `@State` storage is keyed here,
            // not inside the view's own body, so an `.id` applied in there would
            // reset the topic cards but leave the document's own correction
            // field holding text typed against a different recap.
            CatchUpRecapDocument(recap: recap, vm: vm)
                .id(recap.id)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "tray.and.arrow.down")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("No recaps yet")
                    .font(.title3)
                Text("Pick a window and build one.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
