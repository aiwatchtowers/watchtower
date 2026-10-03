# Spike #258 — native tree-sitter grammars in the CLI

Throwaway spike, 2026-10-02. The code is not for merging. It lived in `internal/codeindexspike/` and `cmd/codeindex_spike.go` (a hidden `watchtower codeindex-spike` subcommand) behind `//go:build codegrammars`. It was linked into the real CLI `main` package, so the size difference below is the real one.

## Verdict

**Native grammars are fine for the spec. The WASM fallback is not needed.**

- **Size:** the CLI grows by about 70 MB (37.7 → 104.6 MiB). The owner said size is not a concern.
- **Cold compile:** about 18 s more wall time (+51 s CPU) with an empty build cache. Warm rebuilds take the same time as today.
- **Full index of this repo:** 1.4–1.9 s with 4–8 workers and about 4 s with 2 workers. All of these meet the ≤5 s target. A single worker takes 6.6 s, which misses it, so the background indexer needs ≥2 workers or must skip Markdown.
- **Re-indexing one large file:** 10–75 ms, well inside the ≤200 ms target. This is a full re-parse; tree-sitter's real incremental edit would be faster still.
- **The real cost is query work, not grammars.** Only 20 of the 45 languages ship a `tags.scm`. The Swift and PHP ones exist but have to be rewritten. Ruby's does not compile on the smacker runtime. Signatures and doc comments are not produced by `tags.scm` at all; small Go code extracts them reliably.

Recommended stack for the spec:

- **Grammars:** go-sitter-forest. It covers all 45 languages, its Swift grammar is newer and better, and it is actively maintained.
- **Runtime:** the official `tree-sitter/go-tree-sitter` v0.25 is preferred: it is MIT-licensed, supports ABI 15 and is maintained. The smacker runtime works today, but it is frozen at ABI 14 and its last commit is from Aug 2024.
- **Queries:** our own copies in the repo, each with a fixture.
- **Signature and doc comment:** extracted in Go from the definition node.
- **Build tag:** `codegrammars && cgo`, with a stub for `!cgo`.

Measurement caveat: the machine was heavily loaded during the runs (load average 9–90 on 8 cores; `scripts/dev-health.sh` reported `HEALTH: overloaded` because of parallel sessions). Wall times are pessimistic, and CPU ("user") times are the more reliable comparison. Machine: Apple M1 Pro, 8 cores, 16 GB. Local toolchain: Go 1.27.1 (`go.mod` says 1.25.7).

## 1. Binary size (darwin/arm64, `-ldflags="-s -w"`, as `scripts/build-app.sh` builds it)

| Build | Bytes | MiB | Δ vs baseline |
|---|---:|---:|---:|
| Baseline CLI (no tag) | 39,503,778 | 37.7 | — |
| `codegrammars`: 45 langs, smacker where available, forest for the rest | 109,718,018 | 104.6 | **+70.2 MB (×2.78)** |
| `codegrammars,forestall`: all 45 langs from forest | 112,223,522 | 107.0 | +72.7 MB |

That is +27% on the 256 MB app. The spike's Go code and embedded queries add only about 0.3 MB.

Per-grammar compiled archive sizes (forest variant, MB). They add up to 82.5 MB of archives against 72.7 MB of binary growth, so they are proportional, not exact:

| Grammar | MB | Grammar | MB | Grammar | MB |
|---|---:|---|---:|---|---:|
| nim | 9.40 | ruby | 2.29 | java | 0.55 |
| julia | 5.84 | runtime (go-tree-sitter) | 1.88 | erlang | 0.53 |
| ocaml | 5.83 | tsx | 1.64 | javascript | 0.52 |
| kotlin | 5.66 | bash | 1.62 | yaml | 0.34 |
| objc | 5.53 | typescript | 1.60 | go | 0.33 |
| c_sharp | 5.28 | elixir | 1.59 | elm | 0.31 |
| haskell | 4.11 | rust | 1.27 | scss, css, hcl | ~0.25 each |
| scala | 4.01 | dart | 1.14 | clojure, proto, lua, svelte, dockerfile | 0.16–0.20 |
| cpp | 3.78 | php | 0.99 | graphql, vue, html, toml | 0.12–0.15 |
| swift | 3.70 | groovy | 0.96 | json | 0.08 |
| perl | 3.20 | zig | 0.81 | | |
| sql | 2.63 | c, python, r, markdown | 0.6–0.8 each | | |

