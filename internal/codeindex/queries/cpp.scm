; C++-only definitions, from upstream tree-sitter-cpp tags.scm (spec §6.3),
; run after c.scm (the C++ grammar extends C's, so every C pattern holds
; here too). Changes from upstream: methods — inline definitions, member
; declarations and `Foo::bar` definitions, the last taking Foo as container
; in Go — are methods; classes, structs, enums, namespaces (modules) and
; `using` aliases (types) have their own kinds. Reference captures dropped.
;
; Limits: destructors and operators are not indexed; a constructor declared
; in its class is a method named after the class.

(function_definition
  declarator: (function_declarator declarator: (field_identifier) @name)) @definition.method

(function_definition
  declarator: (function_declarator
    declarator: (qualified_identifier
      name: [
        (identifier) @name
        (qualified_identifier name: (identifier) @name)
        (qualified_identifier name: (qualified_identifier name: (identifier) @name))
      ]))) @definition.method

(field_declaration
  declarator: [
    (function_declarator declarator: (field_identifier) @name)
    (pointer_declarator declarator: (function_declarator declarator: (field_identifier) @name))
    (reference_declarator (function_declarator declarator: (field_identifier) @name))
  ]) @definition.method

(class_specifier name: (type_identifier) @name body: (_)) @definition.class

(namespace_definition name: (namespace_identifier) @name) @definition.module

(alias_declaration name: (type_identifier) @name) @definition.type
