; GraphQL definitions, written for Watchtower (tree-sitter-graphql ships
; no tags.scm; spec §6.3). Object types are classes, interfaces
; interfaces, enums enums (their values consts), input types structs,
; unions and scalars types, directives macros; an `extend type` is a type
; row of its own, the container of what it adds (as Swift's extension).
; Fields of a type, an interface and an input type are fields. Named
; operations (query, mutation, subscription) and fragments are functions.
; Docs are descriptions (the string that opens a definition, read in Go);
; `#` comments are not docs, as in GraphQL itself. A signature starts
; after the description.
;
; Limits: anonymous operations and the `schema` block are not symbols;
; extensions of interfaces, enums, unions and inputs are not indexed;
; field arguments are not fields.

(object_type_definition (name) @name) @definition.class

(interface_type_definition (name) @name) @definition.interface

(enum_type_definition (name) @name) @definition.enum

(input_object_type_definition (name) @name) @definition.struct

(union_type_definition (name) @name) @definition.type

(scalar_type_definition (name) @name) @definition.type

(directive_definition (name) @name) @definition.macro

(object_type_extension (name) @name) @definition.type

(field_definition (name) @name) @definition.field

(input_fields_definition (input_value_definition (name) @name) @definition.field)

(enum_value_definition (enum_value) @name) @definition.const

(operation_definition (name) @name) @definition.function

(fragment_definition (fragment_name (name) @name)) @definition.function
