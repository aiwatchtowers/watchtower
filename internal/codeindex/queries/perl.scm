; Perl definitions, written for Watchtower (tree-sitter-perl ships no
; tags.scm; spec §6.3). A `package` is a module; a `sub` is a function
; whose container is its package — the block of `package X { … }`, or the
; nearest `package X;` statement above it (set in Go). `use constant`
; names are consts; `our` and file-level `my` variables are vars, named
; without their sigil. Subs and variables inside a sub are locals
; (dropped in Go). Docs are the `#` comments directly above (POD is not
; read).
;
; Limits: subs are never methods (Perl does not mark them); anonymous
; subs assigned to globs, `*name = sub …`, `constant` lists built at run
; time, Moose/Moo attributes (`has`) and POD sections are not indexed.

(package_statement name: (package) @name) @definition.module

(subroutine_declaration_statement name: (bareword) @name) @definition.function

(use_statement
  module: (package) @_m
  (list_expression . (autoquoted_bareword) @name)
  (#eq? @_m "constant")) @definition.const

; Each key of a `use constant { … }` list; any other bareword key is
; dropped in Go (the list nests one level per key).
((autoquoted_bareword) @name @definition.const)

(source_file
  (expression_statement
    (assignment_expression
      left: (variable_declaration [
        variable: (_ (varname) @name)
        variables: (_ (varname) @name)
      ]))) @definition.var)

(package_statement (block
  (expression_statement
    (assignment_expression
      left: (variable_declaration [
        variable: (_ (varname) @name)
        variables: (_ (varname) @name)
      ]))) @definition.var))
