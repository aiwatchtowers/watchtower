; Lua definitions, from upstream tree-sitter-lua tags.scm (spec §6.3; the
; forest grammar, whose node names it uses), with the reference captures
; dropped, and a function in a table constructor captured on its field
; (upstream: the whole table). `function M.foo()` and `M.foo = function` take M as container
; and `function M:foo()` is a method of M (set in Go). Functions inside a
; function body are locals (dropped in Go). Docs are `---` comments
; (LuaLS/EmmyLua).
;
; Limits: tables and other variables are not indexed (a module table is
; no symbol, only a container name); an LDoc block continued with `--`
; lines is not a doc.

(function_declaration
  name: [
    (identifier) @name
    (dot_index_expression field: (identifier) @name)
  ]) @definition.function

(function_declaration
  name: (method_index_expression method: (identifier) @name)) @definition.method

(assignment_statement
  (variable_list .
    name: [
      (identifier) @name
      (dot_index_expression field: (identifier) @name)
    ])
  (expression_list .
    value: (function_definition))) @definition.function

(table_constructor
  (field
    name: (identifier) @name
    value: (function_definition)) @definition.function)
