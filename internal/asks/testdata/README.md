# internal/asks fixtures

Shared by the Go tests in this package and the Swift Core tests (read through `#filePath`).
Both sides must agree on every file.

- `cards/*.json` — a ```` ```watchtower-question ```` body (`{"questions": [...]}`). A
  `valid_*` file is accepted and an `invalid_*` file rejected, by `asks.Validate` (as the
  questions of a `question` ask) and by the Swift `ChatQuestionCard` decoder alike. Only
  rules both sides enforce belong here; Go-only bounds (label ≤ 80, description ≤ 300 runes)
  are unit-tested in Go.
- `answers/*.json` — `{kind, payload, answer, canonical | error}`. For `valid_*`, `answer`
  re-encoded with sorted keys and no whitespace equals `canonical` byte for byte (Go:
  `json.Marshal` of `asks.Answer`; Swift: `.sortedKeys` and `.withoutEscapingSlashes`).
  For `invalid_*`, `asks.ParseAnswer` then `asks.ValidateAnswer` fail with exactly `error`.
  The fixtures avoid `<`, `>`, `&`, `/`, U+2028 and U+2029, which the two encoders escape
  differently.
- `render/<answers fixture>.txt` — `asks.Render` of each valid answers fixture
  (`go test ./internal/asks -run TestRenderGolden -update` rewrites them).
- `lines/*.json` — `{id, kind, answer, line}`: `asks.DeliveryLine` and the Swift
  `OwnerAskPrompt` both produce `line`.
