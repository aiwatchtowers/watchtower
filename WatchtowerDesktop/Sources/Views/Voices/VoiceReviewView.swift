import SwiftUI
import WatchtowerCore

/// `VoiceRegistryCenter.VoiceSpotCheck`, spelled bare — the `VoiceCardView`
/// nested-type convention.
typealias VoiceSpotCheck = VoiceRegistryCenter.VoiceSpotCheck

/// The Voices window's Review screen (spec §3.2), on demand only — nothing
/// here runs unless the owner opens it (`VoiceRegistryCenter.loadReview`,
/// driven by `VoicesWindowView`'s segmented control / the tray "Review
/// voices" action). Three sections: the registry (per-person sample counts,
/// channel gaps, delete a person), imports (delete everything from one
/// sender), and spot checks of the latest auto labels (correct / wrong).
/// Export/Import (Task 15, design spec §5) are two sheets opened from here.
/// Pure reader + dispatcher over `VoiceRegistryCenter` — every write goes
/// back through it.
struct VoiceReviewView: View {
    @Environment(AppState.self) private var appState
    /// View-local, not AppState-owned — the same reasoning as
    /// `VoicesWindowView.clipPlayer`: a clip preview belongs to whichever
    /// screen is on display right now.
    @State private var clipPlayer = ClipPlayer()
    @State private var personPendingDelete: VoicePersonSummary?
    @State private var importPendingDelete: VoiceImport?
    @State private var showExportSheet = false
    @State private var showImportSheet = false

    private var center: VoiceRegistryCenter { appState.voiceRegistryCenter }

    var body: some View {
        List {
            Section {
                HStack {
                    Spacer()
                    Button("Import…") { showImportSheet = true }
                    Button("Export…") { showExportSheet = true }
                }
            }

            Section("Registry") {
                if center.people.isEmpty {
                    Text("No registry people yet").foregroundStyle(.secondary)
                } else {
                    ForEach(center.people) { person in
                        personRow(person)
                    }
                }
            }

            Section("Imports") {
                if center.imports.isEmpty {
                    Text("No imported voice prints").foregroundStyle(.secondary)
                } else {
                    ForEach(center.imports) { imported in
                        importRow(imported)
                    }
                }
            }

            Section("Spot checks") {
                if center.spotChecks.isEmpty {
                    Text("Nothing to spot-check right now").foregroundStyle(.secondary)
                } else {
                    ForEach(center.spotChecks) { check in
                        spotCheckRow(check)
                    }
                }
            }
        }
        .confirmationDialog(
            "Delete \(personPendingDelete?.displayName ?? "this person")?",
            isPresented: Binding(get: { personPendingDelete != nil }, set: { if !$0 { personPendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: personPendingDelete
        ) { person in
            Button("Delete", role: .destructive) {
                Task { await center.deletePerson(person.id) }
            }
        } message: { _ in
            Text("Their samples are removed. Auto-labeled clusters revert to \"Speaker N\" — names you typed by hand stay as text.")
        }
        .confirmationDialog(
            "Delete everything from \(importPendingDelete?.senderName ?? "this sender")?",
            isPresented: Binding(get: { importPendingDelete != nil }, set: { if !$0 { importPendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: importPendingDelete
        ) { imported in
            Button("Delete", role: .destructive) {
                guard let id = imported.id else { return }
                Task { await center.deleteImport(id) }
            }
        } message: { _ in
            Text("Their samples are removed. Auto-labeled clusters that depended only on them revert to \"Speaker N\".")
        }
        .sheet(isPresented: $showExportSheet) {
            VoiceExportSheet(people: center.people)
        }
        .sheet(isPresented: $showImportSheet) {
            VoiceImportSheet()
        }
    }

    // MARK: - Registry

    private func personRow(_ person: VoicePersonSummary) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(person.displayName).fontWeight(.semibold)
                Text(countsText(person))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    ForEach(person.channels.sorted { $0.rawValue < $1.rawValue }, id: \.self) { channel in
                        Text(channelLabel(channel))
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                    }
                }
                if let hint = channelGapHint(person) {
                    Text(hint).font(.caption).foregroundStyle(.secondary)
                }
                if let lastRecognized = person.lastRecognized {
                    Text("Last recognized \(TranscriptFormatting.formattedDate(lastRecognized))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Delete", role: .destructive) { personPendingDelete = person }
                .controlSize(.small)
        }
        .padding(.vertical, 4)
    }

    private func countsText(_ person: VoicePersonSummary) -> String {
        "\(person.counts[.owner] ?? 0) yours · \(person.counts[.auto] ?? 0) auto · \(person.counts[.imported] ?? 0) imported"
    }

    private func channelLabel(_ channel: VoiceChannel) -> String {
        switch channel {
        case .room: return "Meeting room"
        case .remote: return "Remote"
        case .unknown: return "Unknown"
        }
    }

    /// Spec §3.2: "only meeting-room samples" for a person heard through
    /// exactly one channel — informational only, never for an unknown-only
    /// person (nothing captured, not a meaningful gap to report).
    private func channelGapHint(_ person: VoicePersonSummary) -> String? {
        guard person.channels.count == 1, let only = person.channels.first, only != .unknown else { return nil }
        switch only {
        case .room: return "Only meeting-room samples"
        case .remote: return "Only remote samples"
        case .unknown: return nil
        }
    }

    // MARK: - Imports

    private func importRow(_ imported: VoiceImport) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(imported.senderName).fontWeight(.semibold)
                Text("\(TranscriptFormatting.formattedDate(imported.importedAt)) · \(imported.peopleCount) people · \(imported.sampleCount) samples")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Delete everything from \(imported.senderName)", role: .destructive) {
                importPendingDelete = imported
            }
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Spot checks

    private func spotCheckRow(_ check: VoiceSpotCheck) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(personName(for: check.personID)).fontWeight(.semibold)
                Text("·").foregroundStyle(.secondary)
                Text(check.meetingTitle).foregroundStyle(.secondary)
            }
            .font(.callout)

            ForEach(Array(check.clips.enumerated()), id: \.offset) { _, clip in
                let url = URL(fileURLWithPath: check.audioPath)
                VoiceClipRow(clip: clip, text: "", isFirst: false, isPlaying: clipPlayer.isPlaying(url: url, span: clip)) {
                    clipPlayer.toggle(url: url, span: clip)
                }
            }

            HStack(spacing: 8) {
                Button("Correct") { Task { await center.spotCheck(check, correct: true) } }
                Button("Wrong") { Task { await center.spotCheck(check, correct: false) } }
            }
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }

    private func personName(for personID: Int64) -> String {
        center.people.first { $0.id == personID }?.displayName ?? "Unknown"
    }
}
