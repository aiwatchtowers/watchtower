; Go definitions. Captures: @name and @definition.<kind> (codeindex.Kind).
; A type_spec's struct/interface kind and a method's receiver container are
; settled in Go (parse.go refine). Only top-level declarations: nothing
; declared inside a function body is indexed.

(source_file
  (function_declaration name: (identifier) @name) @definition.function)

(source_file
  (method_declaration name: (field_identifier) @name) @definition.method)

(source_file
  (type_declaration
    (type_spec name: (type_identifier) @name) @definition.type))

(source_file
  (type_declaration
    (type_alias name: (type_identifier) @name) @definition.type))

(source_file
  (const_declaration
    (const_spec name: (identifier) @name) @definition.const))

(source_file
  (var_declaration
    (var_spec name: (identifier) @name) @definition.var))

(field_declaration_list
  (field_declaration name: (field_identifier) @name) @definition.field)

(interface_type
  (method_elem name: (field_identifier) @name) @definition.method)
