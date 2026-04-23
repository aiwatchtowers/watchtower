import SwiftUI

struct CreateDayPlanItemSheet: View {
    @Bindable var vm: DayPlanViewModel
    @Binding var isPresented: Bool

    @State private var kind: DayPlanItemKind = .timeblock
    @State private var title: String = ""
    @State private var startTime: Date = defaultStartTime()
    @State private var endTime: Date = defaultEndTime()

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader
            Divider()
            formContent
            Divider()
            sheetFooter
        }
        .frame(width: 420, height: 320)
    }

    // MARK: - Header

    private var sheetHeader: some View {
        HStack {
            Text("Add manual item")
                .font(.headline)
            Spacer()
            Button("Cancel") { isPresented = false }
                .keyboardShortcut(.cancelAction)
        }
        .padding()
    }

    // MARK: - Form

    private var formContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Kind picker (segmented)
            VStack(alignment: .leading, spacing: 4) {
                Text("Kind")
                    .font(.subheadline)
                    .fontWeight(.medium)
                Picker("Kind", selection: $kind) {
                    Text("Timeblock").tag(DayPlanItemKind.timeblock)
                    Text("Backlog").tag(DayPlanItemKind.backlog)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            // Title field
            VStack(alignment: .leading, spacing: 4) {
                Text("Title")
                    .font(.subheadline)
                    .fontWeight(.medium)
                TextField("What needs to be done?", text: $title)
                    .textFieldStyle(.roundedBorder)
            }

            // Time pickers (only for timeblock)
            if kind == .timeblock {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Start")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        DatePicker("Start", selection: $startTime,
                                   displayedComponents: [.hourAndMinute])
                            .labelsHidden()
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("End")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        DatePicker("End", selection: $endTime,
                                   displayedComponents: [.hourAndMinute])
                            .labelsHidden()
                    }
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Footer

    private var sheetFooter: some View {
        HStack {
            Spacer()
            Button("Add") {
                let k = kind
                let t = title
                let start: Date? = k == .timeblock ? startTime : nil
                let end: Date? = k == .timeblock ? endTime : nil
                Task {
                    await vm.addManual(kind: k, title: t, startTime: start, endTime: end)
                    isPresented = false
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding()
    }

    // MARK: - Defaults

    private static func defaultStartTime() -> Date {
        let cal = Calendar.current
        let now = Date()
        var comps = cal.dateComponents([.year, .month, .day, .hour], from: now)
        comps.minute = 0
        comps.second = 0
        return cal.date(from: comps) ?? now
    }

    private static func defaultEndTime() -> Date {
        let start = defaultStartTime()
        return start.addingTimeInterval(60 * 60) // +1 hour
    }
}
