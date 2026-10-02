; Rust definitions, from upstream tree-sitter-rust tags.scm (spec §6.3),
; with each ADT on its own kind (upstream reports structs, enums, unions and
; type aliases all as class) and the reference captures dropped. Functions
; in an impl or trait body are methods, in a mod body functions; locals
; inside function bodies are not indexed.

(struct_item name: (type_identifier) @name) @definition.struct

(enum_item name: (type_identifier) @name) @definition.enum

(union_item name: (type_identifier) @name) @definition.struct

(type_item name: (type_identifier) @name) @definition.type

(trait_item name: (type_identifier) @name) @definition.interface

(mod_item name: (identifier) @name) @definition.module

(macro_definition name: (identifier) @name) @definition.macro

(impl_item body: (declaration_list
  (function_item name: (identifier) @name) @definition.method))

(trait_item body: (declaration_list
  (function_item name: (identifier) @name) @definition.method))

(trait_item body: (declaration_list
  (function_signature_item name: (identifier) @name) @definition.method))

(source_file
  (function_item name: (identifier) @name) @definition.function)

(mod_item body: (declaration_list
  (function_item name: (identifier) @name) @definition.function))

(source_file
  (const_item name: (identifier) @name) @definition.const)

(source_file
  (static_item name: (identifier) @name) @definition.var)

(field_declaration_list
  (field_declaration name: (field_identifier) @name) @definition.field)