Dropping the five niche heavyweights (nim, julia, objc, haskell, perl) would save about 28 MB of archive, roughly −25 MB of binary (an estimate, not measured).

## 2. Compile time (whole CLI, clean `GOCACHE`)

| Build | Wall (load ~25) | user CPU | Wall (first run, load 58–90) | Compiler peak RSS |
|---|---:|---:|---:|---:|
| Baseline | 21.1 s | 70.5 s | 38.6 s | 660 MB |
| `codegrammars` (smacker-first) | 39.3 s | 121.2 s | 93.8 s | 737 MB |
| `codegrammars,forestall` | 36.5 s | 121.4 s | 52.9 s | 731 MB |

- **Grammar cost:** about +18 s wall and +51 s CPU when the cache is cold, paid once per cache. The large generated `parser.c` files (nim 67 MB, julia 44 MB, ocaml 35 MB, kotlin 31 MB) are the critical path.
- **Warm rebuild after a real edit in `cmd/`:** 1.35 s baseline vs 1.43 s tagged. The cgo objects are cached, so warm builds cost the same as today.
- **Startup:** `watchtower version` takes 0.02 s in both builds.

## 3. Full index of this repo

Run over `git ls-files`: 3,134 files, of which 3,031 were parsed and 33.2 MB read. The other 103 files had no grammar or were binary/oversized. Each parsed file went through parse + `tags.scm` query + name/kind/line/signature/doc extraction.

| Variant | Workers | Index wall | Files/s | Process total (incl. git ls-files, all-grammar compile) | Peak RSS |
|---|---:|---:|---:|---:|---:|
| smacker-first | 1 | 6.57 s | 477 | 7.17 s | 134 MB |
| smacker-first | 2 | 3.88 s | 807 | 4.50 s | 133 MB |
| smacker-first | 4 | 1.68 s | 1,866 | 2.26 s | 142 MB |
| smacker-first | 8 | 1.43 s | 2,199 | 2.03 s | 169 MB |
| forest-all | 1 | 6.57 s | 477 | 7.23 s | 129 MB |
| forest-all | 2 | 4.56 s | 688 | 5.01 s | 132 MB |
| forest-all | 4 | 1.88 s | 1,669 | 2.35 s | 151 MB |
| forest-all | 8 | 1.57 s | 2,002 | 2.02 s | 184 MB |

- **Symbols:** 61,233 in total. The Swift count is inflated because of the upstream `tags.scm` bug described in §5.
- **One-time grammar + query compile for all 45 languages:** 0.40–0.55 s. The Swift query dominates it: 73 ms on forest and 232 ms on smacker. The real indexer would compile each language lazily.
- **Where the CPU goes (8 workers, smacker-first, CPU summed across workers):**

  | Language | Files | Parse CPU | Query CPU |
  |---|---:|---:|---:|
  | Markdown | 498 | 3.16 s | none (no tags) |
  | Swift | 1,161 | 2.13 s | 1.29 s |
  | Go | 1,209 | 1.96 s | 1.33 s |
  | Everything else | — | under 0.2 s | — |

  Markdown is about 40% of parse CPU and yields no symbols. Skipping it, or indexing headings only with a cheaper path, would bring the single-worker run to about 4 s (estimate).
- **Files with parse errors:**

  | Variant | Swift | SQL | Markdown |
  |---|---:|---:|---:|
  | smacker-first | 36 / 1,161 | 46 / 88 | 1 |
  | forest-all | 14 / 1,161 | 46 / 88 | 1 |

  tree-sitter recovers locally, so symbols are still extracted from these files. The SQL grammar does not handle SQLite's `AUTOINCREMENT` and `PRAGMA`.

## 4. Single-file re-index (target ≤200 ms)

| File | Size | Symbols | First file of its language (new parser + compile + parse + extract) | Warm ×20 median (max) |
|---|---:|---:|---:|---:|
| `WatchtowerDesktop/Sources/Services/MeetingRecorderCenter.swift` | 94 KB | 349 | 95 ms forest / 257 ms smacker | 20.7 ms (21.5) |
| `WatchtowerDesktop/Tests/MeetingRecorderQueueTests.swift` | 73 KB | 283 | 90 ms / 250 ms | 15.5 ms (16.4) |
| `internal/digest/pipeline_test.go` (largest .go) | 116 KB | 140 | 26 ms | 22.3 ms (23.6) |
| `internal/db/memory.go` | 98 KB | 99 | 13 ms | 10.0 ms (10.6) |
| `docs/review/review-lessons.md` (largest file) | 419 KB | 0 | 66 ms | 64.5 ms (67.4) |

