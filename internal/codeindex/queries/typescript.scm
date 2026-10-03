; TypeScript-only definitions, from upstream tree-sitter-typescript
; tags.scm (spec §6.3), run after javascript.scm for TypeScript and TSX,
; with the reference captures dropped. Added to upstream: type aliases,
; enums, namespaces (`internal_module`), interface properties and class
; fields.

(function_signature name: (identifier) @name) @definition.function

(interface_body
  (method_signature name: (property_identifier) @name) @definition.method)

(interface_body
  (property_signature name: (property_identifier) @name) @definition.field)

(abstract_method_signature name: (property_identifier) @name) @definition.method

(abstract_class_declaration name: (type_identifier) @name) @definition.class

(module name: (_) @name) @definition.module

(internal_module name: (_) @name) @definition.module

(interface_declaration name: (type_identifier) @name) @definition.interface

(type_alias_declaration name: (type_identifier) @name) @definition.type

(enum_declaration name: (identifier) @name) @definition.enum

(class_body
  (public_field_definition name: (property_identifier) @name) @definition.field)
