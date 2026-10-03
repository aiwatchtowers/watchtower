; C# definitions, from upstream tree-sitter-c-sharp tags.scm (spec §6.3),
; with the reference captures and upstream's duplicate @module namespace
; capture dropped. Added to upstream: structs, enums and their members
; (consts), records (classes), delegates (types), file-scoped namespaces,
; properties, fields and events (fields; `const` fields consts, decided in
; Go). Definitions inside a method, constructor, accessor or lambda body
; are locals (dropped in Go).
;
; Limits: constructors, destructors, operators and indexers are not
; indexed; a file-scoped namespace encloses nothing (its declarations are
; its siblings in the tree), so it is no container.

(class_declaration name: (identifier) @name) @definition.class

(record_declaration name: (identifier) @name) @definition.class

(interface_declaration name: (identifier) @name) @definition.interface

(struct_declaration name: (identifier) @name) @definition.struct

(enum_declaration name: (identifier) @name) @definition.enum

(enum_member_declaration name: (identifier) @name) @definition.const

(delegate_declaration name: (identifier) @name) @definition.type

(namespace_declaration name: (_) @name) @definition.module

(file_scoped_namespace_declaration name: (_) @name) @definition.module

(method_declaration name: (identifier) @name) @definition.method

(property_declaration name: (identifier) @name) @definition.field

(field_declaration
  (variable_declaration (variable_declarator name: (identifier) @name))) @definition.field

(event_field_declaration
  (variable_declaration (variable_declarator name: (identifier) @name))) @definition.field
