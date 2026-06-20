---
name: add-ai-prompt
description: Use when adding a new AI/LLM call, prompt template, or model-routing decision in the Watchtower Go backend — wiring a prompt that must work on BOTH the claude and codex providers, choosing a model tier (haiku/mini vs sonnet/gpt-5.4), or tagging a call site for routing.
---

# Add an AI Prompt (Watchtower)

Every AI call goes through the `digest.Generator` interface and MUST work on both providers (Claude CLI and Codex CLI) — the interface hides the difference. Never shell out to a CLI directly.

```go
type Generator interface {
    Generate(ctx context.Context, systemPrompt, userMessage, sessionID string) (string, *Usage, string, error)
}
```

## Steps

1. **Register the prompt ID + template** (if reusable / user-editable):
   - Constant in `internal/prompts/store.go` (e.g. `MyFeature = "my.feature"`).
   - Template const + `Defaults` map entry + `AllIDs` + `DefaultVersions` in `internal/prompts/defaults.go`. **Bump `DefaultVersions[id]`** whenever you edit a shipped template so user DBs auto-upgrade.
   - A pipeline-private prompt can instead live as a const in the package's `prompt.go` and be passed as the fallback to `getPrompt`.

2. **Pick the model tier** via the *source tag*, not a hardcoded model:
   - Lightweight (classify/prioritize/rollup) → route to Haiku / `gpt-5.4-mini`. Add your source name to the switch in BOTH `internal/digest/models.go` (`ModelForSource`) and `internal/codex/models.go`.
   - Quality-critical (summaries/analysis) → default (Sonnet / `gpt-5.4`), no change needed.

3. **Build and split the prompt**, then call the generator with a source-tagged context:
   ```go
   tmpl, version := p.getPrompt(prompts.MyFeature, fallbackTemplate)
   full := fmt.Sprintf(tmpl, args...)
   system, user := digest.SplitPromptAtData(full)            // splits at the data marker for prompt caching
   raw, usage, _, err := p.generator.Generate(
       digest.WithSource(ctx, "my.feature"), system, user, "") // source tag drives ModelForSource
   ```
   Pass `""` for sessionID — batch pipelines don't reuse sessions.

4. **Parse the response as JSON** into a typed struct. Both providers return the same normalized text, so no provider-specific branching.

5. **Test with a mock generator** (provider-agnostic — implement the one interface method):
   ```go
   type mockGen struct{ out string }
   func (m *mockGen) Generate(context.Context, string, string, string) (string, *digest.Usage, string, error) {
       return m.out, &digest.Usage{}, "", nil
   }
   ```
   Inject it into the pipeline. See `internal/catchup/pipeline_test.go` and `internal/digest/pipeline_test.go`.

## Gotchas

- **Codex never resumes sessions** — it returns an empty sessionID and runs `--ephemeral`. Don't persist/`--resume` a sessionID; keep any multi-turn state in your own DB.
- **No source tag = default model.** Forgetting `digest.WithSource` silently routes the call to Sonnet/`gpt-5.4` (costlier/slower for light tasks).
- **Both providers, always.** The factory (`cmd/generator.go`: `cliGenerator` / `cliPooledGenerator` / `newAIClient`) picks the provider from `cfg.AI.Provider`; `applyProviderOverride(cfg)` honors the `--provider` flag and MUST run before the generator is built.
- **`Provider` ≠ `Generator`.** `internal/ai/provider.go` (`Query`/`QuerySync`) is for interactive `ask`/`chat` (streaming, sessions). Batch pipelines use `digest.Generator`. Don't mix them.
- **Editing a shipped template without bumping its version** means existing users keep the old prompt from their DB.

## Reference files
- IDs/templates: `internal/prompts/store.go`, `internal/prompts/defaults.go`
- Generators: `internal/digest/generator.go` (Claude), `internal/codex/generator.go` (Codex), interface in `internal/digest/pipeline.go`
- Routing: `internal/digest/models.go`, `internal/codex/models.go`
- Factory/flags: `cmd/generator.go`, `cmd/root.go`
- Interactive provider: `internal/ai/provider.go`, `internal/ai/client.go`, `internal/codex/client.go`

When done, run `local-review` before opening a PR.
