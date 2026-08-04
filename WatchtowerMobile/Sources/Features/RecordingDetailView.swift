import SwiftUI
import WatchtowerKit

/// The read-only recording screen: recap, chapter outline, notes, speaker
/// roster, and the transcript preview. Reads the LIVE record from the shared
/// view model (the `SituationReviewView` shape), so a desktop-side notes or
/// recap update refreshes an open screen.
struct RecordingDetailView: View {
    let recordingID: Int
    let model: RecordingsViewModel
    /// Decoded once per transcript version — never per body evaluation.
    @State private var detail: RecordingDetail?

    var body: some View {
        if let transcript = model.transcript(id: recordingID) {
            content(RecordingRow(transcript), detail)
                .task(id: transcript.updatedAt) { detail = RecordingDetail(transcript) }
        } else {
            ContentUnavailableView(
                "Recording unavailable",
                systemImage: "waveform.slash",
                description: Text("It was deleted on the Mac, or aged out of the synced window.")
            )
        }
    }

    /// The header renders from the row projection (no decode), so the screen
    /// is never blank while the decoded sections are being built.
    private func content(_ row: RecordingRow, _ detail: RecordingDetail?) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.title).font(.headline)
                    if let eventTitle = row.eventTitle {
                        Label(eventTitle, systemImage: "calendar")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(row.metaLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if row.isAdHoc {
                        Text("Ad-hoc recording — not linked to a calendar event.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            if let detail {
                if detail.hasNoGeneratedContent {
                    Section {
                        Label(
                            "No recap or notes were generated for this recording.",
                            systemImage: "sparkles"
                        )
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }
                }
                recapSections(detail.recap)
                chapterSection(detail.chapters)
                notesSection(detail.notes)
                speakerSection(detail.speakers)
                transcriptSection(detail.snippet)
            }
        }
        .navigationTitle("Recording")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func recapSections(_ recap: RecordingDetail.Recap) -> some View {
        switch recap {
        case .absent:
            EmptyView()
        case .unreadable:
            Section {
                Label(
                    "This recording's recap could not be read on the phone. Open it on your Mac.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
        case .present(let content):
            if !content.summary.isEmpty {
                Section("Recap") {
                    Text(content.summary).font(.subheadline)
                }
            }
            bulletSection("Key decisions", content.keyDecisions, icon: "checkmark.seal")
            bulletSection("Action items", content.actionItems, icon: "arrow.right.circle")
            bulletSection("Open questions", content.openQuestions, icon: "questionmark.circle")
        }
    }

    @ViewBuilder
    private func bulletSection(_ title: String, _ lines: [String], icon: String) -> some View {
        if !lines.isEmpty {
            Section(title) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Label(line, systemImage: icon)
                        .font(.subheadline)
                }
            }
        }
    }

    @ViewBuilder
    private func chapterSection(_ chapters: [RecordingChapter]) -> some View {
        if !chapters.isEmpty {
            Section("Chapters") {
                ForEach(chapters) { chapter in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(chapter.title).font(.subheadline.weight(.semibold))
                            Spacer()
                            Text(chapter.timeRange)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        if !chapter.summary.isEmpty {
                            Text(chapter.summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    /// Notes are markdown, rendered as plain text: the phone has no markdown
    /// renderer (`ChatView` shows assistant answers the same way), and
    /// `Text(LocalizedStringKey(…))` would style emphasis while leaving `#`
    /// headings and `-` bullets literal — half-rendered markdown reads worse
    /// than the source. Selectable so a line can be copied out.
    @ViewBuilder
    private func notesSection(_ notes: String) -> some View {
        if !notes.isEmpty {
            Section("Meeting notes") {
                Text(notes)
                    .font(.subheadline)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private func speakerSection(_ speakers: [String]) -> some View {
        if !speakers.isEmpty {
            Section("Speakers") {
                ForEach(Array(speakers.enumerated()), id: \.offset) { _, speaker in
                    Label(speaker, systemImage: "person.wave.2")
                        .font(.subheadline)
                }
            }
        }
    }

    /// The one place that states where the real transcript lives — exactly
    /// where a reader goes looking for it.
    private func transcriptSection(_ snippet: String) -> some View {
        Section {
            if snippet.isEmpty {
                Text("No transcript preview.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text(snippet)
                    .font(.subheadline)
                    .textSelection(.enabled)
            }
        } header: {
            Text("Transcript preview")
        } footer: {
            Text(
                """
                The first 200 characters only. The full transcript and the audio \
                stay on your Mac — open the recording in the Watchtower desktop \
                app to read or play it.
                """
            )
        }
    }
}
