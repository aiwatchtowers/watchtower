# Voice Dictation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Dictate text by voice anywhere free-form text is written in the Desktop app (idea create sheet, meeting notes, Discuss chats, tray quick-capture), with live raw preview and an AI cleanup pass shaped for the destination.

**Architecture:** A new `DictationCenter` on `AppState` drives a new mic-only 16 kHz recorder through the existing `Transcriber`/`TranscriptionLiveSession` provider abstraction (live preview when the provider supports it, batch decode from the in-memory buffer otherwise), then calls a new Go CLI command `watchtower dictate clean` (new light-tier prompt `dictation.clean`) to turn the raw transcript into destination-shaped text. A reusable `DictationButton` integrates it into surfaces.

**Tech Stack:** Swift 5.10 / SwiftUI / AVAudioEngine (new usage), existing transcription provider stack, Go 1.25 / cobra, DB-backed prompt store.

**Spec:** `docs/superpowers/specs/2026-08-11-voice-dictation-design.md`

## Global Constraints

- Everything committed to the repo (code, comments, commit messages, docs) is in English.
- Dictation is a *consumer* of the transcription stack: `StreamingTranscriber`, `WindowedTranscriber`, `WindowPlanner`, `Qwen3Windower`, and the live↔batch equivalence pins must NOT be modified.
- The AI call must work on BOTH providers (claude + codex); light tier requires adding the source tag to BOTH `internal/digest/models.go` and `internal/codex/models.go`.
- The dictated text rides the USER message of the AI call (never the system prompt) so the >32 KB stdin path stays reachable.
- No new TCC surfaces: no `NSEvent` global monitors (Carbon `RegisterEventHotKey` only), mic capture through the standard already-shipped mic permission.
- No new `idea` statuses: quick capture reuses the existing manual-create path (`status='active'`, `source='owner'`, one `idea_mentions` row).
- `QuitCoordinator` does NOT gain dictation in its busy gate (per spec).
- House rules: async UI state lives on an `@MainActor @Observable` center on `AppState`; Swift tests use fakes, never real CoreML/AVAudioEngine; every new Settings-independent behavior needs tests including valid-but-degenerate inputs.
- Update `docs/app-guide.md` for the UI changes (injected into the chatbot system prompt — standing maintenance rule).

---

### Task 1: Go — register the `dictation.clean` prompt + light-tier routing

