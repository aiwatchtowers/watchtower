import SwiftUI

/// The Recordings list (spec §13 C3): "In progress" (sending, waiting for
/// the Mac to wake, transcribing on Mac) and "Earlier" (ready recaps,
/// newest first). A ready row opens its recap; a failed upload offers
/// Retry; a recording held for a Mac this phone no longer links offers
/// Share and Delete, and audio a wipe could not read is one row opening
/// its files (board #171). The heartbeat goes stale with time alone, so
/// the list re-renders every 30 s.
struct RecordingsListView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var deleting: HeldRecording?
    @State private var showingUnreadable = false
    @State private var deleteError: String?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            content(RecordingsListModel(
                recordings: env.phoneRecordings.snapshot,
                replica: env.calendarReplica.snapshot,
                seen: env.recordingsSeen.value,
                now: context.date,
                calendar: .current,
                held: env.heldRecordings,
                linkedHubIDs: env.linkedHubIDs,
                unreadableCount: env.unreadableAudio.count
            ))
        }
        .navigationTitle("Recordings")
        .refreshable { await env.refresh(.pull) }
        .confirmationDialog(
            "Delete this recording?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible, presenting: deleting
        ) { recording in
            Button("Delete", role: .destructive) {
                Task {
                    do {
                        try await env.deleteHeld(recording)
                    } catch {
                        deleteError = error.localizedDescription
                    }
                }
            }
        } message: { _ in
            Text("Its audio is removed from this iPhone. It was not received by a Mac.")
        }
        .alert("Couldn't delete", isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deleteError ?? "")
        }
        .sheet(isPresented: $showingUnreadable) {
            UnreadableRecordingsView()
        }
    }

    private func content(_ model: RecordingsListModel) -> some View {
        List {
            if let empty = model.emptyText {
                Text(empty).foregroundStyle(.secondary)
            }
            if let unreadable = model.unreadableText {
                Button {
                    showingUnreadable = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(PhoneTone.red.color)
                            .frame(width: 40, height: 40)
                            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(unreadable).font(.body.weight(.medium)).foregroundStyle(.primary)
                            Text("Kept on this iPhone, never sent").font(.footnote).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary).accessibilityHidden(true)
                    }
                    .frame(minHeight: 44)
                }
                .accessibilityHint("Shows the files to share or delete")
            }
            if !model.inProgress.isEmpty {
                Section {
                    ForEach(model.inProgress) { row($0) }
                } header: {
                    Text("In progress").font(TypeScale.sectionHeader).textCase(nil)
                }
            }
            if !model.earlier.isEmpty {
                Section {
                    ForEach(model.earlier) { row($0) }
                } header: {
                    Text("Earlier").font(TypeScale.sectionHeader).textCase(nil)
                }
            }
        }
        // A list screen on systemBackground (design pass §2.7, §9.3).
        .listStyle(.plain)
    }

    @ViewBuilder
    private func row(_ entry: RecordingEntry) -> some View {
        if let transcriptID = entry.transcriptID {
            NavigationLink(value: CalendarRoute.recap(transcriptID)) {
                RecordingRow(entry: entry)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(entry.accessibilityLabel)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                RecordingRow(entry: entry)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(entry.accessibilityLabel)
                if entry.offersRetry, let id = entry.phoneRecordingID {
                    Button("Retry") {
                        // The list is the active hub's: its own recorder,
                        // even while another hub's capture is on screen.
                        Task { await env.activeSession.recorder.retry(id: id) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .accessibilityLabel("Retry sending \(entry.title)")
                }
                if let held = entry.heldForUnlinkedMac {
                    HStack(spacing: 12) {
                        if let audio = env.heldAudioURL(held) {
                            ShareLink(item: audio) {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }
                            .accessibilityLabel("Share \(entry.title)")
                        }
                        Button(role: .destructive) {
                            deleting = held
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .accessibilityLabel("Delete \(entry.title)")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
            }
        }
    }
}

/// Icon, title, subtitle and the coloured state line.
private struct RecordingRow: View {
    let entry: RecordingEntry

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(entry.tone.color)
                .frame(width: 40, height: 40)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.title).font(.body.weight(.medium)).lineLimit(1)
                    if entry.isNew {
                        Circle().fill(PhoneTone.accent.color).frame(width: 7, height: 7)
                    }
                }
                Text(entry.subtitle).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                Text(entry.statusText).font(.footnote).foregroundStyle(entry.tone.color).lineLimit(2)
            }
        }
        .frame(minHeight: 44)
    }

    private var icon: String {
        switch entry.state {
        case .recordingOnPhone: "record.circle"
        case .sending: "arrow.up.circle"
        case .waitingForMac: "clock"
        case .heldForMac: "pause.circle"
        case .sendFailed, .macFailed: "exclamationmark.triangle"
        case .onMac: "waveform"
        case .ready: "checkmark"
        }
    }
}

/// The audio a wipe could not read (`.held/unreadable`): kept on the phone,
/// never sent. Each file can be shared (Files, AirDrop) or deleted, all at
/// once too, each delete confirmed (board #171).
private struct UnreadableRecordingsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    /// The names a confirmed Delete removes: one file, or all of them.
    @State private var deleting: [String]?
    @State private var deleteError: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(env.unreadableAudio) { file in
                        row(file)
                    }
                } footer: {
                    Text("Their details couldn't be read while this iPhone was setting a Mac's data aside, so they are not sent to any Mac.")
                }
            }
            .listStyle(.plain)
            .overlay {
                if env.unreadableAudio.isEmpty {
                    Text("No unreadable recordings").foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Couldn't be read")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                if env.unreadableAudio.count > 1 {
                    ToolbarItem(placement: .destructiveAction) {
                        Button("Delete All", role: .destructive) {
                            deleting = env.unreadableAudio.map(\.name)
                        }
                    }
                }
            }
            .confirmationDialog(
                deleting?.count == 1 ? "Delete this recording?" : "Delete all \(deleting?.count ?? 0) recordings?",
                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                titleVisibility: .visible, presenting: deleting
            ) { names in
                Button("Delete", role: .destructive) {
                    Task {
                        do {
                            try await env.deleteUnreadable(names)
                        } catch {
                            deleteError = error.localizedDescription
                        }
                    }
                }
            } message: { _ in
                Text("The audio is removed from this iPhone.")
            }
            .alert("Couldn't delete", isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(deleteError ?? "")
            }
        }
    }

    private func row(_ file: UnreadableAudio) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name).font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                Text(details(file)).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            HStack(spacing: 12) {
                ShareLink(item: file.url) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .accessibilityLabel("Share \(file.name)")
                Button(role: .destructive) {
                    deleting = [file.name]
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .accessibilityLabel("Delete \(file.name)")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
        .padding(.vertical, 4)
    }

    /// "Today 10:00 · 2.4 MB".
    private func details(_ file: UnreadableAudio) -> String {
        let format = RecordingsFormat(calendar: .current, now: Date())
        var parts: [String] = []
        if let modified = file.modifiedAt { parts.append(format.when(modified)) }
        if let bytes = file.byteCount { parts.append(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)) }
        return parts.isEmpty ? "Audio" : parts.joined(separator: " · ")
    }
}
