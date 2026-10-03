; Scala definitions, from upstream tree-sitter-scala tags.scm (spec §6.3),
; with the reference captures dropped and upstream's kinds mapped onto the
; closed set: traits are interfaces, objects modules, enum cases consts,
; class parameters, and vals/vars in a template body, fields; a `def` in a
; template body is a method, at the top level a function; a top-level val
; is a const and a var a var. Definitions inside a function body are
; locals (dropped in Go).
;
; Limits: the package clause is not a symbol (as Java's); extension
; methods and givens are not indexed.

(trait_definition name: (identifier) @name) @definition.interface

(enum_definition name: (identifier) @name) @definition.enum

(simple_enum_case name: (identifier) @name) @definition.const

(full_enum_case name: (identifier) @name) @definition.const

(class_definition name: (identifier) @name) @definition.class

(object_definition name: (identifier) @name) @definition.module

(type_definition name: (type_identifier) @name) @definition.type

(template_body (function_definition name: (identifier) @name) @definition.method)

(template_body (function_declaration name: (identifier) @name) @definition.method)

(compilation_unit (function_definition name: (identifier) @name) @definition.function)

(template_body (val_definition pattern: (identifier) @name) @definition.field)

(template_body (var_definition pattern: (identifier) @name) @definition.field)

(template_body (val_declaration name: (identifier) @name) @definition.field)

(template_body (var_declaration name: (identifier) @name) @definition.field)

(compilation_unit (val_definition pattern: (identifier) @name) @definition.const)

(compilation_unit (var_definition pattern: (identifier) @name) @definition.var)

(class_parameter name: (identifier) @name) @definition.field
