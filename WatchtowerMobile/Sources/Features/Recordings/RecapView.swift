import os
import SwiftUI
import WatchtowerKit

/// The recap and transcript of one recording (spec §13 C3): Recap |
/// Transcript, the phone's marks as jump points into the transcript.
/// Opening it marks the recap seen.
struct RecapView: View {
    let transcriptID: Int

    @Environment(AppEnvironment.self) private var env
    @State private var tab: Tab = .recap
    @State private var loaded: RecapLoader.Loaded?
    /// The line a jump point asked for; consumed by the scroll reader.
    @State private var jumpTarget: Int?
    @State private var highlighted: Int?

    private static let logger = Logger(subsystem: "WatchtowerMobile", category: "RecapView")

    enum Tab: String, CaseIterable, Identifiable {
        case recap = "Recap"
        case transcript = "Transcript"
        var id: Self { self }
    }

    private var transcript: MeetingTranscript? {
        env.calendarReplica.snapshot.transcripts.first { $0.id == transcriptID }
    }

    var body: some View {
        Group {
            if let transcript {
                content(transcript)
                    .task(id: transcript.updatedAt) { await load(transcript) }
            } else {
                ContentUnavailableView(
                    "Recording not on this phone",
                    systemImage: "waveform",
                    description: Text("It may have aged out; the Mac still has it.")
                )
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { env.recordingsSeen.markOpened(transcriptID) }
    }

    private func load(_ transcript: MeetingTranscript) async {
        do {
            loaded = try await RecapLoader.load(transcript: transcript, recordings: env.phoneRecordings.snapshot, store: env.store)
        } catch {
            Self.logger.error("recap load failed: \(error.localizedDescription, privacy: .public)")
            loaded = RecapLoader.Loaded(body: .unreadable(error.localizedDescription), marks: [])
        }
    }

    private func content(_ transcript: MeetingTranscript) -> some View {
        let model = RecapModel(
            transcript: transcript,
            body: loaded?.body ?? .segments([]),
            marks: loaded?.marks ?? [],
            calendar: .current,
            now: Date()
        )
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header(model)
                    Picker("View", selection: $tab) {
                        ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if !model.jumpPoints.isEmpty {
                        marks(model.jumpPoints)
                    }
                    switch tab {
                    case .recap: recap(model)
                    case .transcript: transcriptLines(model, loading: loaded == nil)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .onChange(of: jumpTarget) {
                guard let target = jumpTarget else { return }
                jumpTarget = nil
                // The transcript tab lays out in this pass; scroll on the next.
                Task { @MainActor in
                    withAnimation { proxy.scrollTo(target, anchor: .top) }
                    highlighted = target
                }
            }
        }
    }

    private func header(_ model: RecapModel) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(model.title).font(.title2.weight(.bold))
            Text(model.subtitle).font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }

    /// The phone's marks: tap one to jump into the transcript.
    private func marks(_ points: [JumpPoint]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(points) { point in
                    Button {
                        guard let line = point.lineID else { return }
                        tab = .transcript
                        jumpTarget = line
                    } label: {
                        Label(point.label, systemImage: "flag")
                            .font(.footnote.monospacedDigit())
                            .padding(.horizontal, 12)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.bordered)
                    .disabled(point.lineID == nil)
                    .accessibilityLabel(point.accessibilityLabel)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Marks")
    }

    @ViewBuilder
    private func recap(_ model: RecapModel) -> some View {
        if let summary = model.summary {
            Text(summary).font(.body).foregroundStyle(.primary.opacity(0.85))
        }
        if let empty = model.recapEmptyText {
            Text(empty).foregroundStyle(.secondary)
        }
        ForEach(model.sections) { section in
            VStack(alignment: .leading, spacing: 0) {
                Text(section.title.uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 2)
                ForEach(Array(section.items.enumerated()), id: \.offset) { _, item in
                    Text(item)
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 10)
                    Divider()
                }
                if let more = section.moreText {
                    Text(more).font(.footnote).foregroundStyle(.secondary).padding(.top, 8)
                }
            }
            .padding(.top, 8)
        }
    }

    @ViewBuilder
    private func transcriptLines(_ model: RecapModel, loading: Bool) -> some View {
        if loading {
            ProgressView().frame(maxWidth: .infinity)
        } else {
            if let notice = model.clippedNotice {
                Label(notice, systemImage: "scissors")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let error = model.transcriptError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(PhoneTone.red.color)
            }
            ForEach(model.lines) { line in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        if let speaker = line.speaker {
                            Text(speaker).font(.subheadline.weight(.semibold)).foregroundStyle(line.speakerTone.color)
                        }
                        Text(line.time).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Text(line.text).font(.subheadline)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(
                    highlighted == line.id ? PhoneTone.accent.color.opacity(0.12) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8)
                )
                .id(line.id)
                .accessibilityElement(children: .combine)
            }
        }
    }
}
