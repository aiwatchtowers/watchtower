; Python definitions. Functions directly in a class body are methods;
; functions nested in functions are not indexed. A docstring (first
; statement string) is the doc, read in Go; a # comment never is.

(module
  (function_definition name: (identifier) @name) @definition.function)

(module
  (decorated_definition
    definition: (function_definition name: (identifier) @name) @definition.function))

(class_definition
  body: (block
    (function_definition name: (identifier) @name) @definition.method))

(class_definition
  body: (block
    (decorated_definition
      definition: (function_definition name: (identifier) @name) @definition.method)))

(class_definition name: (identifier) @name) @definition.class

(module
  (expression_statement
    (assignment left: (identifier) @name)) @definition.var)
