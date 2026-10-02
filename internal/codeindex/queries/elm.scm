; Elm definitions, from upstream tree-sitter-elm tags.scm (spec §6.3),
; with the reference captures dropped and the kinds mapped onto the closed
; set: a custom type is an enum and its variants consts (upstream: type
; and union), a type alias a type, a top-level value a function (as
; upstream), a port a function. Only top-level values: a let binding is a
; local. Docs are {-| -} comments, above the type annotation (read in Go).

(file (value_declaration
  (function_declaration_left . (lower_case_identifier) @name)) @definition.function)

(port_annotation name: (lower_case_identifier) @name) @definition.function

(type_alias_declaration name: (upper_case_identifier) @name) @definition.type

(type_declaration name: (upper_case_identifier) @name) @definition.enum

(union_variant name: (upper_case_identifier) @name) @definition.const

(module_declaration name: (upper_case_qid) @name) @definition.module
