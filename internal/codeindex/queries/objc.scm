; Objective-C definitions, written for Watchtower (tree-sitter-objc ships
; no tags.scm; spec §6.3), concatenated after the C query (the grammar
; extends C's, so functions, structs, enums, typedefs, macros and
; file-scope variables come from there). An @interface and an
; @implementation are classes (a category of either a type, the container
; of what it adds, as Swift's extension; decided in Go); a @protocol is a
; protocol. Methods declared or defined are methods, named by their full
; selector (`addValue:forKey:`, joined in Go); properties and instance
; variables are fields. `NS_ENUM`/`NS_OPTIONS` enums are rewritten in Go
; before parsing (same length, the name in place) into plain C enums the
; grammar parses; a typedef's doc and signature are the enum's or the
; struct's it defines. Definitions inside a function or method body are locals
; (dropped in Go).
;
; Limits: a .h header is parsed as C (Monaco's association), so its
; @interface is not indexed; Objective-C++ (.mm) parses only as far as it
; is Objective-C; a class declared and implemented in one file has two
; class rows (as a C++ method declared and defined); blocks and
; `@class` forward declarations are not indexed.

(class_interface . (identifier) @name) @definition.class

(class_implementation . (identifier) @name) @definition.class

(protocol_declaration . (identifier) @name) @definition.protocol

(method_declaration . (identifier) @name) @definition.method

(method_declaration . (method_type) . (identifier) @name) @definition.method

(method_definition . (identifier) @name) @definition.method

(method_definition . (method_type) . (identifier) @name) @definition.method

(property_declaration
  (struct_declaration
    (struct_declarator [
      (identifier) @name
      (pointer_declarator declarator: (identifier) @name)
    ]))) @definition.field

(instance_variable
  (struct_declaration
    (struct_declarator [
      (identifier) @name
      (pointer_declarator declarator: (identifier) @name)
    ]))) @definition.field
