; Julia definitions, written for Watchtower (tree-sitter-julia ships no
; tags.scm; spec §6.3). A module is a module; `struct` and `mutable
; struct` are structs, their fields fields; `abstract type` and
; `primitive type` are types; `@enum` is an enum, its values consts. A
; `function`, and a short form `f(x) = …` at the top level or in a
; module, is a function (a method extended on another module,
; `Base.length`, is named length); `macro` is a macro; `const` is a
; const and any other top-level or module-level assignment a var.
; Definitions inside a function, a macro or a `let` are locals (dropped
; in Go). Docs are docstrings, the string directly above a definition
; (read in Go; an indented signature line opening it is skipped).
;
; Limits: `#` comments are not docs (as in Julia); operator methods
; (`Base.:+`), functions defined by a macro, and `begin` blocks' contents
; are not indexed; a parametric type keeps no parameters in its name.

(module_definition name: (identifier) @name) @definition.module

(struct_definition (type_head [
  (identifier) @name
  (parametrized_type_expression . (identifier) @name)
  (binary_expression . [(identifier) @name (parametrized_type_expression . (identifier) @name)])
])) @definition.struct

(struct_definition (typed_expression . (identifier) @name) @definition.field)

(struct_definition (identifier) @name @definition.field)

(abstract_definition (type_head [
  (identifier) @name
  (parametrized_type_expression . (identifier) @name)
  (binary_expression . [(identifier) @name (parametrized_type_expression . (identifier) @name)])
])) @definition.type

(primitive_definition (type_head [
  (identifier) @name
  (binary_expression . (identifier) @name)
])) @definition.type

(macrocall_expression
  (macro_identifier (identifier) @_m)
  (macro_argument_list . (identifier) @name)
  (#eq? @_m "enum")) @definition.enum

(macrocall_expression
  (macro_identifier (identifier) @_m)
  (macro_argument_list . (identifier) (identifier) @name @definition.const)
  (#eq? @_m "enum"))

(function_definition (signature [
    (call_expression . [(identifier) @name (field_expression (identifier) @name .)])
    (typed_expression . (call_expression . [(identifier) @name (field_expression (identifier) @name .)]))
    (where_expression . [(call_expression . [(identifier) @name (field_expression (identifier) @name .)]) (typed_expression . (call_expression . [(identifier) @name (field_expression (identifier) @name .)]))])
  ])) @definition.function

(macro_definition (signature [
    (call_expression . [(identifier) @name (field_expression (identifier) @name .)])
    (typed_expression . (call_expression . [(identifier) @name (field_expression (identifier) @name .)]))
    (where_expression . [(call_expression . [(identifier) @name (field_expression (identifier) @name .)]) (typed_expression . (call_expression . [(identifier) @name (field_expression (identifier) @name .)]))])
  ])) @definition.macro

(source_file (assignment . [
    (call_expression . [(identifier) @name (field_expression (identifier) @name .)])
    (typed_expression . (call_expression . [(identifier) @name (field_expression (identifier) @name .)]))
    (where_expression . [(call_expression . [(identifier) @name (field_expression (identifier) @name .)]) (typed_expression . (call_expression . [(identifier) @name (field_expression (identifier) @name .)]))])
  ]) @definition.function)

(module_definition (assignment . [
    (call_expression . [(identifier) @name (field_expression (identifier) @name .)])
    (typed_expression . (call_expression . [(identifier) @name (field_expression (identifier) @name .)]))
    (where_expression . [(call_expression . [(identifier) @name (field_expression (identifier) @name .)]) (typed_expression . (call_expression . [(identifier) @name (field_expression (identifier) @name .)]))])
  ]) @definition.function)

(const_statement (assignment . (identifier) @name)) @definition.const

(source_file (assignment . (identifier) @name) @definition.var)

(module_definition (assignment . (identifier) @name) @definition.var)
