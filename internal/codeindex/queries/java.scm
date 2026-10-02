; Java definitions, from upstream tree-sitter-java tags.scm (spec §6.3),
; with the reference captures dropped. Added to upstream: enums and their
; constants, records, annotation types and their elements, fields
; (`static final` ones are consts, decided in Go) and interface constants.
; Definitions inside a method, constructor or lambda body are locals
; (dropped in Go).
;
; Limits: constructors are not indexed (they repeat the class name); the
; package clause is not a symbol.

(class_declaration name: (identifier) @name) @definition.class

(record_declaration name: (identifier) @name) @definition.class

(interface_declaration name: (identifier) @name) @definition.interface

(annotation_type_declaration name: (identifier) @name) @definition.interface

(enum_declaration name: (identifier) @name) @definition.enum

(enum_constant name: (identifier) @name) @definition.const

(method_declaration name: (identifier) @name) @definition.method

(annotation_type_element_declaration name: (identifier) @name) @definition.method

(field_declaration
  declarator: (variable_declarator name: (identifier) @name)) @definition.field

(constant_declaration
  declarator: (variable_declarator name: (identifier) @name)) @definition.const
