; Swift definitions, rewritten from upstream tags.scm (spec §6.3): every
; capture is on the declaration itself (upstream captured the enclosing
; type once per property — a fake class row each), and methods in enum
; bodies are methods. A class_declaration's kind (class, struct, enum,
; actor, extension) is read from declaration_kind in Go. Locals inside
; function bodies are not indexed.

(class_declaration name: (type_identifier) @name) @definition.class

; extension Foo / extension Foo.Bar
(class_declaration name: (user_type) @name) @definition.class

(protocol_declaration name: (type_identifier) @name) @definition.protocol

(typealias_declaration name: (type_identifier) @name) @definition.type

(source_file
  (function_declaration name: (simple_identifier) @name) @definition.function)

(class_body
  (function_declaration name: (simple_identifier) @name) @definition.method)

(enum_class_body
  (function_declaration name: (simple_identifier) @name) @definition.method)

(protocol_body
  (protocol_function_declaration name: (simple_identifier) @name) @definition.method)

(class_body (init_declaration "init" @name) @definition.method)

(enum_class_body (init_declaration "init" @name) @definition.method)

(protocol_body (init_declaration "init" @name) @definition.method)

(class_body
  (property_declaration
    name: (pattern bound_identifier: (simple_identifier) @name)) @definition.field)

(enum_class_body
  (property_declaration
    name: (pattern bound_identifier: (simple_identifier) @name)) @definition.field)

(protocol_body
  (protocol_property_declaration
    name: (pattern bound_identifier: (simple_identifier) @name)) @definition.field)

(source_file
  (property_declaration
    (value_binding_pattern mutability: "let")
    name: (pattern bound_identifier: (simple_identifier) @name)) @definition.const)

(source_file
  (property_declaration
    (value_binding_pattern mutability: "var")
    name: (pattern bound_identifier: (simple_identifier) @name)) @definition.var)
