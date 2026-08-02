# Multi-Provider AI Support: Architecture Design

## Overview

Adding Codex CLI as a full-fledged AI provider alongside Claude CLI.
Switching happens via config. The Claude path remains untouched.

---

## Go Backend

### 1. New package `internal/codex/`

#### `resolve.go` — binary discovery (analogous to `internal/claude/resolve.go`):
- `FindBinary(override string) string` — looks up the `codex` binary (PATH → login shell → fallback dirs)
- `RichPATH() string` — enriched PATH for the subprocess
- Caching via `sync.Once`

#### `generator.go` — CodexGenerator implements `digest.Generator`:
```go
type CodexGenerator struct {
    model     string
    codexPath string
}
func NewCodexGenerator(model, codexPath string) *CodexGenerator
func (g *CodexGenerator) Generate(ctx context.Context, systemPrompt, userMessage, sessionID string) (string, *digest.Usage, string, error)
```

CLI invocation:
```
codex exec \
  --model <model> \
  --json \
  -c approval_policy=never \
  -c sandbox_mode=read-only \
  -c developer_instructions="<systemPrompt>" \
  "<userMessage>"
```

Key points:
- System prompt via `-c developer_instructions="..."` (NOT concatenated into userMessage)
- `--json` → JSONL output
- `--ephemeral` to disable sessions

#### `client.go` — CodexClient for streaming (ask/chat):
```go
type Client struct {
    model    string
    dbPath   string
    codexCmd string
}
func NewClient(model, dbPath, codexPath string) *Client
func (c *Client) Query(ctx context.Context, systemPrompt, userMessage, sessionID string) (<-chan string, <-chan error, <-chan string)
func (c *Client) QuerySync(ctx context.Context, systemPrompt, userMessage, sessionID string) (string, *ai.Usage, error)
```

#### `models.go` — Codex models:
```go
const (
    ModelDefault     = "gpt-5.4"        // analog of Sonnet
    ModelLightweight = "gpt-5.4-mini"   // analog of Haiku
)
func ModelForSource(source string) string // same mapping as digest.ModelForSource
```

#### `parse.go` — JSONL event parsing:
```go
type CodexEvent struct {
    Type     string      `json:"type"`      // thread.started, turn.started, turn.completed, item.started, item.completed, error
    ThreadID string      `json:"thread_id"`
    Item     *CodexItem  `json:"item"`
    Usage    *CodexUsage `json:"usage"`
    Error    *CodexError `json:"error"`
}
type CodexItem struct {
    ID      string `json:"id"`
    Type    string `json:"type"`    // agent_message, command_execution, mcp_tool_call
    Content string `json:"content"`
}
type CodexUsage struct {
    InputTokens  int `json:"input_tokens"`
    OutputTokens int `json:"output_tokens"`
}
type CodexError struct {
    Message string `json:"message"`
}
```

Result extraction: the last `item.completed` event with `item.type == "agent_message"` contains the final answer.

#### `mcp.go` — MCP configuration for Codex:
- Create a temp directory with `.codex/config.toml` containing the MCP config for SQLite
- Use `--cd` to point at this directory
- Cleanup in defer

`.codex/config.toml` format:
```toml
[mcp_servers.sqlite]
command = "npx"
args = ["-y", "@anthropic-ai/mcp-server-sqlite", "<dbPath>"]
```

### 2. `ai.Provider` interface

New file `internal/ai/provider.go`:
```go
type Provider interface {
    Query(ctx context.Context, systemPrompt, userMessage, sessionID string) (<-chan string, <-chan error, <-chan string)
    QuerySync(ctx context.Context, systemPrompt, userMessage, sessionID string) (string, *Usage, error)
}
```

`ai.Client` (Claude) already satisfies the signatures. `codex.Client` — new implementation.

### 3. Configuration

`internal/config/config.go` — add:
```go
// In AIConfig:
Provider string `mapstructure:"provider"` // "claude" (default) | "codex"

// In Config (root level, next to ClaudePath):
CodexPath string `mapstructure:"codex_path"`
```

`internal/config/defaults.go`:
```go
const DefaultAIProvider = "claude"
```

### 4. Factory functions

`cmd/generator.go`:
```go
func cliGenerator(cfg *config.Config) digest.Generator {
    if cfg.AI.Provider == "codex" {
        return codex.NewCodexGenerator(codex.ModelDefault, cfg.CodexPath)
    }
    return digest.NewClaudeGenerator(digest.ModelSonnet, cfg.ClaudePath)
}
```

`cmd/ask.go` — `newAIClient(cfg, dbPath) ai.Provider`

### 5. CLI flag

`cmd/root.go` — persistent flag `--provider` (claude|codex), override cfg.AI.Provider.

### 6. Go files (scope for Go Dev):
1. `internal/codex/resolve.go` — new
2. `internal/codex/models.go` — new
3. `internal/codex/generator.go` — new
4. `internal/codex/client.go` — new
5. `internal/codex/mcp.go` — new
6. `internal/codex/parse.go` — new
7. `internal/ai/provider.go` — new
8. `internal/config/config.go` — change
9. `internal/config/defaults.go` — change
10. `cmd/generator.go` — change
11. `cmd/ask.go` — change
12. `cmd/root.go` — change

