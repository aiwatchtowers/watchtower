import SwiftUI
import WatchtowerKit

/// The recap and transcript of one recording (spec §13 C3): Recap |
/// Transcript, the phone's marks as jump points into the transcript.
/// Opening it marks the recap seen.
struct RecapView: View {
    let transcriptID: Int

    @Environment(AppEnvironment.self) private var env
    @State private var tab: Tab
    @State private var bodyModel = RecapBodyModel()
    /// The line a jump point asked for; consumed by the scroll reader.
    @State private var jumpTarget: Int?
    @State private var highlighted: Int?

    /// `initialTab` is for the screenshot tour; the app always opens Recap.
    init(transcriptID: Int, initialTab: Tab = .recap) {
        self.transcriptID = transcriptID
        _tab = State(initialValue: initialTab)
    }

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
                let phoneID = env.phoneRecordings.snapshot.phoneRecordingID(forTranscript: transcript)
                content(transcript)
                    .task(id: phoneID) {
                        bodyModel.observe(transcript: transcript, phoneRecordingID: phoneID, store: env.store)
                    }
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

    private func content(_ transcript: MeetingTranscript) -> some View {
        let loaded = bodyModel.loaded
        let model = RecapModel(
            transcript: transcript,
            body: loaded?.body ?? .segments([]),
            marks: loaded?.marks ?? [],
            calendar: .current,
            now: Date()
        )
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.medium) {
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
                .padding(.horizontal, Spacing.large)
                .padding(.bottom, Spacing.wide)
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
        VStack(alignment: .leading, spacing: Spacing.tight) {
            Text(model.title).font(TypeScale.pageTitle)
            Text(model.subtitle).font(TypeScale.meta).foregroundStyle(.secondary)
        }
        .padding(.top, Spacing.small)
    }

    /// The phone's marks: tap one to jump into the transcript.
    private func marks(_ points: [JumpPoint]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.regular) {
                ForEach(points) { point in
                    Button {
                        guard let line = point.lineID else { return }
                        tab = .transcript
                        jumpTarget = line
                    } label: {
                        Label(point.label, systemImage: "flag")
                            .font(TypeScale.time)
                            .padding(.horizontal, Spacing.medium)
                            .frame(minHeight: PhoneMetrics.minTouch)
                            .background(Fill.card, in: Capsule().inset(by: Spacing.regular))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
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
            SectionHeader("Summary")
            Text(summary)
                .font(TypeScale.rowTitle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Spacing.small)
        }
        if let empty = model.recapEmptyText {
            Text(empty).foregroundStyle(.secondary)
        }
        ForEach(model.sections) { section in
            // C6: a headline as written; the count of items beside it.
            SectionHeader(section.title, count: section.items.count)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(section.items.enumerated()), id: \.offset) { index, item in
                    if index > 0 { CardRowDivider() }
                    Text(item)
                        .font(TypeScale.rowTitle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, Spacing.cozy)
                }
            }
            .card()
            if let more = section.moreText {
                Text(more).font(TypeScale.meta).foregroundStyle(.secondary).padding(.horizontal, Spacing.small)
            }
        }
    }

    @ViewBuilder
    private func transcriptLines(_ model: RecapModel, loading: Bool) -> some View {
        if loading {
            ProgressView().frame(maxWidth: .infinity)
        } else {
            if let notice = model.clippedNotice {
                Label(notice, systemImage: "scissors")
                    .font(TypeScale.meta)
                    .foregroundStyle(.secondary)
            }
            if let empty = model.emptyTranscriptText {
                Text(empty).foregroundStyle(.secondary)
            }
            if let error = model.transcriptError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(TypeScale.meta)
                    .foregroundStyle(PhoneTone.red.color)
            }
            ForEach(model.lines) { line in
                VStack(alignment: .leading, spacing: Spacing.tight) {
                    HStack(spacing: Spacing.regular) {
                        if let speaker = line.speaker {
                            Text(speaker).font(.subheadline.weight(.semibold)).foregroundStyle(line.speakerTone.color)
                        }
                        Text(line.time).font(TypeScale.time).foregroundStyle(.secondary)
                    }
                    Text(line.text).font(TypeScale.rowTitle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Spacing.regular)
                .background(
                    highlighted == line.id ? Fill.selected : Color.clear,
                    in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                )
                .id(line.id)
                .accessibilityElement(children: .combine)
            }
        }
    }
}
