; Zig definitions, written for Watchtower (tree-sitter-zig ships no
; tags.scm; spec §6.3). A top-level or container-level `const`/`var`
; whose value is a `struct` (or `opaque`) is a struct, a `union` a
; struct, an `enum` or an error set an enum; any other is a const or a
; var by its keyword (decided in Go), except `@import` aliases, which are
; dropped. A `fn` in a container is a method, at the top level a
; function, and an enum's fields are consts (all decided in Go); other
; container fields are fields. Definitions inside a function body, a
; `test` or a `comptime` block are locals (dropped in Go). Docs are `///`
; comments.
;
; Limits: `test` blocks and a container's `//!` doc are not indexed; a type built by a function call (`const List =
; std.ArrayList(u8)`) is a const, not a type.

(variable_declaration . (identifier) @name) @definition.var

(function_declaration name: (identifier) @name) @definition.function

(container_field name: (identifier) @name) @definition.field