---

## Swift Desktop

### 1. CodexService.swift — new service

Rename `ClaudeServiceProtocol` → `AIServiceProtocol`. Update:
- Protocol declaration
- `ClaudeService: AIServiceProtocol`
- `CodexService: AIServiceProtocol`
- All references in ViewModels and DI

```swift
final class CodexService: AIServiceProtocol, Sendable {
    func stream(
        prompt: String,
        systemPrompt: String?,
        sessionID: String?,
        dbPath: String?,
        model: String?,
        extraAllowedTools: [String]
    ) -> AsyncThrowingStream<StreamEvent, Error>
}
```

CLI invocation:
```
codex exec \
  --model <model> \
  --json \
  -c approval_policy=never \
  -c sandbox_mode=read-only \
  -c developer_instructions="<systemPrompt>" \
  --cd <workingDir> \
  "<prompt>"
```

Key points:
- System prompt via `-c developer_instructions="..."` (NOT concatenation)
- `--json` → JSONL output, parsed line by line
- `item.completed` + `type == "agent_message"` → `.turnComplete(content)`
- Streaming deltas via `item.started` → `.text(delta)`
- `turn.completed` → can be ignored
- End of process → `.done`

MCP for SQLite: create a temp `.codex/config.toml`:
```toml
[mcp_servers.sqlite]
command = "npx"
args = ["-y", "@anthropic-ai/mcp-server-sqlite", "<dbPath>"]
```
Write to the temp dir, use `--cd`.

Binary discovery: `Constants.findCodexPath()` — analog of `findClaudePath()`.

### 2. ConfigService.swift — provider in settings

New fields:
```swift
var aiProvider: String?  // "claude" | "codex", default "claude"
var codexPath: String?
```

In `reload()`: read from yaml `ai.provider` and `codex_path`.
In `save()`: save back.

### 3. ChatViewModel.swift — models and provider

```swift
enum AIProvider: String, CaseIterable, Identifiable {
    case claude
    case codex
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }
}

enum ChatModel: String, CaseIterable, Identifiable {
    // Claude
    case sonnet = "claude-sonnet-4-6"
    case haiku = "claude-haiku-4-5-20251001"
    case opus = "claude-opus-4-6"
    // Codex
    case gpt54 = "gpt-5.4"
    case gpt54mini = "gpt-5.4-mini"
    case gpt53codex = "gpt-5.3-codex"

    var provider: AIProvider { ... }
    var displayName: String { ... }

    static func models(for provider: AIProvider) -> [ChatModel] {
        allCases.filter { $0.provider == provider }
    }
}
```

ChatView: picker shows only models of the current provider.

On provider switch:
```swift
let service: any AIServiceProtocol = switch provider {
    case .claude: ClaudeService()
    case .codex: CodexService()
}
```

### 4. Settings UI

In Settings → AI section:
- **Provider picker**: `Picker("AI Provider", selection: $configService.aiProvider)` — Claude / Codex
- **Codex Path**: text field, shown only when provider == codex
- Model picker: filtered by the current provider

### 5. JSONL parsing (Codex events)

```swift
struct CodexEvent: Decodable {
    let type: String
    let threadId: String?
    let item: CodexItem?
    let usage: CodexUsage?
    let error: CodexError?
}
struct CodexItem: Decodable {
    let id: String
    let type: String
    let content: String?
}
struct CodexUsage: Decodable {
    let inputTokens: Int
    let outputTokens: Int
}
struct CodexError: Decodable {
    let message: String
}
```

### 6. Swift files (scope for Swift Dev):
1. `WatchtowerDesktop/Sources/Services/CodexService.swift` — new
2. `WatchtowerDesktop/Sources/Services/ClaudeService.swift` — rename protocol → AIServiceProtocol
3. `WatchtowerDesktop/Sources/Services/Constants.swift` — findCodexPath()
4. `WatchtowerDesktop/Sources/Services/ConfigService.swift` — aiProvider, codexPath
5. `WatchtowerDesktop/Sources/ViewModels/ChatViewModel.swift` — ChatModel extension, AIProvider enum
6. `WatchtowerDesktop/Sources/Views/SettingsView.swift` — provider picker

---

## Config YAML format (Go ↔ Swift contract)

```yaml
ai:
  provider: "codex"        # string: "claude" | "codex", default "claude"
  model: "gpt-5.4"         # string: model of the current provider
  workers: 5               # int
codex_path: "/usr/local/bin/codex"  # string, optional
claude_path: ""                      # string, optional (already exists)
```

## Codex JSONL event types (for parsing in both clients)

- `thread.started` → `thread_id: string`
- `turn.started` → (no payload)
- `item.completed` → `item.id: string, item.type: string, item.content: string`
- `turn.completed` → `usage.input_tokens: int, usage.output_tokens: int`
- `error` → `error.message: string`

Go types: `int` for tokens, `string` for IDs and content.
Swift types: `Int` for tokens, `String` for IDs and content.
