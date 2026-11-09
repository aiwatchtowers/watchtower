# Contributing to Watchtower

Thanks for your interest. Watchtower is a macOS app (SwiftUI) with a Go CLI and
background daemon behind it. Bug reports, fixes and focused improvements are
welcome.

## Before you start

- For anything bigger than a small fix, open an issue first so we can agree on
  the shape before you write code.
- Search existing issues before filing a new one.
- Security problems go through private reporting, not issues: see
  [SECURITY.md](SECURITY.md).

## Requirements

- macOS 14 or later, Apple Silicon
- Go 1.26+
- A Swift 6+ toolchain (Xcode 16+)
- An AI provider to run the app: Claude Code, the Codex CLI, or a local
  Ollama-compatible server

The Go side builds an in-repo SQLCipher engine with cgo, so `CGO_ENABLED=0`
does not build. The first `go test` after a clean cache compiles it (about 30 s).

## Build

```bash
git clone https://github.com/aiwatchtowers/watchtower.git
cd watchtower
make hooks       # once per clone: installs the leak-check pre-push hook
make app-dev     # fast dev build of the CLI and the desktop app
make build       # Go CLI only
```

`make app` is the full release build. The README explains building while the
app is running.

## Test

Run the narrow checks while you iterate and the full ones before you open a PR.

While iterating:

```bash
go test ./internal/<pkg>                  # only the package you touched
go test ./internal/<pkg> -run TestName    # narrower still
make test-swift FILTER=<TestClass>        # Desktop tests, always filtered
make kit-test FILTER=<TestClass>          # WatchtowerKit (shared mobile package)
make lint-diff                            # Go lint issues new versus origin/main
make lint-swift                           # Swift lint (lint-diff checks Go only)
```

Before a PR:

```bash
make test        # full Go suite
make test-swift  # full Swift suite, Desktop and Kit
make lint-all    # Go, Desktop, Kit and phone lint
```

With iPhone app changes, also run `make mobile-test`. Please do not delete
`WatchtowerDesktop/.build`: a cold rebuild of the ML dependencies takes minutes.

## Where things live

| Path | What |
| --- | --- |
| `cmd/`, `internal/` | Go CLI, daemon and pipelines |
| `WatchtowerDesktop/` | macOS app (SwiftUI, GRDB) |
| `WatchtowerKit/`, `WatchtowerMobile/` | shared Swift package and the iPhone app |
| `internal/db/migrations/` | goose SQL migrations |
| `docs/guide/` | the user guide, starting at [docs/guide/README.md](docs/guide/README.md) |
| `docs/features/` | developer notes per feature: architecture, contracts, limits |
| `docs/inventory/` | behavior contracts guarded by tests |
| `docs/review/review-rules.md` | review rules, including Swift / Desktop conventions |
| `docs/design/desktop-style-guide.md` | style guide for new Desktop screens |

Read the relevant `docs/features/` note before changing an area.
[CLAUDE.md](CLAUDE.md) is the full developer index (it also guides AI coding
agents working in this repo).

### Behavior contracts

`docs/inventory/` lists behaviors that must not change without the
maintainers' approval, each backed by a guard test named `Test<Module>NN_…`.
If your change would weaken or break one, say so in the issue or PR and wait
for a decision. Do not relax, rename or split a guard test to make it pass.

### Schema changes

Add a new numbered goose migration in `internal/db/migrations/`, mirror it in
`internal/db/schema.sql`, and regenerate the snapshots:

```bash
go test ./internal/db/ -run 'TestSchemaGolden|TestDesktopTestSchema' -update
```

The `add-migration` skill in `.claude/skills/` has the details, including the
table-rebuild steps for changing a CHECK constraint.

## Pull requests

- Branch off `main` and open the PR into `main`. One change per PR.
- Add or update tests for what you changed, and say in the PR how you tested it.
- A user-facing change updates its page in `docs/guide/` in the same PR,
  following [docs/guide/WRITING.md](docs/guide/WRITING.md).
- Docs, code comments and commit messages are in English.
- CI must be green: tests, lint and the leak check.

## No live data

This repository is public. Never commit data from a real install: not in
tests, fixtures, docs, screenshots or logs. That means no real Slack, Google
or Jira ids, company or workspace names, company mail domains, personal names
or email addresses, and no local absolute paths. Use placeholders such as
`<corp-workspace>`, `<owner-slack-id>` and "colleague A", and neutral samples
such as `acme` and `example.com`.

`make hooks` installs a pre-push hook that runs `scripts/leak-check.sh` over
the commits you push; CI runs the same scan on every PR. A deliberate fake that
trips a generic pattern can carry `leak-check:allow` on its line.

## License

By contributing, you agree that your contributions are licensed under the
[MIT License](LICENSE).
