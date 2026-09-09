# Quick Connections — Close v1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the just-merged Quick Connections feature an honest, finished v1 — pin the http-transport config shape with a test, stop codex/ollama from silently pretending an external connection works, and turn the raw-JSON add-sheet into a usable structured editor.

**Architecture:** Three small, additive slices on top of the merged feature. Nothing native changes; QC-01/02/03 contracts hold. Go: one characterization test + one CLI warning path. Swift: a provider-notice caption + a kind-adaptive secret editor and quote-aware args tokenizer, both driven by pure Core helpers so they unit-test without the ML stack.

**Tech Stack:** Go 1.25 (cobra CLI, `internal/ai`, `internal/externalmcp`), SwiftUI + GRDB (WatchtowerCore + WatchtowerDesktop).

**Spec:** Feature spec `docs/superpowers/specs/2026-09-09-quick-connections-external-mcp-design.md` + contracts `docs/inventory/quick-connections.md` (QC-01..03). This plan argues from those; it introduces no new numbered contract.

## Global Constraints

- **QC-01 (native untouched):** with zero external connections the mcp-config + allowlist stay byte-identical. Do NOT modify `buildMCPConfig`'s `watchtower` entry or the zero-connection path. `TestBuildMCPConfig_ZeroExternalUnchanged` must stay green untouched.
- **QC-02 (read-only):** add no write path; do not make an external connection reachable by `internal/tools` `Registry`.
- **QC-03 (secrets never on argv):** the secret travels via stdin only. Any new secret-editor code builds JSON in Swift and pipes it through the existing `--secret-stdin` path; never add a secret to an argv token.
- **Repo is English:** all code, comments, test names, and user-facing strings in English.
- **Inner-loop tests:** Go — `go test ./internal/ai/` / `./cmd/`. Swift Core — `cd WatchtowerDesktop && swift test --filter <Class>` (Core tests build without the ML stack; keep new pure helpers + their tests in `WatchtowerCore` / `Tests/Core`).
- Do not relax or rename any existing guard test.

---

### Task 1: Pin the http-transport config shape (Go)

Characterization/guard test. `externalServerConfig` already emits the correct http shape (`internal/ai/client.go:288-307`); nothing tests the http branch, so owner-notice #3's shape is asserted only by the source. This test locks it. It passes on first run by design (it pins existing behavior) — that is the point of a characterization guard, not a red-green cycle.

**Files:**
- Test: `internal/ai/client_test.go` — add `TestBuildMCPConfig_HTTPServerShape` immediately after `TestBuildMCPConfig_MergesExternalServers` (~L518), reusing that test's parsed-anonymous-struct pattern (L497-503).

**Interfaces:**
- Consumes: `Client.SetExternalMCPServers([]ExternalMCPServer)` and `buildMCPConfig()` (`internal/ai/client.go:117`, 258-307). `ExternalMCPServer` fields: `Name/Kind/Command/Args/URL/Env/Headers` (L81-89).
- Produces: nothing (test only).

- [ ] **Step 1: Write the guard test**

Mirror `TestBuildMCPConfig_MergesExternalServers`. Configure ONE http server with a URL and a non-empty `Headers` map, build the config, JSON-decode `mcpServers[name]` into an anonymous struct with `Type string \`json:"type"\``, `URL string \`json:"url"\``, `Headers map[string]string \`json:"headers"\``, and pointer/optional `Command *string \`json:"command"\``. Assert:
- `Type == "http"`, `URL == <given>`, `Headers` equals the given map.
- `Command == nil` (no stdio keys leak into an http entry).
- The allowlist contains `mcp__<name>` (reuse the `buildArgs`/allowlist accessor the sibling tests use).

Add a second sub-case (or a second test `TestBuildMCPConfig_HTTPServerOmitsEmptyHeaders`) asserting that with an empty `Headers` map the emitted object has NO `headers` key (decode into a `map[string]json.RawMessage` and assert `_, ok := m["headers"]; !ok`).

- [ ] **Step 2: Run — confirm it passes (pins current behavior)**

Run: `go test ./internal/ai/ -run TestBuildMCPConfig_HTTP -v`
Expected: PASS. If it FAILS, the emitted http shape differs from `{"type":"http","url":...,"headers":...}` — STOP and report; that would be a real bug in `externalServerConfig`, not a test to bend.

