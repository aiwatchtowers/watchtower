; Bash definitions, written for Watchtower (tree-sitter-bash ships no
; tags.scm; spec §6.3). Both function forms (`foo() {` and `function foo
; {`) are functions, wherever they sit outside a function body (a
; function defined inside an `if` at the top level counts); a function
; defined inside another's body is a local (dropped in Go). Top-level
; variables are vars, `readonly` and `declare -r` ones consts (decided in
; Go). Docs are the `#` comments directly above; the shebang and
; shellcheck directives are skipped.
;
; Limits: a top-level variable is a row per assignment (a reassignment
; repeats it), and one assigned only inside an `if`, a loop or a function
; is not indexed; aliases are not indexed.

(function_definition name: (word) @name) @definition.function

(program
  (declaration_command (variable_assignment name: (variable_name) @name)) @definition.var)

(program
  (variable_assignment name: (variable_name) @name) @definition.var)
