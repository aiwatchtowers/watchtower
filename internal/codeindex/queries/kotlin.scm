; Kotlin definitions, written for Watchtower (tree-sitter-kotlin ships no
; tags.scm; spec §6.3). Classes are classes, an `interface` an interface
; and an `enum class` an enum (decided in Go), enum entries consts; an
; `object` is a module (as Scala's); a typealias is a type. A `fun` in a
; class, object or enum body is a method, at the top level a function; an
; extension function (`fun String.last()`) is a method whose container is
; its receiver type (set in Go). A top-level `val` is a const, a `var` a
; var; properties in a body and `val`/`var` constructor parameters are
; fields, a `const val` anywhere a const (decided in Go). Definitions
; inside a function body, a lambda, an accessor or an init block are
; locals (dropped in Go). A KDoc `/**` directly after the imports is still
; the first declaration's doc (the grammar parks it in the import list;
; read in Go).
;
; Limits: a companion object is not a symbol (its members take the
; enclosing class as container); constructors, destructuring declarations
; (`val (a, b) = …`) and members of an anonymous `object :` expression are
; not indexed; the package header is not a symbol.

(class_declaration (type_identifier) @name) @definition.class

(object_declaration (type_identifier) @name) @definition.module

(type_alias (type_identifier) @name) @definition.type

(enum_entry (simple_identifier) @name) @definition.const

(source_file (function_declaration (simple_identifier) @name) @definition.function)

(class_body (function_declaration (simple_identifier) @name) @definition.method)

(enum_class_body (function_declaration (simple_identifier) @name) @definition.method)

(source_file
  (property_declaration (variable_declaration (simple_identifier) @name)) @definition.var)

(class_body
  (property_declaration (variable_declaration (simple_identifier) @name)) @definition.field)

(enum_class_body
  (property_declaration (variable_declaration (simple_identifier) @name)) @definition.field)

(class_parameter (binding_pattern_kind) (simple_identifier) @name) @definition.field