The "first file" column includes the one-time query compile for that language. In a long-lived daemon that cost is paid once. The warm numbers are a full re-parse of the file without reusing the old tree.

## 5. Language availability matrix (45 languages)

S = `smacker/go-tree-sitter` (31 + CUE), F = `alexaandru/go-sitter-forest` (all 45; one Go module per language). `tags.scm` = an upstream query vendored in forest, identical to the upstream repo for Swift and PHP (checked with diff).

| Language | S | F | Upstream tags.scm | Spike result |
|---|:-:|:-:|:-:|---|
| C | ✓ | ✓ | ✓ | ok |
| C++ | ✓ | ✓ | ✓ | ok |
| C# | ✓ | ✓ | ✓ | ok |
| Rust | ✓ | ✓ | ✓ | ok |
| Go | ✓ | ✓ | ✓ | ok |
| Java | ✓ | ✓ | ✓ | ok |
| JavaScript | ✓ | ✓ | ✓ | ok |
| TypeScript | ✓ | ✓ | ✓ (TS-only nodes) | must be concatenated with the JS query, as upstream intends; the combination compiles |
| TSX | ✓ | ✓ | ✓ (TS-only nodes) | same as TypeScript |
| Python | ✓ | ✓ | ✓ | ok (docstrings sit inside the body, not before it) |
| PHP | ✓ | ✓ | ✓ | compiles; needs extending (see §6) |
| Swift | ✓ | ✓ | ✓ | compiles; **needs a rewrite** (see §6) |
| Ruby | ✓ | ✓ | ✓ | **does not compile** on the smacker runtime: its `#is-not? local` / `#strip!` predicates are mis-parsed |
| Lua | ✓ | ✓ | ✓ | does not compile against smacker's older Lua grammar (`invalid node type function_declaration`); fine with the forest grammar |
| Scala | ✓ | ✓ | ✓ | ok |
| Elixir | ✓ | ✓ | ✓ | ok |
| OCaml | ✓ | ✓ | ✓ | ok (`.ml` only; `.mli` needs the interface grammar) |
| Elm | ✓ | ✓ | ✓ | ok |
| Dart | – | ✓ | ✓ | ok |
| R | – | ✓ | ✓ | ok |
| Kotlin | ✓ | ✓ | **missing** | the spike wrote one: 6 patterns, about 20 lines |
| Bash | ✓ | ✓ | **missing** | the spike wrote one: 1 pattern |
| Groovy | ✓ | ✓ | missing | |
| SQL | ✓ | ✓ | missing | weak for SQLite (46 of 88 migrations have errors) |
| HCL / Terraform | ✓ | ✓ | missing | forest has no separate `terraform` package; HCL covers `.tf` |
| Protobuf | ✓ | ✓ | missing | |
| Dockerfile | ✓ | ✓ | missing | |
| HTML, CSS | ✓ | ✓ | missing | |
| YAML, TOML | ✓ | ✓ | missing | |
| Markdown | ✓ | ✓ | missing | |
| Svelte | ✓ | ✓ | missing | |
| Erlang, Haskell, Zig, Objective-C, Julia, Perl, Nim, Clojure | – | ✓ | missing | |
| JSON, SCSS, GraphQL, Vue | – | ✓ | missing | |

No target language is missing entirely.

**Languages without a `tags.scm` (25):**

- **Code-like, need a definitions query (~20 lines + fixture each), 15:** Kotlin, Bash, Groovy, Haskell, Erlang, Clojure, Julia, Nim, Objective-C, Perl, Zig, SQL (`CREATE TABLE/VIEW/INDEX`), HCL (`resource`/`module`/`variable` blocks), Protobuf (`message`/`service`/`rpc`), GraphQL (type and operation definitions).
- **Markup/config, outline-style or skip, 10:** HTML, CSS, SCSS, YAML, TOML, JSON, Markdown, Dockerfile, Svelte, Vue. Svelte and Vue really need injection (index the `<script>` block with the JS/TS query), which is more than 20 lines.

**Already shipped but needing work (5):** Swift (rewrite), PHP (extend), Ruby (predicates), TypeScript/TSX (JS+TS concatenation), Lua (only with the forest grammar).

