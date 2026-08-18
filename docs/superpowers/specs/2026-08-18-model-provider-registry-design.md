# Model & Provider Registry — Design

**Date:** 2026-08-18
**Status:** approved (owner picked "variant B" — registry; model-per-tier; aliases + free input; Discuss chats ride the strong tier without pickers)

## Problem

The model a pipeline actually uses is hardcoded and the Settings UI is decorative:

- `internal/digest/models.go` pins `claude-haiku-4-5-20251001` / `claude-sonnet-4-6`; `internal/codex/models.go` pins `gpt-5.4` / `gpt-5.4-mini`. When a call carries a source tag (every pipeline does), `ModelForSource` **overrides** the user-configured `ai.model` (`internal/digest/generator.go` `Generate`), so the Settings model field only affects untagged calls.
- The ~17-entry source→tier switch is duplicated byte-for-byte between `internal/digest/models.go` and `internal/codex/models.go`.
- Desktop chat models are a hardcoded Swift enum (`ChatModel` in `ChatViewModel.swift`) used by the main AI Chat picker and all four Discuss chat VMs. New model releases require an app release.
- No local/self-hosted provider. A stale unmerged branch `feature/ollama-provider` (`b9d06d1d`, based on 2026-05 main) already implements an OpenAI-compatible client+generator; it is ported, not merged.

## Goals

1. User-configured models win over code constants, per tier (light/strong).
2. New models appear without an app release: Claude defaults become CLI **aliases** (`haiku`, `sonnet`) that track the newest versions; every model field is free-input with validation; Ollama models are listed live from the server.
3. Third provider `ollama` — OpenAI-compatible HTTP (`/v1/chat/completions`), covering Ollama, LM Studio, vLLM, corporate gateways.
4. One source of truth for the Desktop UI: no model lists in Swift.

## Non-goals (v1)

Mixing providers across tiers; per-pipeline model overrides (`targets.extract.model` stays as-is); a remote curated catalog; changing when the daemon picks up config (still on restart).

## Design

### 1. Go: registry + tier unification

- New package `internal/providers`: a static registry of provider metadata — `ID` (`claude`/`codex`/`ollama`), display name, kind (`cli`/`http`), default model per tier, whether live model listing is supported. Claude defaults: light=`haiku`, strong=`sonnet` (aliases). Codex: light=`gpt-5.4-mini`, strong=`gpt-5.4`. Ollama: both tiers default to the single configured Ollama model.
- The duplicated source switch collapses into one `digest.TierForSource(source) Tier` (`TierLight`/`TierStrong`); `digest` already owns the source-tag contract (`SourceLight`, `WithSource`).
- Generators (`digest.ClaudeGenerator`, `codex.Generator`, new `ollama.Generator`) carry `modelLight`/`modelStrong` fields resolved at construction (config value if set, else registry default). `Generate` maps source→tier→field. Constructors keep a single-model signature variant for compatibility where needed, but `cmd` wiring passes both tiers.

### 2. Config

- New keys: `ai.models.light`, `ai.models.strong` (empty → registry default for the active provider), `ai.ollama_url` (default `http://localhost:11434`).
- Legacy `ai.model` is read as `ai.models.strong` when the new key is unset — an install that deliberately pinned a model keeps it. Exception: a legacy value equal to the retired `claude-sonnet-4-6` default is treated as unset for every provider — setup used to seed that literal into each config.yaml, so it means "never chose a model"; honoring it would pin every existing install to an aging model and defeat the aliases. Setup stops seeding `ai.model`.
- `ai.provider` accepts `ollama` alongside `claude`/`codex`.

### 3. Ollama provider (port of `b9d06d1d`)

- `internal/ollama/{client,generator}.go` ported onto current `ai.Provider` / `digest.Generator` interfaces, with tier fields. OpenAI-compatible chat completions; no session concept (empty session ID).
- Model discovery via the standard `GET /v1/models` (not Ollama's `/api/tags`), so any compatible server works.

### 4. CLI door: `watchtower ai models --json`

New `ai` command group. `models` prints the registry: each provider's id, display name, default tier models, the currently resolved light/strong models for the configured provider, and — for Ollama — the live model list from `/v1/models`. An unreachable server yields an empty list plus an `error` string, never a non-zero exit for the whole command.

### 5. Desktop

- `ConfigService`: round-trip `ai.models.light`, `ai.models.strong`, `ai.ollama_url`.
- Settings → System → AI: provider picker gains Ollama; the single model field becomes **two** fields (Light / Strong), each a free-text field with a suggestions menu fed by `watchtower ai models --json` (cached per Settings open by a small `AIModelCatalog` service). Ollama selected → URL field appears; Test Connection gains an Ollama branch (direct HTTP chat call via URLSession).
- `ChatModel` enum dies. Main AI Chat builds its picker from `AIModelCatalog` (falls back to resolved defaults when the CLI call fails). The four Discuss chat VMs (Situation/Target/Meeting/Idea) use the resolved strong-tier model — no pickers (owner decision).

### 6. Testing

- Go: tier resolution (config override wins; empty falls back to registry default; per provider), unified `TierForSource` keeps the exact source list, `ollama` generator + `/v1/models` via `httptest` (one mux per server — Go 1.25 duplicate-HandleFunc panic), `ai models --json` output shape, legacy `ai.model` → strong mapping.
- Swift: `ConfigService` yaml round-trip for the new keys; `AIModelCatalog` JSON parsing; Discuss VM model resolution from config (Tests/Core where possible).

## Error handling

- Ollama HTTP errors surface as generator errors like any CLI failure (pipelines already tolerate per-call failures).
- `ai models` degrades gracefully on a dead Ollama server (empty list + error field).
- Model validation stays where it is: `validateModel` in `cmd` remains a no-op (new model IDs must not be rejected by stale allowlists); the Settings Test Connection button is the explicit validation path.
