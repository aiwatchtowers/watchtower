; OCaml definitions, from upstream tree-sitter-ocaml tags.scm (spec §6.3),
; with the @doc/#strip! machinery (docs are the (** *) comments read in
; Go) and the reference and operator captures dropped. Changes from
; upstream: only module-level lets count (a let inside an expression is a
; local), and a top-level value is a const, a let with parameters or a
; fun body a function (decided in Go); a type is a struct for a record,
; an enum for a variant (decided in Go); constructors are consts and
; record fields fields (upstream: enum_variant/field references kept as
; definitions); `val` specifications in a signature are functions.
;
; Limits: .mli files need the interface grammar and are not indexed; a doc
; comment after its item (OCaml allows both) is not read.

(compilation_unit (value_definition
  (let_binding pattern: (value_name) @name) @definition.function))

(structure (value_definition
  (let_binding pattern: (value_name) @name) @definition.function))

(external (value_name) @name) @definition.function

(value_specification (value_name) @name) @definition.function

(type_definition
  (type_binding
    name: [
      (type_constructor) @name
      (type_constructor_path (type_constructor) @name)
    ]) @definition.type)

(constructor_declaration (constructor_name) @name) @definition.const

(field_declaration (field_name) @name) @definition.field

(module_definition (module_binding (module_name) @name) @definition.module)

(module_type_definition (module_type_name) @name) @definition.interface

(class_definition (class_binding (class_name) @name) @definition.class)

(class_type_definition (class_type_binding (class_type_name) @name) @definition.class)

(method_definition (method_name) @name) @definition.method

(instance_variable_definition (instance_variable_name) @name) @definition.field
