; Rust definitions, from upstream tree-sitter-rust tags.scm (spec §6.3),
; with each ADT on its own kind (upstream reports structs, enums, unions and
; type aliases all as class) and the reference captures dropped. Functions
; in an impl or trait body are methods (an impl's methods and associated
; consts take the impl's type as container, set in Go), in a mod body
; functions; locals inside function bodies are not indexed.
;
; Limits: fields are a struct's or a union's named fields only (an enum's
; struct-variant fields and the variants themselves are not indexed);
; tuple-struct fields are unnamed and not indexed; items inside a macro
; invocation or a function body are not indexed.

(struct_item name: (type_identifier) @name) @definition.struct

(enum_item name: (type_identifier) @name) @definition.enum

(union_item name: (type_identifier) @name) @definition.struct

(type_item name: (type_identifier) @name) @definition.type

(trait_item name: (type_identifier) @name) @definition.interface

(mod_item name: (identifier) @name) @definition.module

(macro_definition name: (identifier) @name) @definition.macro

(impl_item body: (declaration_list
  (function_item name: (identifier) @name) @definition.method))

(impl_item body: (declaration_list
  (const_item name: (identifier) @name) @definition.const))

(trait_item body: (declaration_list
  (function_item name: (identifier) @name) @definition.method))

(trait_item body: (declaration_list
  (function_signature_item name: (identifier) @name) @definition.method))

(trait_item body: (declaration_list
  (const_item name: (identifier) @name) @definition.const))

(source_file
  (function_item name: (identifier) @name) @definition.function)

(mod_item body: (declaration_list
  (function_item name: (identifier) @name) @definition.function))

(source_file
  (const_item name: (identifier) @name) @definition.const)

(mod_item body: (declaration_list
  (const_item name: (identifier) @name) @definition.const))

(source_file
  (static_item name: (identifier) @name) @definition.var)

(mod_item body: (declaration_list
  (static_item name: (identifier) @name) @definition.var))

(struct_item body: (field_declaration_list
  (field_declaration name: (field_identifier) @name) @definition.field))

(union_item body: (field_declaration_list
  (field_declaration name: (field_identifier) @name) @definition.field))
