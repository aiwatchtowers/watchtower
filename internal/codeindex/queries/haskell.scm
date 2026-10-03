; Haskell definitions, written for Watchtower (tree-sitter-haskell ships
; no tags.scm; spec §6.3). The module header is a module; a `data` type
; is an enum with several constructors (its constructors consts) and a
; struct with one, a `newtype` a struct, a `type` synonym a type, a
; `class` an interface whose method signatures are methods. Record fields
; are fields. A top-level function is a function, indexed at its first
; equation (later equations of the same name are dropped in Go); a
; binding with no arguments is a const, a function when its type
; signature is a function type (decided in Go). Docs are Haddock `-- |`
; comments above the definition or its type signature (read in Go).
;
; Limits: instances and their methods, operators defined in prefix form
; (`(<+>)`), pattern bindings, type families and GADT constructors are
; not indexed; a definition's span is its first equation only; bindings
; in `where` and `let` are locals (not matched).

(header module: (module) @name) @definition.module

(declarations (data_type name: (name) @name) @definition.struct)

(declarations (newtype name: (name) @name) @definition.struct)

(declarations (type_synomym name: (name) @name) @definition.type)

(declarations (class name: (name) @name) @definition.interface)

(class_declarations (signature name: (variable) @name) @definition.method)

(data_constructor constructor: (_ name: (constructor) @name)) @definition.const

(field name: (field_name (variable) @name)) @definition.field

(declarations (function name: (variable) @name) @definition.function)

(declarations (bind name: (variable) @name) @definition.const)