- [ ] **Step 3: Commit**

```bash
git add internal/ai/client_test.go
git commit -m "test(ai): pin external http MCP server config shape ({type,url,headers})"
```

---

### Task 2: Provider-honesty warning in the CLI (Go)

codex chats get the base MCP subprocess but drop external connections (`codex.Client` doesn't implement `externalMCPConfigurable`); ollama tool-mode chats route through runtime B and never wire them. So under a non-claude configured provider an enabled connection is inert — but `connections enable`/`add` say nothing. Emit a stderr warning so "enabled" isn't a silent lie. (Behavior unchanged otherwise; the connection still enables/creates.)

**Files:**
- Modify: `cmd/connections.go` — `runConnectionsEnable`/`setConnectionEnabled` (L272-301) and the add path (`runConnectionsAdd`). `cfg` (loaded `*config.Config`) is already in scope in `openConnectionsCmdDB` (L280-289) — currently discarded via `_`; keep it and read `cfg.AI.ConfiguredProviderID()`.
- Test: `cmd/connections_test.go` (add cases; if the file does not exist, create it following the nearest existing `cmd/*_test.go` cobra-command test — resolve by grepping `cmd/*_test.go` for how a command is invoked with a captured `ErrOrStderr()` buffer and an isolated temp DB/config).

**Interfaces:**
- Consumes: `config.AIConfig.ConfiguredProviderID()` (`internal/config/config.go:35-53`, the frozen at-Load provider), `db.SetExternalConnectionEnabled`, `db.InsertExternalConnection`.
- Produces: a reusable helper `warnIfProviderIgnoresConnections(w io.Writer, cfg *config.Config)` in `cmd/connections.go` that writes the warning to `w` when `cfg.AI.ConfiguredProviderID() != "claude"` and nothing otherwise. Both `enable` and `add` call it with `cmd.ErrOrStderr()`.

- [ ] **Step 1: Write the failing test**

In `cmd/connections_test.go`, table test `TestConnectionsEnable_WarnsUnderNonClaudeProvider`:
- Given a config whose configured provider is `ollama`, running `connections enable <id>` on an existing row writes to stderr a message containing `only` and `claude` and the connection name, AND the row ends enabled (assert via `db.GetExternalConnection`).
- Given configured provider `claude`, the same run writes NOTHING to stderr.
Mirror the same two cases for `connections add` (`TestConnectionsAdd_WarnsUnderNonClaudeProvider`) — non-claude ⇒ warning + row created disabled; claude ⇒ no warning.

- [ ] **Step 2: Run to verify it fails**

Run: `go test ./cmd/ -run TestConnections.*WarnsUnderNonClaudeProvider -v`
Expected: FAIL (no warning emitted yet).

- [ ] **Step 3: Implement**

Add:
```go
// warnIfProviderIgnoresConnections tells the owner that Quick Connections are
// wired only for the claude provider, so an enabled connection is inert under
// codex/ollama. Non-fatal: the enable/add still succeeds.
func warnIfProviderIgnoresConnections(w io.Writer, cfg *config.Config, name string) {
	if p := cfg.AI.ConfiguredProviderID(); p != "claude" {
		fmt.Fprintf(w, "warning: Quick Connections work only with the claude AI provider; connection %q will be inert under provider %q\n", name, p)
	}
}
```
Call it from `runConnectionsEnable` (after a successful enable, resolving the connection name via `db.GetExternalConnection`) and from `runConnectionsAdd` (after insert), both with `cmd.ErrOrStderr()`. Follow the existing `fmt.Fprintf(cmd.ErrOrStderr(), "warning: ...")` precedent at L317-318.

- [ ] **Step 4: Run to verify it passes**

Run: `go test ./cmd/ -run TestConnections -v`
Expected: PASS (new + existing connections tests).

- [ ] **Step 5: Commit**

```bash
git add cmd/connections.go cmd/connections_test.go
git commit -m "feat(connections): warn on enable/add when the configured provider ignores external connections"
```

---

### Task 3: Desktop provider-honesty caption (Swift)

Mirror Task 2 in the app: when the current AI provider is not claude, the Quick Connections card shows a caption that these connections work only with claude. Decision is a pure Core helper (unit-tested without the ML stack); the view renders it.

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Logic/QuickConnectionsProviderNotice.swift` (pure).
- Create: `WatchtowerDesktop/Tests/Core/QuickConnectionsProviderNoticeTests.swift`.
- Modify: `WatchtowerDesktop/Sources/Views/Settings/QuickConnectionsDetail.swift` (render the caption at the top of the card) and/or `AddExternalConnectionView.swift`. Read the current provider from the existing AppState-cached `AIModelCatalog` — resolve the exact provider-read call site by grepping `AIModelCatalog` usages under `Sources/Views/Settings/` (Settings→System→AI already renders provider-aware UI from it; reuse that accessor). If AppState exposes no simple provider string, thread the catalog's resolved provider into the view the same way the AI settings screen does.

**Interfaces:**
- Consumes: the app's resolved AI provider id string (`"claude"` / `"codex"` / `"ollama"` / empty).
- Produces: `enum QuickConnectionsProviderNotice { static func caption(forProvider provider: String?) -> String? }` — returns `nil` for `"claude"`, and a non-nil English caption for any other/empty provider.

- [ ] **Step 1: Write the failing Core test**

`QuickConnectionsProviderNoticeTests`: `caption(forProvider: "claude")` is `nil`; `caption(forProvider: "ollama")` and `caption(forProvider: "codex")` are non-nil and contain "claude"; `caption(forProvider: nil)` is non-nil (unknown ⇒ warn, honest default).

- [ ] **Step 2: Run to verify it fails**

Run: `cd WatchtowerDesktop && swift test --filter QuickConnectionsProviderNoticeTests`
Expected: FAIL (type does not exist).

- [ ] **Step 3: Implement the helper**

```swift
public enum QuickConnectionsProviderNotice {
    /// Nil when the provider is claude (connections fully work); otherwise a
    /// caption telling the owner Quick Connections are claude-only today.
    public static func caption(forProvider provider: String?) -> String? {
        guard provider == "claude" else {
            return "Quick Connections currently work only with the claude AI provider. "
                 + "Enabled connections are inert under the current provider."
        }
        return nil
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd WatchtowerDesktop && swift test --filter QuickConnectionsProviderNoticeTests`
Expected: PASS.

- [ ] **Step 5: Render the caption**

In `QuickConnectionsDetail.swift`, when `QuickConnectionsProviderNotice.caption(forProvider: <resolved provider>)` is non-nil, show it as a `.font(.caption).foregroundStyle(.secondary)` (or a warning-tinted) row at the top of the card. Keep it a read of the already-cached provider — no new fetch.

- [ ] **Step 6: Build + targeted UI test if present; commit**

Run: `make test-swift FILTER=QuickConnectionsProviderNoticeTests`
```bash
git add WatchtowerDesktop/Sources/WatchtowerCore/Logic/QuickConnectionsProviderNotice.swift WatchtowerDesktop/Tests/Core/QuickConnectionsProviderNoticeTests.swift WatchtowerDesktop/Sources/Views/Settings/QuickConnectionsDetail.swift
git commit -m "feat(desktop): caption Quick Connections as claude-only when provider differs"
```

---

### Task 4: Add-sheet polish — structured secret editor + quote-aware args (Swift)

Replace the raw-JSON secret field with a kind-adaptive key/value editor (Env rows for stdio, Headers rows for http) and the naive `split(" ")` args parse with a quote-aware tokenizer. Both are driven by pure Core helpers so they unit-test without the ML stack. Secret still leaves via stdin (QC-03).

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Logic/ExternalConnectionInput.swift` — two pure helpers:
  - `ExternalConnectionSecretBuilder.json(kind:pairs:) -> String?` — given `kind` (`"stdio"`/`"http"`) and an array of (key, value) pairs (empty-key/empty rows dropped), returns the JSON string `{"env":{...}}` for stdio or `{"headers":{...}}` for http, or `nil` when no non-empty pairs (⇒ no `--secret-stdin`). Field names must match Go `Secret` (`env`/`headers`, `internal/externalmcp/secret_store.go:13-16`).
  - `CommandArgsTokenizer.tokenize(_ text:) -> [String]` — shell-like split honoring single and double quotes so a quoted path with a space is one arg; unquoted runs split on whitespace; trailing/leading whitespace ignored.
- Create: `WatchtowerDesktop/Tests/Core/ExternalConnectionInputTests.swift`.
- Modify: `AddExternalConnectionView.swift` (replace `secretJSON` TextField L72 + `argsText` split L113 with the structured editor + tokenizer; drop the raw-JSON caption L74-76), and `ExternalConnectionsViewModel.swift` if the add signature needs the pre-built JSON string instead of raw text (keep passing the built JSON to the existing stdin path L98-105 — do NOT change how stdin is piped).

**Interfaces:**
- Consumes: the selected `kind` picker value already in the sheet; the existing `vm.addConnection(...)` stdin path.
- Produces: the two Core helpers above (pure, testable).

- [ ] **Step 1: Write the failing Core tests**

`ExternalConnectionInputTests`:
- `CommandArgsTokenizer.tokenize`: `"a b c"` → `["a","b","c"]`; `"--path \"/a b/c\" --x"` → `["--path","/a b/c","--x"]`; `"'single quoted'"` → `["single quoted"]`; `"  spaced   out  "` → `["spaced","out"]`; `""` → `[]`.
- `ExternalConnectionSecretBuilder.json`: `kind:"http", pairs:[("Authorization","Bearer x")]` → `{"headers":{"Authorization":"Bearer x"}}` (decode + compare, don't string-match key order); `kind:"stdio", pairs:[("TOKEN","t")]` → `{"env":{"TOKEN":"t"}}`; empty/whitespace-only rows dropped; all-empty ⇒ `nil`.

- [ ] **Step 2: Run to verify they fail**

Run: `cd WatchtowerDesktop && swift test --filter ExternalConnectionInputTests`
Expected: FAIL (types do not exist).

- [ ] **Step 3: Implement the helpers**

Write `ExternalConnectionSecretBuilder.json` (build a `[String:String]` from non-empty pairs, wrap under `env`/`headers` by kind, `JSONEncoder` with `.sortedKeys` for determinism, return `nil` if the inner map is empty) and `CommandArgsTokenizer.tokenize` (a small state machine over characters: track in-single-quote/in-double-quote, accumulate current token, flush on unquoted whitespace).

- [ ] **Step 4: Run to verify they pass**

Run: `cd WatchtowerDesktop && swift test --filter ExternalConnectionInputTests`
Expected: PASS.

- [ ] **Step 5: Wire the sheet**

In `AddExternalConnectionView.swift`: replace the args field's parse with `CommandArgsTokenizer.tokenize(argsText)`. Replace the raw-JSON secret field with a small dynamic list of key/value rows plus an "Add row" button; label the section "Environment variables" when `kind == "stdio"` and "Headers" when `kind == "http"`. On submit, build the secret via `ExternalConnectionSecretBuilder.json(kind:pairs:)` and pass that string (or nil) into the existing `vm.addConnection` stdin path — unchanged transport. Keep a stdio security note if one already exists.

- [ ] **Step 6: Build the Desktop target + commit**

Run: `make test-swift FILTER=ExternalConnectionInputTests` (and a local build of the app target to confirm the view compiles).
```bash
git add WatchtowerDesktop/Sources/WatchtowerCore/Logic/ExternalConnectionInput.swift WatchtowerDesktop/Tests/Core/ExternalConnectionInputTests.swift WatchtowerDesktop/Sources/Views/Settings/AddExternalConnectionView.swift WatchtowerDesktop/Sources/ViewModels/ExternalConnectionsViewModel.swift
git commit -m "feat(desktop): structured kind-adaptive secret editor + quote-aware args in add-connection sheet"
```

---

## Self-review

- **Spec coverage:** owner-notice #3 (http shape) → Task 1; codex/ollama silent-ignore honesty → Tasks 2+3; deferred add-sheet polish (key/value editor, args quoting, secret-shape-vs-kind) → Task 4. All three "A" items covered.
- **Contracts:** QC-01 path untouched (no edits to zero-connection/`watchtower` entry); QC-02 no write path added; QC-03 secret still stdin-only (Task 4 builds JSON in Swift, pipes via existing `--secret-stdin`). No new numbered contract.
- **Type consistency:** Go `Secret` field names `env`/`headers` reused verbatim by the Swift builder (Task 4). `ConfiguredProviderID()` is the frozen provider both CLI (Task 2) and the caption logic (Task 3) key on.
- **No placeholders:** every task has concrete code or an explicit, grep-resolvable lookup (test-file location, `AIModelCatalog` provider accessor) with the resolution rule stated.