## 6. Swift and PHP deep check

The tag query supplies only `@name` and `@definition.<kind>`. Neither `tags.scm` captures a signature or a doc comment. The JS, Python, Ruby, Rust and Go upstream queries do capture `@doc`, but through non-standard `#select-adjacent!` / `#strip!` predicates that the Go bindings do not implement. The spike derived the missing pieces in Go:

- **Signature:** the definition node's text up to its body child (`body`, `class_body`, `computed_property`, `compound_statement`, …), with whitespace collapsed.
- **Doc comment:** the adjacent preceding sibling comment nodes, climbing through wrapper nodes such as `export_statement`.
- **Swift kind:** read from the `declaration_kind` field, because `class_declaration` also covers struct, enum, actor and extension.

This works well.

### Swift

Tested on a modern sample (`@Observable`/`@MainActor` macros, actors, `some`/`any`, result builders, async/throws, a protocol with a primary associated type, parameter packs, `consuming`, `#Preview`, typed throws) and on a real 94 KB file from `WatchtowerDesktop/Sources`.

Kinds:

| Obtained | How |
|---|---|
| class, struct, enum, actor, extension | via `declaration_kind` |
| protocol | reported as `interface` |
| method (in class/struct/protocol bodies) | |
| function (top level) | |
| property | |
| init / deinit / subscript | upstream patterns exist |

Signatures come out clean and include the attributes, for example:

- `@Observable @MainActor final class CounterModel`
- `func increment(by step: Int = 1) async throws -> Int`
- `nonisolated func describe() -> some CustomStringConvertible`
- `actor Cache<Key: Hashable & Sendable, Value: Sendable>`
- `protocol Repository<Entity>: Sendable`
- `let items: any Collection<String>`
- `func withPack<each T>(_ value: repeat each T)`

Doc comments: `///` blocks (including multi-line runs) are found reliably, even when attributes sit between the comment and the declaration. On the real file, 218 of 349 symbols carried a doc comment.

Upstream `tags.scm` defects, so it must be rewritten:

- The `(class_declaration (class_body (property_declaration …))) @definition.property` pattern captures the **whole class** as the definition. Every stored property therefore also produces a bogus "class/struct named after the property" row. On the real file this affected about half of the 64 class and 39 struct rows, and it inflates the repo's Swift symbol count. The fix is to capture the declaration node itself.
- Methods inside `enum` bodies are reported as `function`, because `enum_class_body` is not covered.
- Extensions of qualified types produce no extension symbol.
- Properties are matched twice (class-body pattern and top-level pattern); the spike deduplicated them.

Grammar quality on modern syntax:

| Variant | Files with errors in this repo |
|---|---:|
| smacker (older grammar) | 36 / 1,161 |
| forest (current grammar) | 14 / 1,161 |

- **smacker** fails on Swift Testing's freestanding macros (`#expect(...)`, `try #require(...)`), which accounts for most of its 36.
- **forest** still fails on:
  - `nonisolated(unsafe) var`
  - `if let x = try await …`
  - `switch await …`
  - some `#if DEBUG` placements
  - `.success(())` / `.yield(())`
  - multi-trailing-closure `label:` forms
  - typed throws `throws(E)` (Swift 6 syntax, not 5.10)
- Macros (`@Observable`, `@resultBuilder`, attached attributes), actors, `some`/`any`, async and parameter packs all parse.
- Errors stay local: symbols before and after the bad span are still extracted.

### PHP (written sample covering PHP 8.x)

Obtained:

| Kind | Notes |
|---|---|
| namespace | as `module` |
| class | |
| interface | |
| trait | reported as `interface` |
| field (typed property) | |
| function / method | both reported as `function` |

Signatures include attributes and modifiers, for example `#[Entity(table: 'invoices')] final class Invoice implements Payable`, `public static function fromArray(array $data): self` and `abstract protected function hook(): void;`. A multi-line promoted constructor collapses to one line.

Doc comments: `/** */` docblocks are found for classes, properties, methods and free functions.

Gaps in the upstream query (extend it):

- `enum` declarations are missing entirely.
- Enum cases, class `const` and promoted constructor properties are missing.
- Methods come out as `function`.
- A plain `//` line comment above a method is taken as its doc. The doc collector should accept only `/**` in PHP, and `///` or `/** */` in Swift.

