# Third-party notices

Third-party code compiled into the Watchtower CLI beyond ordinary Go module
dependencies: the tree-sitter runtime and the grammars the code index
(`internal/codeindex`) parses with. Each grammar module comes from
[go-sitter-forest](https://github.com/alexaandru/go-sitter-forest), which
wraps the upstream grammar's generated `parser.c` (and `scanner.c` where the
grammar has one) in a Go package; the upstream grammar's own licence applies
to that C code, the forest licence to the Go wrapper.

An untagged build carries the Go, Python and Swift grammars; the release build
(`-tags codegrammars`) carries every grammar below. A grammar joins this file
in the same change that adds it to `internal/codeindex/grammars_full.go`.

## Runtime

| Component | Go module | Version | Licence | Upstream |
|---|---|---|---|---|
| go-tree-sitter (Go binding, vendors the tree-sitter C library) | `github.com/tree-sitter/go-tree-sitter` | v0.25.0 | MIT | https://github.com/tree-sitter/go-tree-sitter |
| tree-sitter C library (vendored in the binding's `src/`) | — | as vendored by go-tree-sitter v0.25.0 | MIT | https://github.com/tree-sitter/tree-sitter |
| ICU subset (vendored in the binding's `src/unicode/`) | — | as vendored by go-tree-sitter v0.25.0 | Unicode / ICU licence (ICU 58 and later) | https://github.com/unicode-org/icu |

## Grammars

| Language | Go module | Version | Wrapper licence | Grammar licence | Upstream grammar |
|---|---|---|---|---|---|
| Go | `github.com/alexaandru/go-sitter-forest/go` | v1.9.4 | MIT | MIT | https://github.com/tree-sitter/tree-sitter-go |
| Python | `github.com/alexaandru/go-sitter-forest/python` | v1.9.10 | MIT | MIT | https://github.com/tree-sitter/tree-sitter-python |
| Rust | `github.com/alexaandru/go-sitter-forest/rust` | v1.9.13 | MIT | MIT | https://github.com/tree-sitter/tree-sitter-rust |
| Swift | `github.com/alexaandru/go-sitter-forest/swift` | v1.9.5 | MIT | MIT | https://github.com/alex-pinkus/tree-sitter-swift |

The queries under `internal/codeindex/queries/` are Watchtower's own; those
that start from an upstream grammar's `tags.scm` say so in their header and
are derived works under that grammar's licence listed above.
