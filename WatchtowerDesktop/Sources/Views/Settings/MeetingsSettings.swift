import SwiftUI

/// Meetings tab — everything about recording and transcribing meetings.
/// Moved out of the old General tab; same @AppStorage keys, same controls.
struct MeetingsSettings: View {
    @Environment(AppState.self) private var appState
    @Bindable var config: ConfigService

    @AppStorage("transcription.provider") private var transcriptionProvider = "whisperkit"
    @AppStorage("transcription.model") private var transcriptionModel = "large-v3-v20240930"
    @AppStorage("transcription.langset") private var transcriptionLangset = "ru,uk,en"
    @AppStorage("transcription.windowSec") private var transcriptionWindowSec = 30.0
    @AppStorage("transcription.langThreshold") private var transcriptionLangThreshold = 0.6
    @AppStorage("transcription.margin") private var transcriptionMargin = 0.2
    @AppStorage("transcription.forceLang") private var transcriptionForceLang = ""
    @AppStorage("transcription.diarization") private var transcriptionDiarization = true
    @AppStorage("transcription.contextPrompt") private var transcriptionContextPrompt = false
    @AppStorage("transcription.liveTranscription") private var transcriptionLive = true
    @AppStorage(MeetingRecorderCenter.preloadBeforeMeetingsKey) private var transcriptionPreload = true
    @AppStorage("transcription.diarizationThreshold") private var transcriptionDiarizationThreshold = 0.6
    @AppStorage("transcription.micAGC") private var transcriptionMicAGC = false
    @AppStorage(JoinMeetingAction.autoRecordKey) private var autoRecordOnJoin = true
    @State private var showAdvancedTranscription = false

    var body: some View {
        Form {
            engineSection
            recordingSection
            speakersSection
            advancedSection
        }
        .formStyle(.grouped)
        .padding(.horizontal)
        .padding(.top, 4)
        .safeAreaInset(edge: .bottom) {
            ConfigSaveBar(config: config)
        }
    }

    private var engineSection: some View {
        Section("Engine") {
            Picker("Engine", selection: $transcriptionProvider) {
                ForEach(TranscriptionProviderRegistry.availableProviders(), id: \.displayName) { p in
                    Text(p.displayName).tag(type(of: p).id)
                }
            }
            .help("On-device transcription engine")
            .onChange(of: transcriptionProvider) { _, id in
                // Reset the model to the new provider's default, then prefetch.
                let provider = TranscriptionProviderRegistry.resolve(providerID: id)
                transcriptionModel = provider.models.first?.id ?? transcriptionModel
                appState.transcriptionModelProvisioner.ensureDownloaded(providerID: id, model: transcriptionModel)
            }

            Picker("Model", selection: $transcriptionModel) {
                ForEach(TranscriptionProviderRegistry.resolve(providerID: transcriptionProvider).models) { m in
                    Text(m.label).tag(m.id)
                }
            }
            .help("Model used for on-device transcription")
            .onChange(of: transcriptionModel) { _, newValue in
                appState.transcriptionModelProvisioner.ensureDownloaded(providerID: transcriptionProvider, model: newValue)
            }

            engineCapabilityCaption

            if let supported = TranscriptionProviderRegistry.resolve(providerID: transcriptionProvider)
                .supportedLanguages(model: transcriptionModel) {
                let missing = transcriptionLangset.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty && !supported.contains($0) }
                if !missing.isEmpty {
                    Label("This engine does not support: \(missing.joined(separator: ", "))",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }

            TextField(
                "Languages",
                text: $transcriptionLangset,
                prompt: Text("ru,uk,en")
            )
            .help("Comma-separated language codes to detect per window")
        }
    }

    private var recordingSection: some View {
        Section("Recording") {
            Toggle("Auto-record on join", isOn: $autoRecordOnJoin)
                .help("Pressing Join on a calendar event also starts an event-linked recording (unless one is already running)")

            Toggle("Live transcription", isOn: $transcriptionLive)
                .help("Transcribe while recording so text appears during the meeting. "
                    + "Off = record only and transcribe after Stop, keeping the machine idle during the call.")

            Toggle("Preload model before meetings", isOn: $transcriptionPreload)
                .help("Load the transcription model ~5 minutes before a meeting starts and keep it "
                    + "warm between back-to-back recordings, so Record starts instantly. "
                    + "Off = load on demand and free the memory once each recording is processed.")

            Toggle("Mic auto-gain (experimental)", isOn: $transcriptionMicAGC)
                .help("Boost a quiet microphone toward a healthy recording level while you are the "
                    + "dominant sound in it, so your own voice is not lost in the recording. "
                    + "Moments where remote participants are the dominant sound are left untouched, "
                    + "so their audio leaking into your mic is never amplified.")

            Stepper(
                "Delete audio after \(config.transcriptAudioRetentionDays) days",
                value: $config.transcriptAudioRetentionDays,
                in: 0...365
            )
            .help("Recording audio is deleted after this many days; transcript text is kept forever. 0 disables cleanup.")
        }
    }

    private var speakersSection: some View {
        Section("Speakers") {
            Toggle("Speaker roles", isOn: $transcriptionDiarization)
                .help("Label transcript lines with who was speaking ([Я] / [Speaker N]) using on-device diarization")

            LabeledContent("Diarization threshold") {
                TextField("", value: $transcriptionDiarizationThreshold, format: .number)
                    .frame(width: 70)
                    .multilineTextAlignment(.trailing)
            }
            .help("Speaker clustering strictness (0.3–0.9). Lower = more distinct speakers. "
                + "Try lowering when different people get merged into one Speaker N.")
        }
    }

    private var advancedSection: some View {
        Section {
            DisclosureGroup("Advanced", isExpanded: $showAdvancedTranscription) {
                advancedTranscriptionControls
            }
        }
    }

    @ViewBuilder
    private var advancedTranscriptionControls: some View {
        LabeledContent("Window (seconds)") {
            TextField("", value: $transcriptionWindowSec, format: .number)
                .frame(width: 70)
                .multilineTextAlignment(.trailing)
        }
        LabeledContent("Language threshold") {
            TextField("", value: $transcriptionLangThreshold, format: .number)
                .frame(width: 70)
                .multilineTextAlignment(.trailing)
        }
        LabeledContent("Runner-up margin") {
            TextField("", value: $transcriptionMargin, format: .number)
                .frame(width: 70)
                .multilineTextAlignment(.trailing)
        }
        TextField(
            "Force language",
            text: $transcriptionForceLang,
            prompt: Text("auto-detect")
        )
        .help("Set a language code (e.g. ru) to skip detection entirely")

        Toggle("Cross-window context (experimental)", isOn: $transcriptionContextPrompt)
            .help("Feed each window's decode the previous window's text (Whisper long-form conditioning). "
                + "May help continuity on clean audio; costs roughly 1.4x decode time. WhisperKit engine only.")
    }

    /// One-line summary of what the selected engine/model can do, so the
    /// live-vs-batch difference is visible right where the engine is chosen
    /// (batch engines show no live panel while recording — that's expected,
    /// not a bug).
    private var engineCapabilityCaption: some View {
        let provider = TranscriptionProviderRegistry.resolve(providerID: transcriptionProvider)
        var parts = [
            provider.supportsLive
                ? "Live transcript while recording"
                : "No live transcript — text appears after Stop"
        ]
        if let langs = provider.supportedLanguages(model: transcriptionModel) {
            parts.append("\(langs.count) languages")
        } else {
            parts.append("any language")
        }
        return Label(parts.joined(separator: " · "),
                     systemImage: provider.supportsLive ? "waveform.badge.mic" : "clock")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