**Files:**
- Modify: `internal/prompts/store.go` (ID const block)
- Modify: `internal/prompts/defaults.go` (`Defaults`, `AllIDs`, `DefaultVersions`, `Descriptions` + template const)
- Modify: `internal/digest/models.go` (light-tier switch)
- Modify: `internal/codex/models.go` (light-tier switch)
- Test: `internal/prompts/defaults_extra_test.go`, `internal/digest/models_test.go` (if present — otherwise assert in `internal/digest`'s existing test file for `ModelForSource`), `internal/codex/` equivalent

**Interfaces:**
- Produces: `prompts.DictationClean = "dictation.clean"` (string const); template `defaultDictationClean` whose `fmt.Sprintf` placeholders are, in order: `%s` mode instruction block, `%s` language directive. `ModelForSource("dictation.clean")` returns the light model in both packages.

- [ ] **Step 1: Write the failing registration pin test** in `internal/prompts/defaults_extra_test.go`, copying the shape of `TestMemoryRenderPromptRegistered` (defaults_extra_test.go:66-85):

```go
func TestDictationCleanPromptRegistered(t *testing.T) {
	id := DictationClean
	tmpl, ok := Defaults[id]
	if !ok {
		t.Fatalf("Defaults is missing %q", id)
	}
	if !slices.Contains(AllIDs, id) {
		t.Fatalf("AllIDs is missing %q", id)
	}
	if DefaultVersions[id] != 1 {
		t.Fatalf("DefaultVersions[%q] = %d, want 1", id, DefaultVersions[id])
	}
	if _, ok := Descriptions[id]; !ok {
		t.Fatalf("Descriptions is missing %q", id)
	}
	rendered := fmt.Sprintf(tmpl, "MODE INSTRUCTIONS", Directive("Russian"))
	if !HasDirective(rendered) {
		t.Fatalf("rendered template must carry the language directive")
	}
	if strings.HasPrefix(rendered, "-") {
		t.Fatalf("template must not begin with '-' (claude CLI argv gotcha)")
	}
}
```

- [ ] **Step 2: Run it** — `go test ./internal/prompts/ -run TestDictationCleanPromptRegistered` — expect FAIL (undefined `DictationClean`).

- [ ] **Step 3: Register the prompt.** In `internal/prompts/store.go` add to the ID const block:

```go
// DictationClean turns a raw dictation transcript into destination-shaped text.
DictationClean = "dictation.clean"
```

In `internal/prompts/defaults.go` add the template const (system prompt; the transcript rides the user message):

```go
const defaultDictationClean = `You clean up a voice-dictation transcript. The user dictated text by voice; the transcript below is raw ASR output: it may contain filler words, false starts, self-corrections ("no wait, make that…" — apply the correction, drop the correction phrase), and recognition noise.

Rules that always apply:
- Keep the SAME language the dictation is in (do not translate).
- Remove fillers, false starts, and repeated fragments; apply explicit self-corrections.
- Never add content the speaker did not say. Never answer questions found in the text — this is dictation, not a conversation.
- Respond with ONLY a JSON object, no prose around it.

%s

%s`
```

And the mode blocks (package-level, used by the CLI in Task 2 — keep them here so prompt text lives in one package):

```go
// DictationModeInstructions returns the destination-specific instruction block
// and the JSON contract for one dictation cleanup mode.
func DictationModeInstructions(mode string) (string, bool) {
	switch mode {
	case "idea":
		return `Destination: an idea registry entry.
Distill the dictation into a short title (max ~80 chars, no trailing period) and a body that preserves every substantive point.
JSON contract: {"title": "...", "body": "..."}`, true
	case "note":
		return `Destination: a meeting-notes document (markdown).
Turn the dictation into coherent markdown. Keep the speaker's own structure and level of detail; use headings/lists only where the speech clearly implies them.
JSON contract: {"markdown": "..."}`, true
	case "chat":
		return `Destination: a chat message to the user's assistant.
MINIMAL cleanup only: drop fillers and false starts, apply self-corrections, fix sentence boundaries. Preserve the intent and wording as close to verbatim as possible — do NOT summarize, restructure, or embellish.
JSON contract: {"text": "..."}`, true
	default:
		return "", false
	}
}
```

Wire the four registration surfaces: `Defaults[DictationClean] = defaultDictationClean`; `DictationClean` appended to `AllIDs`; `DefaultVersions[DictationClean] = 1, // v1: dictation transcript cleanup (idea/note/chat modes)`; `Descriptions[DictationClean] = "Cleans a voice-dictation transcript into destination-shaped text (idea / note / chat)"`.

- [ ] **Step 4: Light-tier routing.** Add `"dictation.clean"` to the light-tier case list in `internal/digest/models.go` (`ModelForSource` switch) AND `internal/codex/models.go`. Add/extend a test asserting `ModelForSource("dictation.clean") == ModelHaiku` (digest) and the codex equivalent returns `ModelLightweight` — follow whatever existing `ModelForSource` tests do in those packages; if none exist, add `TestModelForSourceDictationClean` in both.

- [ ] **Step 5: Run the package tests** — `go test ./internal/prompts/ ./internal/digest/ ./internal/codex/` — expect PASS (including the pre-existing `TestDefaultsMatchPromptIDs` / `TestAllIDsMatchDefaults` guards).

- [ ] **Step 6: Commit** — `git commit -m "feat(prompts): register dictation.clean light-tier prompt"`.

---

### Task 2: Go — `watchtower dictate clean` command

**Files:**
- Create: `cmd/dictate.go`
- Test: `cmd/dictate_test.go`

**Interfaces:**
- Consumes: `prompts.DictationClean`, `prompts.DictationModeInstructions(mode)`, `prompts.Directive(lang)`, `prompts.ExtractJSONObject`, `digest.WithSource`, `cliGenerator`, `openDBFromConfig` ordering (`applyProviderOverride` before generator).
- Produces: CLI `watchtower dictate clean --mode idea|note|chat --transcript-file <path>`. Stdout envelope (two-space-indent JSON): mode `idea` → `{"mode":"idea","title":"…","body":"…"}`; `note` → `{"mode":"note","markdown":"…"}`; `chat` → `{"mode":"chat","text":"…"}`. Non-zero exit on any failure, nothing persisted. Test seam: `var dictateGeneratorFactory = func(cfg *config.Config) digest.Generator { return cliGenerator(cfg) }`.

- [ ] **Step 1: Write failing tests** in `cmd/dictate_test.go`. Copy the harness pieces from `cmd/meeting_transcript_test.go`: a `dictateMockGen` (same shape as `transcriptMockGen` — records `lastUserMessage`, `calls`, scripted `response`/`err`) and `stubDictateGenerator(t, gen)` swapping `dictateGeneratorFactory` under `t.Cleanup`. Tests:

```go
func TestDictateCleanIdeaMode(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()
	resetDictateFlags(t)
	gen := &dictateMockGen{response: `{"title":"Ship v2","body":"We should ship v2 next week."}`}
	stubDictateGenerator(t, gen)

	f := writeTempTranscript(t, "so um we should ship v2 next week I think")

	var buf bytes.Buffer
	dictateCleanCmd.SetOut(&buf)
	dictateCleanFlagMode = "idea"
	dictateCleanFlagFile = f
	require.NoError(t, dictateCleanCmd.RunE(dictateCleanCmd, nil))

	env := rawEnvelopeFrom(t, buf.Bytes())
	assert.Equal(t, "idea", env["mode"])
	assert.Equal(t, "Ship v2", env["title"])
	assert.Equal(t, "We should ship v2 next week.", env["body"])
	assert.Equal(t, 1, gen.calls)
	assert.Contains(t, gen.lastUserMessage, "ship v2 next week", "transcript must ride the USER message")
}
```

Also write (same pattern, one test each): `TestDictateCleanNoteMode` (asserts `markdown` key), `TestDictateCleanChatMode` (asserts `text` key), `TestDictateCleanRejectsUnknownMode` (mode `"poem"` → error mentioning valid modes, generator never called), `TestDictateCleanRequiresTranscriptFile` (no flag → error), `TestDictateCleanEmptyTranscript` (file with only whitespace → error, generator never called), `TestDictateCleanGeneratorFailure` (gen err → `RunE` returns error containing "boom"), `TestDictateCleanMissingRequiredKey` (idea-mode reply `{"title":"x"}` with empty/missing body → error mentioning the raw reply), `TestDictateCleanFencedJSON` (reply wrapped in ```json fences still parses — through `prompts.ExtractJSONObject`).

Add `writeTempTranscript(t, s)` helper (temp file via `t.TempDir()`), `resetDictateFlags(t)` resetting the package-level flag vars, and `rawEnvelopeFrom` (decode into `map[string]any`; reuse `rawEnvelope` if it fits).

- [ ] **Step 2: Run** — `go test ./cmd/ -run TestDictateClean` — expect FAIL (undefined symbols).

- [ ] **Step 3: Implement `cmd/dictate.go`:**

```go
package cmd

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"

	"github.com/spf13/cobra"

	"watchtower/internal/config"
	"watchtower/internal/digest"
	"watchtower/internal/prompts"
)

var (
	dictateCleanFlagMode string
	dictateCleanFlagFile string
)

// dictateGeneratorFactory is the seam tests override to inject a mock
// generator (same pattern as transcriptGeneratorFactory).
var dictateGeneratorFactory = func(cfg *config.Config) digest.Generator {
	return cliGenerator(cfg)
}

var dictateCmd = &cobra.Command{
	Use:   "dictate",
	Short: "Voice-dictation helpers for the Desktop app",
}

var dictateCleanCmd = &cobra.Command{
	Use:   "clean",
	Short: "Clean a raw dictation transcript into destination-shaped text",
	Long: `Cleans a raw voice-dictation transcript via a light-tier AI pass.
Pure transform: reads the transcript file, prints a JSON envelope on stdout,
persists nothing. Exits 1 on any failure.`,
	RunE: runDictateClean,
}

func init() {
	rootCmd.AddCommand(dictateCmd)
	dictateCmd.AddCommand(dictateCleanCmd)
	dictateCleanCmd.Flags().StringVar(&dictateCleanFlagMode, "mode", "", "cleanup destination: idea, note, or chat (required)")
	dictateCleanCmd.Flags().StringVar(&dictateCleanFlagFile, "transcript-file", "", "path to the raw transcript text file (required)")
}

func runDictateClean(cmd *cobra.Command, _ []string) error {
	instructions, ok := prompts.DictationModeInstructions(dictateCleanFlagMode)
	if !ok {
		return fmt.Errorf("invalid --mode %q (valid: idea, note, chat)", dictateCleanFlagMode)
	}
	if dictateCleanFlagFile == "" {
		return fmt.Errorf("--transcript-file is required")
	}
	raw, err := os.ReadFile(dictateCleanFlagFile)
	if err != nil {
		return fmt.Errorf("reading transcript file: %w", err)
	}
	transcript := strings.TrimSpace(string(raw))
	if transcript == "" {
		return fmt.Errorf("transcript file is empty")
	}

	cfg, err := config.Load(flagConfig)
	if err != nil {
		return fmt.Errorf("loading config: %w", err)
	}
	applyProviderOverride(cfg)

	database, err := openDBFromConfig()
	if err != nil {
		return fmt.Errorf("opening database: %w", err)
	}
	defer database.Close()

	store := prompts.New(database, nil)
	tmpl, _, storeErr := store.Get(prompts.DictationClean)
	if storeErr != nil {
		tmpl = prompts.Defaults[prompts.DictationClean]
	}
	system := fmt.Sprintf(tmpl, instructions, prompts.Directive(cfg.AI.Language))
	// The transcript rides the USER message so the >32 KB stdin path stays
	// reachable and a leading "-" can never be parsed as a CLI flag.
	user := "=== RAW DICTATION TRANSCRIPT ===\n" + transcript

	gen := dictateGeneratorFactory(cfg)
	reply, _, _, err := gen.Generate(digest.WithSource(cmd.Context(), "dictation.clean"), system, user, "")
	if err != nil {
		return fmt.Errorf("cleaning dictation: %w", err)
	}

	obj, err := prompts.ExtractJSONObject(reply)
	if err != nil {
		return fmt.Errorf("extracting cleanup JSON: %w (raw: %.300s)", err, reply)
	}
	var parsed struct {
		Title    string `json:"title"`
		Body     string `json:"body"`
		Markdown string `json:"markdown"`
		Text     string `json:"text"`
	}
	if err := json.Unmarshal([]byte(obj), &parsed); err != nil {
		return fmt.Errorf("parsing cleanup JSON: %w (raw: %.300s)", err, reply)
	}

	envelope := map[string]any{"mode": dictateCleanFlagMode}
	switch dictateCleanFlagMode {
	case "idea":
		if strings.TrimSpace(parsed.Title) == "" || strings.TrimSpace(parsed.Body) == "" {
			return fmt.Errorf("cleanup reply missing title/body (raw: %.300s)", reply)
		}
		envelope["title"], envelope["body"] = parsed.Title, parsed.Body
	case "note":
		if strings.TrimSpace(parsed.Markdown) == "" {
			return fmt.Errorf("cleanup reply missing markdown (raw: %.300s)", reply)
		}
		envelope["markdown"] = parsed.Markdown
	case "chat":
		if strings.TrimSpace(parsed.Text) == "" {
			return fmt.Errorf("cleanup reply missing text (raw: %.300s)", reply)
		}
		envelope["text"] = parsed.Text
	}

	enc := json.NewEncoder(cmd.OutOrStdout())
	enc.SetIndent("", "  ")
	return enc.Encode(envelope)
}
```

Adjust to the real local helpers: if `config.Load(flagConfig)`/`applyProviderOverride` differ in name or signature, copy the exact bootstrap used by `openDBFromConfig` callers (`cmd/watch.go:98-115`) — the requirement is: provider override applied before the generator is built; workspace DB opened only to read the tunable prompt.

- [ ] **Step 4: Run** — `go test ./cmd/ -run TestDictateClean` — expect PASS. Then the full gate: `go build ./... && go vet ./... && go test ./cmd/ ./internal/prompts/`.

- [ ] **Step 5: Commit** — `git commit -m "feat(cli): add dictate clean command (dictation transcript cleanup)"`.

---

### Task 3: Swift — `MicRecorder` (mic-only 16 kHz capture)

**Files:**
- Create: `WatchtowerDesktop/Sources/Services/Transcription/MicRecorder.swift`
- Test: `WatchtowerDesktop/Tests/Helpers/DictationTestSupport.swift` (FakeMicRecorder), `WatchtowerDesktop/Tests/MicRecorderTests.swift`

**Interfaces:**
- Produces:

```swift
/// Mic-only live capture for dictation. Unlike AudioRecording it writes no
/// file — samples exist only in the stream (the caller buffers them).
protocol MicRecording: AnyObject {
    /// Requests mic permission on first use; throws on denial or engine failure.
    func start() async throws
    func stop()
    /// Live 16 kHz mono Float32 samples; finishes when stop() is called.
    var samples: AsyncStream<[Float]> { get }
}

final class MicRecorder: MicRecording { init() }
enum MicRecorderError: LocalizedError { case microphonePermissionDenied; case engineStartFailed(String) }
```

- [ ] **Step 1: Write FakeMicRecorder** in `Tests/Helpers/DictationTestSupport.swift`, mirroring `FakeRecorder` (`Tests/Helpers/MeetingRecorderTestSupport.swift:11-49`) minus the file: owns its continuation, `func emit(_ samples: [Float])`, `startError` knob, `startCalls`/`stopCalls` counters, `stop()` finishes the continuation.

- [ ] **Step 2: Write `MicRecorderTests`** — real-hardware paths can't run in CI, so test the pure parts: (a) stream finishes after `stop()` even when `start()` was never called (degenerate); (b) `start()` throws `.microphonePermissionDenied` when the permission hook reports denied — make the permission check injectable: `init(requestAccess: @escaping () async -> Bool = { await AVCaptureDevice.requestAccess(for: .audio) })`.

- [ ] **Step 3: Run** — `cd WatchtowerDesktop && swift test --filter MicRecorderTests 2>&1 | tee /tmp/t.log; echo "exit=$?"` — expect FAIL (type not found). (Always check the real exit code — never pipe through `tail` alone.)

- [ ] **Step 4: Implement `MicRecorder`.** `AVAudioEngine`; on `start()`: `guard await requestAccess() else { throw .microphonePermissionDenied }`, install a tap on `engine.inputNode` with the node's output format, convert each tap buffer to 16 kHz mono Float32 through `AVAudioConverter` (copy the converter dance from `SystemAudioRecorder.appendDownsampled`, `SystemAudioRecorder.swift:326-363` — including the `consumed` one-shot input block and the `frameLength > 0` guard), yield `Array(UnsafeBufferPointer(start: data, count: n))` per converted buffer into the continuation. `stop()`: remove tap, stop engine, `continuation.finish()`. `deinit` also finishes the continuation (SystemAudioRecorder precedent). No file writes anywhere.

- [ ] **Step 5: Run tests** — same filter — expect PASS. Also `swift build 2>&1 | tail -5; echo "exit=$?"`.

- [ ] **Step 6: Commit** — `git commit -m "feat(desktop): mic-only 16 kHz recorder for dictation"`.

---

### Task 4: Swift — `DictationCleanService` (CLI wrapper)

**Files:**
- Create: `WatchtowerDesktop/Sources/Services/DictationCleanService.swift`
- Test: `WatchtowerDesktop/Tests/DictationCleanServiceTests.swift`

**Interfaces:**
- Consumes: `CLIRunnerProtocol` (`Sources/Services/CLIRunner.swift:8-12`).
- Produces:

```swift
enum DictationMode: String, Sendable { case idea, note, chat }

/// Cleaned dictation, shaped for the destination.
struct DictationCleanResult: Equatable, Sendable {
    var title: String?   // idea mode only
    var text: String     // body / markdown / chat text
}

struct DictationCleanService {
    let runner: CLIRunnerProtocol
    func clean(transcript: String, mode: DictationMode) async throws -> DictationCleanResult
}
```

- [ ] **Step 1: Write failing tests** using the existing `FakeCLIRunner`/`TranscriptCapturingRunner` patterns (`Tests/Helpers/MeetingRecorderTestSupport.swift:184-215`): (a) idea mode decodes `{"mode":"idea","title":"T","body":"B"}` → `DictationCleanResult(title:"T", text:"B")`; (b) note mode maps `markdown` → `text`, title nil; (c) chat mode maps `text` → `text`; (d) the transcript is passed via a `--transcript-file` temp file whose content the capturing runner reads DURING the call, and the file is gone after; (e) runner throw propagates; (f) envelope missing its mode key → throws a descriptive error.

- [ ] **Step 2: Run** — `swift test --filter DictationCleanServiceTests` — expect FAIL.

- [ ] **Step 3: Implement.** Write transcript to `FileManager.default.temporaryDirectory.appendingPathComponent("dictation-\(UUID().uuidString).txt")`, `defer { try? FileManager.default.removeItem(at: url) }` (the `TranscriptSaveService.save` precedent, `TranscriptSaveService.swift:129-192`), run `["dictate", "clean", "--mode", mode.rawValue, "--transcript-file", url.path]`, decode with `JSONDecoder` into a private envelope struct with all-optional fields, map per mode, throw `DictationCleanError.badEnvelope` when the mode's key is absent/empty.

- [ ] **Step 4: Run tests** — expect PASS.

- [ ] **Step 5: Commit** — `git commit -m "feat(desktop): dictation cleanup CLI service"`.

---

### Task 5: Swift — `DictationCenter` + MeetingRecorderCenter hook + AppState wiring

**Files:**
- Create: `WatchtowerDesktop/Sources/Services/DictationCenter.swift`
- Modify: `WatchtowerDesktop/Sources/Services/MeetingRecorderCenter.swift` (one new optional hook)
- Modify: `WatchtowerDesktop/Sources/App/AppState.swift` (own + wire the center)
- Modify: `WatchtowerDesktop/Sources/App/WatchtowerApp.swift` (environment key injection, all four scenes)
- Test: `WatchtowerDesktop/Tests/DictationCenterTests.swift`

**Interfaces:**
- Consumes: `MicRecording` (Task 3), `DictationCleanService` (Task 4), `Transcriber`/`TranscriptionLiveSession` (`TranscriptionProvider.swift:30-47`), `MeetingRecorderCenter.defaultEngineFactory` (`MeetingRecorderCenter.swift:369-374`), `TranscriptionConfig.fromDefaults`.
- Produces:

```swift
enum DictationPhase: Equatable {
    case idle, loadingEngine, recording, cleaning
    case failed(String)
}

@MainActor @Observable
final class DictationCenter {
    private(set) var phase: DictationPhase = .idle
    private(set) var activeTargetID: String?
    private(set) var liveText: String = ""      // accumulated raw text
    private(set) var lastRaw: String?           // survives cleanup, for "Raw" revert
    /// Wired by AppState to MeetingRecorderCenter.isBusy. The button reads it
    /// to disable itself; start() reads it as the belt-and-braces guard.
    var meetingBusy: () -> Bool = { false }

    init(recorderFactory: @escaping () -> MicRecording = { MicRecorder() },
         engineFactory: @escaping (TranscriptionConfig) async throws -> Transcriber
             = MeetingRecorderCenter.defaultEngineFactory,
         runnerResolver: @escaping () -> CLIRunnerProtocol? = { ProcessCLIRunner.makeDefault() },
         defaults: UserDefaults = .standard,
         engineIdleTTL: Duration = .seconds(15 * 60))

    /// Starts dictating into one target. onLiveText delivers the full raw text
    /// accumulated so far; onResult delivers the cleaned result exactly once.
    func start(targetID: String, mode: DictationMode,
               onLiveText: @escaping @MainActor (String) -> Void,
               onResult: @escaping @MainActor (DictationCleanResult) -> Void)
    func stop()                      // stop mic → finish transcription → clean → onResult
    func cancel()                    // discard everything, back to idle
    func meetingCaptureWillStart()   // auto-stop active dictation + drop the resident engine
    func retry()                     // from .failed back to .idle
}
```

- MeetingRecorderCenter gains: `var captureWillStart: (() -> Void)?` — invoked synchronously at the top of `startRecording(eventID:title:)` before any engine work. AppState wires it in `initialize()`:

```swift
dictationCenter.meetingBusy = { [meetingRecorderCenter] in meetingRecorderCenter.isBusy }
meetingRecorderCenter.captureWillStart = { [dictationCenter] in dictationCenter.meetingCaptureWillStart() }
```

- SwiftUI environment key (in `DictationCenter.swift`):

```swift
private struct DictationCenterKey: EnvironmentKey {
    static let defaultValue: DictationCenter? = nil  // nil default keeps ViewInspector tests safe
}
extension EnvironmentValues {
    var dictationCenter: DictationCenter? {
        get { self[DictationCenterKey.self] } set { self[DictationCenterKey.self] = newValue }
    }
}
```

Injected in `WatchtowerApp.swift` alongside each scene's `.environment(appState)` (all four scenes — main WindowGroup at the OUTERMOST level per the documented overlay trap at `WatchtowerApp.swift:288-291`, progress, settings, tray): `.environment(\.dictationCenter, appState.dictationCenter)`.

**Behavior requirements (each is a test):**

1. **Live happy path:** `start` → engine loads via factory (phase `.loadingEngine` → `.recording`), mic samples stream into `makeLiveSession(config:)`; every chunk appends to `liveText` and fires `onLiveText`. `stop()` → mic stops, live session's `TranscriptionOutput.text` becomes the raw transcript → phase `.cleaning` → `DictationCleanService.clean` → `onResult(cleaned)` → `.idle`. `lastRaw` holds the raw transcript.
2. **Batch fallback:** engine factory returns a `Transcriber` whose `makeLiveSession` is nil (`TestTranscriber(engine, supportsLive: false)`) → no live chunks; all samples are buffered; `stop()` runs `transcriber.transcribe(buffer, config:, progress:)` then cleans. (The center ALWAYS buffers samples, so a mid-stream live failure also falls back to batch from the buffer — same rule as the meeting single-pass fallback.)
3. **Dictation config:** built once at `start` — `TranscriptionConfig.fromDefaults(defaults)` then override `windowSec = 10`, `diarization = false`, `boundarySnapSec` unchanged, `liveTranscription` NOT consulted (dictation live-ness is decided by `makeLiveSession` alone). If `TranscriptionConfig` fields are `let`, add a `func overridingForDictation() -> TranscriptionConfig` copy-helper next to `fromDefaults` — do NOT change existing field mutability.
4. **Degenerate stop:** `stop()` with zero samples / empty raw transcript → NO cleanup CLI call, `onResult(DictationCleanResult(title: nil, text: ""))`, `.idle`. (Valid-but-degenerate rule.)
5. **Cleanup failure:** CLI throws → `onResult` is NOT fired; phase `.failed("cleanup failed — raw text kept")`; `liveText`/`lastRaw` intact (the button leaves the raw span in the field).
6. **Sticky engine:** after a successful dictation the `Transcriber` reference is retained; a second `start` within the TTL does not call the engine factory again (assert `engineLoads == 1`). After `engineIdleTTL` elapses (tests inject `.milliseconds(5)`), the reference drops (factory called again).
7. **Meeting coordination:** `meetingCaptureWillStart()` during `.recording` → behaves exactly like `stop()` (delivers what was said) AND drops the resident engine after the cleanup completes; when `.idle` with a warm engine → just drops the engine. `start` while `meetingBusy()` is true → no-op: phase stays `.idle`, no callback fires (the button is disabled in that state anyway; this is the belt-and-braces path).
8. **Busy exclusivity:** `start` while another dictation is active → no-op (first dictation unaffected).
9. **Single onResult:** `stop()` twice → cleanup and `onResult` fire once.

- [ ] **Step 1: Write `DictationCenterTests`** covering all nine behaviors above, using `FakeMicRecorder`, `ScriptedEngine`/`TestTranscriber` (from `MeetingRecorderTestSupport.swift`), `FakeCLIRunner` with a canned `{"mode":"chat","text":"cleaned"}` stdout, `isolatedDefaults()`, and the `waitUntil` helper. Also add to `MeetingRecorderCenterTests` one test: `startRecording` invokes `captureWillStart` before capture begins.

- [ ] **Step 2: Run** — `swift test --filter DictationCenterTests` — expect FAIL.

- [ ] **Step 3: Implement `DictationCenter`** per the interface + behaviors. Key mechanics: one `dictationTask: Task<Void, Never>` drives recorder+live-session; a sample-buffering `Task` tees `recorder.samples` into both the buffer and (when live) the session — simplest correct shape: the center consumes `recorder.samples` itself, appends to `buffer`, and re-yields into a private `AsyncStream` handed to the live session (single consumer rule for AsyncStream — never give the same stream to two readers). Engine TTL: `engineReleaseTask = Task { try? await Task.sleep(for: engineIdleTTL); guard !Task.isCancelled else { return }; self.warmTranscriber = nil }`, cancelled+recreated on each use.

- [ ] **Step 4: Add the `captureWillStart` hook** to `MeetingRecorderCenter.startRecording` (first line, before `isStarting` work): `captureWillStart?()`. Wire both directions in `AppState.initialize()`; add `let dictationCenter = DictationCenter()` to AppState's center block. Inject the environment key in all four scenes in `WatchtowerApp.swift`.

- [ ] **Step 5: Run** — `swift test --filter 'DictationCenterTests|MeetingRecorderCenterTests' 2>&1 | tee /tmp/t.log; echo "exit=$?"` — expect PASS, plus `swift build`.

- [ ] **Step 6: Commit** — `git commit -m "feat(desktop): DictationCenter with sticky engine and meeting coordination"`.

---

### Task 6: Swift — `DictationButton` + IdeaCreateSheet integration (Phase 1 complete)

**Files:**
- Create: `WatchtowerDesktop/Sources/Views/Components/DictationButton.swift`
- Modify: `WatchtowerDesktop/Sources/Views/Ideas/IdeaCreateSheet.swift`
- Test: `WatchtowerDesktop/Tests/DictationButtonTests.swift`

**Interfaces:**
- Consumes: `DictationCenter` via `@Environment(\.dictationCenter)`.
- Produces:

```swift
/// Mic button + span management for one text binding. Renders nothing when
/// no DictationCenter is in the environment (tests, previews).
struct DictationButton: View {
    @Binding var text: String
    let mode: DictationMode
    let targetID: String                 // unique per field, e.g. "idea-create.essence"
    var onTitle: ((String) -> Void)?     // idea mode: cleaned title, fired only when non-nil
    var isDisabled: Bool = false         // parent-supplied extra gate (e.g. notes isGenerating)
}
```

**Span management (all in the button, center stays binding-agnostic):** on start, capture `baseText = text` (plus `"\n\n"` separator when non-empty for note mode, `" "` for chat/idea); `onLiveText: { raw in text = base + raw }`; `onResult: { r in text = base + r.text; if let t = r.title { onTitle?(t) }; armRevert(raw: center.lastRaw) }`. Revert = transient capsule "Raw" button (copy the undo-toast shape, `RecordingDetailTabs.swift:714-755` — armed only on success, 5 s cancellable auto-dismiss task) that sets `text = base + raw`. Empty result (`r.text.isEmpty && r.title == nil`) → `text = baseText` trimmed back, no revert.

**Button states:** mic glyph (`mic.fill`) idle; disabled + `.help(reason)` when `center.meetingBusy()` or `isDisabled` or another target is active; pulsing red while `.recording` on THIS target (reuse the recording-pulse idiom if one exists in `RecordingIndicatorView`, otherwise `.symbolEffect(.pulse)`); spinner while `.cleaning`; warning glyph + retry on `.failed`. Esc stops: `.onExitCommand { center.stop() }` on the button's container.

**IdeaCreateSheet:** place the button in the Essence label row (`HStack { Text("Essence"); Spacer(); DictationButton(text: $essence, mode: .idea, targetID: "idea-create.essence", onTitle: { if title.isEmpty { title = $0 } }) }`). Keep the ⌘Return create shortcut untouched.

- [ ] **Step 1: Write `DictationButtonTests`** — the span logic is the testable core; extract it into a small pure helper so tests don't need ViewInspector:

```swift
enum DictationSpan {
    static func base(existing: String, mode: DictationMode) -> String
    static func compose(base: String, dictated: String) -> String
}
```

Tests: empty field idea/chat → base == existing; non-empty note → base ends with `"\n\n"`; non-empty chat → single space; compose trims nothing from dictated; empty dictated → compose returns the original existing text (trailing separator removed).

- [ ] **Step 2: Run** — expect FAIL; **Step 3:** implement helper + button + sheet integration; **Step 4:** `swift test --filter Dictation && swift build`; expect PASS.

- [ ] **Step 5: Commit** — `git commit -m "feat(desktop): dictation button + idea create sheet integration"`.

---

### Task 7: Swift — Notes tab + ChatInput integration (Phase 2)

**Files:**
- Modify: `WatchtowerDesktop/Sources/Views/Calendar/RecordingDetailTabs.swift` (`RecordingNotesTab`, `:370-476`)
- Modify: `WatchtowerDesktop/Sources/Views/Chat/ChatInput.swift`
- Test: extend `WatchtowerDesktop/Tests/ChatInputViewTests.swift`

**Interfaces:**
- Consumes: `DictationButton` (Task 6), `@Environment(\.dictationCenter)` (nil-safe).

- [ ] **Step 1: Notes tab.** In `RecordingNotesTab`'s header row add `DictationButton(text: $draft, mode: .note, targetID: "notes.\(transcript.id)", isDisabled: isGenerating)`. Appending into `draft` rides the existing 800 ms debounced autosave (`scheduleSave`) for free; `isDisabled: isGenerating` honors the same lock as `.disabled(isGenerating)` on the editor — dictation must not route around the adoption guard.

- [ ] **Step 2: ChatInput.** Add two defaulted members so no call site breaks (the `placeholder` precedent, and Onboarding's trailing-closure form keeps compiling):

```swift
var dictationTargetID: String? = nil   // nil → no mic button
@Environment(\.dictationCenter) private var dictationCenter
```

In the trailing `HStack`, before the send button: `if let id = dictationTargetID, dictationCenter != nil { DictationButton(text: $text, mode: .chat, targetID: id) }`. The environment default is nil, so existing `ChatInputViewTests` and ViewInspector stay green (never `@Environment(AppState.self)` here — the TrayMenuView lesson).

- [ ] **Step 3: Pass `dictationTargetID` at the eight VM-bound call sites** (`ChatView.swift:186` → `"chat.workspace"`, `TargetChatView.swift:18` → `"chat.target.\(target.id)"`, `TargetDetailView.swift:750` → `"chat.target-assistant.\(target.id)"`, `SituationDiscussSection.swift:187` → `"chat.situation.\(situation.id)"`, `IdeaDiscussSection.swift:184` → `"chat.idea.\(idea.id)"`, `RecordingDetailTabs.swift:885` → `"chat.meeting.\(transcript.id)"`, both Settings assistant panels → `"chat.setup.email"` / `"chat.setup.calendar"`). Skip `OnboardingChatView` (onboarding runs before permissions/context are settled — deliberate).

- [ ] **Step 4: Extend `ChatInputViewTests`**: with `dictationTargetID` nil → no mic button in the hierarchy; with a target id but nil environment center → still no mic button.

- [ ] **Step 5: Run** — `swift test --filter ChatInputViewTests && swift build; echo "exit=$?"` — expect PASS.

- [ ] **Step 6: Commit** — `git commit -m "feat(desktop): dictation in notes editor and all discuss chats"`.

---

### Task 8: Swift — tray quick capture + Carbon global hotkey (Phase 3)

**Files:**
- Create: `WatchtowerDesktop/Sources/Views/QuickCapture/QuickCaptureView.swift`
- Create: `WatchtowerDesktop/Sources/App/GlobalHotKey.swift`
- Modify: `WatchtowerDesktop/Sources/App/WatchtowerApp.swift` (new `Window` scene)
- Modify: `WatchtowerDesktop/Sources/Views/TrayMenuView.swift` (new tray item)
- Modify: `WatchtowerDesktop/Sources/App/TrayAppDelegate.swift` (hotkey registration)
- Modify: `WatchtowerDesktop/Sources/App/AppState.swift` (`var openQuickCapture: (() -> Void)?`)
- Modify: `scripts/build-app.sh` (mic usage string reword)
- Test: `WatchtowerDesktop/Tests/QuickCaptureViewModelTests.swift`, extend `Tests/TrayMenuViewTests.swift`

**Interfaces:**
- Produces: tray item "New Voice Idea" + global hotkey ⌃⌥D → a small floating "Quick Capture" window that starts dictating immediately (mode `idea`); Stop → cleanup → inserts via `IdeaQueries.createManual` (existing manual path: `status='active'`, `source='owner'`, one `idea_mentions` provenance row) → confirmation state with "Open Ideas" button → auto-close.

- [ ] **Step 1: `QuickCaptureViewModel`** (`@MainActor @Observable`, lives IN the view file — it's screen-local, not an AppState center; the window closing cancels capture by design, and `DictationCenter` — which IS on AppState — owns everything long-running). API: `start(center:)`, `stop()`, `save(dbPool:)`; state `liveText`, `result: DictationCleanResult?`, `savedIdeaID: Int64?`, `error: String?`. `save` calls `IdeaQueries.createManual(db, kind: "idea", title: result.title ?? String(result.text.prefix(80)), essence: result.text)` in one `dbPool.write`. Write failing tests first: save happy path (rows in `ideas` + `idea_mentions` — use the existing test DB helper the IdeaQueries tests use), save with empty result → no insert + error set, title fallback when cleanup returned no title.

- [ ] **Step 2: `QuickCaptureView`** — compact VStack (recording indicator, live raw text in a scrolling `Text`, Stop/Cancel buttons, then result preview + Save/Discard, then "Saved ✓ — Open Ideas"). Uses `@Environment(\.dictationCenter)` + `@Environment(AppState.self)`. On appear: `viewModel.start(center:)` — dictation begins immediately, that's the point of quick capture.

- [ ] **Step 3: The scene + tray + hotkey.** New scene in `WatchtowerApp.swift` (after the progress window): `Window("Quick Capture", id: "quick-capture") { QuickCaptureView().environment(appState).environment(\.dictationCenter, appState.dictationCenter) }.windowResizability(.contentSize).defaultPosition(.topTrailing)` — the scene MUST self-inject both environments (the documented per-scene trap). Tray: one `Button("New Voice Idea", action: quickCaptureAction)` + injected closure on `TrayMenuContent` (NOT on `TrayMenuView` — ViewInspector rule), wired in `TrayMenuView` to `{ ActivationPolicyDecision.becomeRegularAndActivate(); appState.openQuickCapture?() }`; `rootContent.onAppear` sets `appState.openQuickCapture = { openWindow(id: "quick-capture") }` (capture `@Environment(\.openWindow)` there). Extend `TrayMenuViewTests` for the new item.

- [ ] **Step 4: `GlobalHotKey.swift`** — minimal Carbon wrapper, registered from `TrayAppDelegate.applicationDidFinishLaunching` (only when `managesLifecycle`):

```swift
import Carbon.HIToolbox

/// Global hotkey via Carbon RegisterEventHotKey — deliberately NOT an NSEvent
/// global monitor, which would require Accessibility permission (TCC prompt,
/// a P0 for this project). Carbon hotkeys need no permission.
@MainActor
final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let handler: () -> Void

    /// Default: Control+Option+D ("dictate").
    init(keyCode: UInt32 = UInt32(kVK_ANSI_D),
         modifiers: UInt32 = UInt32(controlKey | optionKey),
         handler: @escaping () -> Void)
    func register()
    func unregister()  // also called in deinit
}
```

Implementation: `InstallEventHandler` on `GetApplicationEventTarget()` for `kEventClassKeyboard`/`kEventHotKeyPressed`, `RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)`; the C callback trampolines to the Swift handler via `Unmanaged<GlobalHotKey>.fromOpaque(userData!)`. Handler body in the delegate: `AppState.shared.openQuickCapture?()` (activation policy handled by the window appearing). Registration failure (`OSStatus != noErr`, e.g. the combo is taken) → log and continue; the tray item still works.

- [ ] **Step 5: Reword the mic usage string** in `scripts/build-app.sh:170-173`: `NSMicrophoneUsageDescription` = "Watchtower uses the microphone to record your side of meetings and to take voice dictation, transcribed locally."

- [ ] **Step 6: Run** — `swift test --filter 'QuickCapture|TrayMenu' && swift build; echo "exit=$?"` — expect PASS.

- [ ] **Step 7: Commit** — `git commit -m "feat(desktop): tray quick-capture with global hotkey (Carbon, no TCC)"`.

---

### Task 9: Docs — app guide + CLAUDE.md feature note

**Files:**
- Modify: `docs/app-guide.md` (mic buttons in Ideas/Notes/chats, quick capture + hotkey — user-visible behavior only)
- Modify: `CLAUDE.md` (short feature note under Feature Notes: DictationCenter, sticky engine TTL, `dictate clean` + `dictation.clean`, the `captureWillStart` seam, Carbon-not-NSEvent rationale)

- [ ] **Step 1:** Write all three edits. **Step 2:** `go build ./... && go vet ./...` still green (docs only, sanity). **Step 3: Commit** — `git commit -m "docs: voice dictation app-guide and developer notes"`.

---

### Task 10: Quality gate → PR → green CI → merge

- [ ] **Step 1:** Run the **local-review** skill over the whole branch diff vs `origin/main` (it runs the CI mirror: gofmt + go vet + golangci-lint + go build + swift build/lint + affected tests, then the review panel; final-PR reviews use debate-review). Triage every finding critically; fix accepted ones with a commit per batch.
- [ ] **Step 2:** Push `feature/voice-dictation`, open the PR (gh CLI, push as the vadimtrunov account per project memory) with a summary referencing the spec, ending with the standard generated-with footer.
- [ ] **Step 3:** Watch CI; if red, fix (systematic-debugging rules; remember the dedupe-gate gotcha — "skipping" ≠ green; `workflow_dispatch` is the escape hatch).
- [ ] **Step 4:** Merge (owner pre-authorized: "доводи до PR, делай его зеленым и мержи").