The smacker and forest PHP grammars gave identical results.

### Hand-written query effort (Kotlin)

A 20-line Kotlin query found all six symbols in a sample. The fixture still exposed two bugs: a doc comment missed on a `data class` right after the package header, and the property signature narrowed to the bare name. Budget about 20 lines plus a fixture per language, plus one review round.

## 7. Binding options

| Option | License | Runtime ABI | Coverage | Notes |
|---|---|---|---|---|
| `smacker/go-tree-sitter` | MIT | 14 (min 13) | 31 of 45 | Last commit Aug 2024. Ships **no queries**. Frees memory through finalizers. Some grammars are stale (Lua, Swift). Module zip 14 MB (251 MB unpacked). |
| `alexaandru/go-sitter-forest` | MIT (every vendored grammar LICENSE in the 45 says MIT; re-check upstream before shipping) | grammars are ABI 14 | 45 of 45 (and many more) | Actively maintained (root module v1.9.163). One module per language. Embeds upstream and nvim-treesitter queries (`GetQuery("tags", NativeOnly)`). `GetLanguage()` returns an `unsafe.Pointer`, so it plugs into the smacker runtime (`sitter.NewLanguage`) or the official one. 45 languages = 26 MB of zips / 454 MB unpacked in the module cache. |
| `tree-sitter/go-tree-sitter` (official) | MIT | 15 (min 13) | runtime only; grammars come from each grammar repo's `bindings/go` | Requires explicit `Close()` (no finalizers). **Trap:** some grammar repos do not commit the generated `src/parser.c`. `alex-pinkus/tree-sitter-swift`'s Go module has `src/` without `parser.c`, so `go get`-ing its binding cannot compile. Generated sources still have to come from somewhere vendored (forest does this). The `tree-sitter/tree-sitter-php` module does include `parser.c` and `queries/tags.scm`. Not built in this spike. |

## 8. cgo, CI and release implications

- **Today the CLI has zero cgo packages.** `modernc.org/sqlite` is pure Go, and `go list -deps` finds no `CgoFiles` in the CLI. The grammars would be the first cgo dependency. Use the tag `codegrammars && cgo`, and give the package a `!cgo` stub so `CGO_ENABLED=0` builds and tools keep compiling.
- **Release build is unaffected apart from build time.** `scripts/build-app.sh` already builds `GOARCH=arm64 CGO_ENABLED=1 go build` natively on macOS, so nothing is cross-compiled. The cost is +18 s on a cold cache and nothing on a warm one. If a linux or windows CLI were ever cross-built from a Mac, it would need a C cross-toolchain (for example `zig cc`); no such build exists today.
- **CI is unchanged unless the tag is turned on.** The Go jobs (`ci.yml` Go Test, `release.yml` Go Release Gate, both on ubuntu-latest) run untagged `go build ./...`, `make test-cover` and `-race`. If a job adds `-tags codegrammars`, ubuntu runners already have gcc (`-race` needs cgo anyway). Each job then pays about +50 s CPU on a cold build cache (setup-go restores `GOCACHE`), plus module downloads of about 40 MB of zips.
- **Lint:** golangci-lint and `make lint-diff` do not see tagged files unless `build-tags: [codegrammars]` is configured.
- **Modules:** `go mod tidy` considers every build tag, so the grammar modules land in `go.mod`/`go.sum` even though untagged builds never download or compile them.
- **Noise:** the smacker Lua `parser.c` prints a harmless `-Wnull-character` warning. Forest builds were quiet.

## 9. Inputs for the spec

1. Grammars from go-sitter-forest, pinned per language. Runtime: the official go-tree-sitter v0.25, behind a small adapter with explicit `Close()`.
2. Vendor our own `queries/<lang>.scm` with a golden fixture per language:
   - start from the 20 upstream queries;
   - rewrite Swift, extend PHP, fix the Ruby predicates, concatenate JS+TS;
   - write about 15 code-language queries.
3. Extract signature and doc comment in Go (definition text up to the body; adjacent preceding comments, with a per-language doc-comment prefix filter). Do not rely on query predicates for this.
4. Indexer: lazy per-language query compile, a pool of ≥2 workers for the background full index, Markdown excluded or indexed headings-only, and a per-file re-index on change (10–75 ms measured).
5. Optional size trim: drop nim, julia, objc, haskell and perl (about −25 MB) if size ever matters.
