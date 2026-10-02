; Ruby definitions, from upstream tree-sitter-ruby tags.scm (spec §6.3),
; without the @doc/#strip!/#select-adjacent! machinery and the reference
; captures (whose `#is-not? local` the official runtime does not
; implement); docs are the # comments read in Go. Changes from upstream: a
; top-level `def` is a function; constants are indexed; definitions inside
; a method, block or lambda body are locals (dropped in Go).
;
; Limits: attr_reader/attr_accessor fields and define_method are calls, not
; indexed; `class << self` is not a symbol of its own (its methods take the
; enclosing class as container).

(program
  (method name: (_) @name) @definition.function)

(body_statement
  (method name: (_) @name) @definition.method)

(singleton_method name: (_) @name) @definition.method

(alias name: (_) @name) @definition.method

(class
  name: [
    (constant) @name
    (scope_resolution name: (_) @name)
  ]) @definition.class

(singleton_class
  value: [
    (constant) @name
    (scope_resolution name: (_) @name)
  ]) @definition.class

(module
  name: [
    (constant) @name
    (scope_resolution name: (_) @name)
  ]) @definition.module

(assignment left: (constant) @name) @definition.const
