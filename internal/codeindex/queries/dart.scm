; Dart definitions, from upstream tree-sitter-dart tags.scm (spec §6.3),
; with the reference captures dropped and the kinds mapped onto the closed
; set: mixins are interfaces, extensions types, enum constants consts;
; upstream's catch-all `(method_signature) @definition.method` (which names
; nothing) is dropped, and methods are captured on their method_signature
; (the body is its sibling, joined in Go). Added to upstream: fields,
; abstract members, top-level functions and consts. Definitions inside a
; function body are locals (dropped in Go).
;
; Limits: constructors (plain and factory) and operators are not indexed;
; a top-level `var` is not indexed.

(class_definition name: (identifier) @name) @definition.class

(mixin_declaration (mixin) (identifier) @name) @definition.interface

(extension_declaration name: (identifier) @name) @definition.type

(enum_declaration name: (identifier) @name) @definition.enum

(enum_constant name: (identifier) @name) @definition.const

(type_alias . (type_identifier) @name) @definition.type

(method_signature
  [
    (function_signature name: (identifier) @name)
    (getter_signature name: (identifier) @name)
    (setter_signature name: (identifier) @name)
  ]) @definition.method

(class_body
  (declaration
    [
      (function_signature name: (identifier) @name)
      (getter_signature name: (identifier) @name)
      (setter_signature name: (identifier) @name)
    ]) @definition.method)

(class_body
  (declaration
    (initialized_identifier_list
      (initialized_identifier (identifier) @name))) @definition.field)

(program (function_signature name: (identifier) @name) @definition.function)

(program
  (static_final_declaration_list
    (static_final_declaration (identifier) @name) @definition.const))
