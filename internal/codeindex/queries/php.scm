; PHP definitions, from upstream tree-sitter-php tags.scm (spec §6.3),
; extended: enums and their cases, class and top-level constants, promoted
; constructor properties; methods are methods (upstream reports them as
; functions). Reference captures dropped. Traits are interfaces, as
; upstream. Definitions inside a function are locals (dropped in Go). Only
; a /** */ docblock is a doc (lang.go), so a // comment above a function
; is not.

(namespace_definition name: (namespace_name) @name) @definition.module

(interface_declaration name: (name) @name) @definition.interface

(trait_declaration name: (name) @name) @definition.interface

(class_declaration name: (name) @name) @definition.class

(enum_declaration name: (name) @name) @definition.enum

(enum_case name: (name) @name) @definition.const

(property_declaration
  (property_element (variable_name (name) @name))) @definition.field

(property_promotion_parameter
  name: (variable_name (name) @name)) @definition.field

(const_declaration (const_element (name) @name)) @definition.const

(function_definition name: (name) @name) @definition.function

(method_declaration name: (name) @name) @definition.method
