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
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let empty = model.emptyText {
                    Text(empty).foregroundStyle(.secondary).padding(Spacing.small)
                }
                if let unreadable = model.unreadableText {
                    Button {
                        showingUnreadable = true
                    } label: {
                        FlatRow(icon: .symbol("exclamationmark.triangle", tone: .red), title: unreadable) {
                            Text("Kept on this iPhone, never sent")
                        } trailing: {
                            Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary).accessibilityHidden(true)
                        }
                    }
                    .buttonStyle(.plain)
                    .card(padding: EdgeInsets())
                    .padding(.top, Spacing.regular)
                    .accessibilityHint("Shows the files to share or delete")
                }
                group("In progress", model.inProgress)
                group("Earlier", model.earlier)
            }
            .padding(.horizontal, Spacing.large)
            .padding(.bottom, Spacing.large)
        }
    }

    /// A caps header over one card of rows with a hairline between each two.
    @ViewBuilder
    private func group(_ title: String, _ entries: [RecordingEntry]) -> some View {
        if !entries.isEmpty {
            SectionHeader(title, count: entries.count)
            VStack(spacing: 0) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 { CardRowDivider(inset: Spacing.medium) }
                    row(entry)
                }
            }
            .card(padding: EdgeInsets())
        }
    }

    @ViewBuilder
    private func row(_ entry: RecordingEntry) -> some View {
        if let transcriptID = entry.transcriptID {
            NavigationLink(value: CalendarRoute.recap(transcriptID)) {
                RecordingRow(entry: entry)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(entry.accessibilityLabel)
        } else {
            VStack(alignment: .leading, spacing: Spacing.regular) {
                RecordingRow(entry: entry)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(entry.accessibilityLabel)
                if entry.offersRetry, let id = entry.phoneRecordingID {
                    Button("Retry") {
                        // The list is the active hub's: its own recorder,
                        // even while another hub's capture is on screen.
                        Task { await env.activeSession.recorder.retry(id: id) }
                    }
                    .buttonStyle(SecondaryActionStyle())
                    .padding(.horizontal, Spacing.medium)
                    .accessibilityLabel("Retry sending \(entry.title)")
                }
                if let held = entry.heldForUnlinkedMac {
                    HStack(spacing: Spacing.medium) {
                        if let audio = env.heldAudioURL(held) {
                            ShareLink(item: audio) {
                                Label("Share", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(SecondaryActionStyle())
                            .accessibilityLabel("Share \(entry.title)")
                        }
                        Button(role: .destructive) {
                            deleting = held
                        } label: {
                            Label("Delete", systemImage: "trash").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(SecondaryActionStyle())
                        .accessibilityLabel("Delete \(entry.title)")
                    }
                    .padding(.horizontal, Spacing.medium)
                }
            }
            .padding(.bottom, Spacing.regular)
        }
    }
}

/// A flat row: icon, title, subtitle and the coloured state line.
private struct RecordingRow: View {
    let entry: RecordingEntry

    var body: some View {
        FlatRow(icon: .symbol(icon, tone: entry.tone), title: entry.title, titleLineLimit: 1, insets: RowInsets.flat) {
            VStack(alignment: .leading, spacing: Spacing.tight) {
                Text(entry.subtitle)
                Text(entry.statusText).foregroundStyle(entry.tone.color).lineLimit(2)
            }
        } trailing: {
            if entry.isNew {
                Circle()
                    .fill(PhoneTone.accent.color)
                    .frame(width: PhoneMetrics.macDot, height: PhoneMetrics.macDot)
                    .accessibilityHidden(true)
            }
        }
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
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(spacing: 0) {
                        ForEach(Array(env.unreadableAudio.enumerated()), id: \.element.id) { index, file in
                            if index > 0 { CardRowDivider(inset: Spacing.medium) }
                            row(file)
                        }
                    }
                    .card(padding: EdgeInsets())
                    Text("Their details couldn't be read while this iPhone was setting a Mac's data aside, so they are not sent to any Mac.")
                        .font(TypeScale.meta)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, Spacing.small)
                        .padding(.top, Spacing.compact)
                }
                .padding(.horizontal, Spacing.large)
                .padding(.top, Spacing.regular)
            }
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
        VStack(alignment: .leading, spacing: Spacing.regular) {
            VStack(alignment: .leading, spacing: Spacing.tight) {
                Text(file.name).font(TypeScale.rowTitle).lineLimit(1).truncationMode(.middle)
                Text(details(file)).font(TypeScale.meta).foregroundStyle(.secondary).lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            HStack(spacing: Spacing.medium) {
                ShareLink(item: file.url) {
                    Label("Share", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                }
                .accessibilityLabel("Share \(file.name)")
                Button(role: .destructive) {
                    deleting = [file.name]
                } label: {
                    Label("Delete", systemImage: "trash").frame(maxWidth: .infinity)
                }
                .accessibilityLabel("Delete \(file.name)")
            }
            .buttonStyle(SecondaryActionStyle())
        }
        .padding(.horizontal, Spacing.medium)
        .padding(.vertical, Spacing.cozy)
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
