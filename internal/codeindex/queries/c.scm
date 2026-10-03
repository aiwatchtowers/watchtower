; C definitions, from upstream tree-sitter-c tags.scm (spec §6.3). Changes
; from upstream: a function's definition node is the whole
; function_definition (upstream captured the declarator, so end_line and
; the signature stopped at the parameters), including functions returning
; pointers; prototypes are functions too; structs and unions are structs
; and enums enums (upstream: class and type), only with a body; added
; fields, enumerators (consts), #define macros and file-scope variables
; (`const` ones consts, decided in Go). Locals inside a function body are
; not indexed (dropped in Go).
;
; Limits: a function behind more than two pointer levels or returning a
; function pointer is not found; an anonymous struct is not a symbol (a
; typedef of one is a type).

(function_definition
  declarator: [
    (function_declarator declarator: (identifier) @name)
    (pointer_declarator declarator: (function_declarator declarator: (identifier) @name))
    (pointer_declarator declarator: (pointer_declarator declarator: (function_declarator declarator: (identifier) @name)))
  ]) @definition.function

(declaration
  declarator: [
    (function_declarator declarator: (identifier) @name)
    (pointer_declarator declarator: (function_declarator declarator: (identifier) @name))
    (pointer_declarator declarator: (pointer_declarator declarator: (function_declarator declarator: (identifier) @name)))
  ]) @definition.function

(struct_specifier name: (type_identifier) @name body: (_)) @definition.struct

(union_specifier name: (type_identifier) @name body: (_)) @definition.struct

(enum_specifier name: (type_identifier) @name body: (_)) @definition.enum

(enumerator name: (identifier) @name) @definition.const

(type_definition declarator: (type_identifier) @name) @definition.type

(field_declaration
  declarator: [
    (field_identifier) @name
    (pointer_declarator declarator: (field_identifier) @name)
    (pointer_declarator declarator: (pointer_declarator declarator: (field_identifier) @name))
    (array_declarator declarator: (field_identifier) @name)
  ]) @definition.field

(preproc_def name: (identifier) @name) @definition.macro

(preproc_function_def name: (identifier) @name) @definition.macro

(declaration
  declarator: [
    (identifier) @name
    (init_declarator declarator: (identifier) @name)
    (init_declarator declarator: (pointer_declarator declarator: (identifier) @name))
    (pointer_declarator declarator: (identifier) @name)
  ]) @definition.var
