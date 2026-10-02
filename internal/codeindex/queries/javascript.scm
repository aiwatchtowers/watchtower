; JavaScript definitions, from upstream tree-sitter-javascript tags.scm
; (spec §6.3), with the reference captures and the @doc/#strip!/
; #select-adjacent! machinery dropped (docs are read in Go). TypeScript and
; TSX run this query followed by typescript.scm, so it uses only nodes all
; three grammars share.
;
; Changes from upstream: top-level variables are indexed (a function value
; makes a function, `const` a const, `let`/`var` a var — decided in Go);
; methods are methods only in a class body; a named function expression
; is not indexed apart from the assignment that names it; definitions
; inside a function are locals (dropped in Go). Constructors are not
; indexed, as upstream.

(class_declaration name: (_) @name) @definition.class

(class name: (_) @name) @definition.class

(class_body
  (method_definition name: (property_identifier) @name) @definition.method
  (#not-eq? @name "constructor"))

(object
  (method_definition name: (property_identifier) @name) @definition.function)

(function_declaration name: (identifier) @name) @definition.function

(generator_function_declaration name: (identifier) @name) @definition.function

(program
  (lexical_declaration
    (variable_declarator name: (identifier) @name) @definition.var))

(program
  (variable_declaration
    (variable_declarator name: (identifier) @name) @definition.var))

(export_statement
  (lexical_declaration
    (variable_declarator name: (identifier) @name) @definition.var))

(export_statement
  (variable_declaration
    (variable_declarator name: (identifier) @name) @definition.var))

(assignment_expression
  left: [
    (identifier) @name
    (member_expression property: (property_identifier) @name)
  ]
  right: [(arrow_function) (function_expression)]) @definition.function

(pair
  key: (property_identifier) @name
  value: [(arrow_function) (function_expression)]) @definition.function
