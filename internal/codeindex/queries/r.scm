; R definitions, from upstream tree-sitter-r tags.scm (spec §6.3), with
; the reference captures dropped. Changes from upstream: every top-level
; assignment (`<-`, `<<-`, `=`) is a var, a function when its value is a
; function (decided in Go); a quoted name loses its quotes; assignments
; inside a function or a call are not indexed. Docs are roxygen #'
; comments.
;
; Limits: R has no type definitions this indexes (S4/R6 classes are calls);
; `->` assignments are not indexed.

(program
  (binary_operator
    lhs: [
      (identifier) @name
      (string (string_content) @name)
    ]
    operator: ["<-" "<<-" "="]) @definition.var)
