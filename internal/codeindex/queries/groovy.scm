; Groovy definitions, written for Watchtower (tree-sitter-groovy ships no
; tags.scm; spec §6.3). A class is a class, an `interface` or a `trait`
; an interface (decided in Go); a method defined or declared in a class
; body is a method, a top-level `def` a function, and so is a variable
; holding a closure (`def helper = { … }`). Variables in a class body are
; fields, top-level ones vars, `static final` and top-level `final` ones
; consts (decided in Go). Docs are GroovyDoc `/** */` blocks only (read
; in Go). Before parsing, a class header's `implements …` is blanked and
; `trait` spelled `class` (same length; the grammar knows neither).
;
; Limits: the grammar has no enums (an enum and its body are not
; indexed), no constructors (not indexed) and no Jenkinsfile declarative
; `pipeline { … }` block; definitions inside a closure (a Gradle block)
; or a method body are not indexed.

(class_definition name: (identifier) @name) @definition.class

(class_definition body: (closure
  (function_definition function: (identifier) @name) @definition.method))

(class_definition body: (closure
  (function_declaration function: (identifier) @name) @definition.method))

(class_definition body: (closure
  (declaration name: (identifier) @name) @definition.field))

(source_file (function_definition function: (identifier) @name) @definition.function)

(source_file (declaration name: (identifier) @name) @definition.var)
