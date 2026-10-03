; Clojure definitions, written for Watchtower (tree-sitter-clojure ships
; no tags.scm; spec §6.3). Top-level forms by their head symbol: `ns` is
; a module; `defn`, `defn-` and `defmulti` are functions, `defmacro` a
; macro, `def` and `defonce` vars; `defprotocol` is a protocol and the
; signatures in it methods, `definterface` an interface, `defrecord` and
; `deftype` structs. A name keeps no metadata (`^:private x` gives x).
; Docs are the docstring after the name (read in Go), else the `;;`
; comments directly above. A signature is the form's first line.
;
; Limits: forms not at the top level (inside a `let`, a `comment` or a
; reader conditional), `defmethod` implementations, record fields and the
; methods a record or a type implements are not indexed; a head written
; with its namespace (`clojure.core/defn`) is not recognised.

(source (list_lit
  . value: (sym_lit name: (sym_name) @_kw)
  . value: (sym_lit name: (sym_name) @name)
  (#eq? @_kw "ns")) @definition.module)

(source (list_lit
  . value: (sym_lit name: (sym_name) @_kw)
  . value: (sym_lit name: (sym_name) @name)
  (#any-of? @_kw "defn" "defn-" "defmulti")) @definition.function)

(source (list_lit
  . value: (sym_lit name: (sym_name) @_kw)
  . value: (sym_lit name: (sym_name) @name)
  (#eq? @_kw "defmacro")) @definition.macro)

(source (list_lit
  . value: (sym_lit name: (sym_name) @_kw)
  . value: (sym_lit name: (sym_name) @name)
  (#any-of? @_kw "def" "defonce")) @definition.var)

(source (list_lit
  . value: (sym_lit name: (sym_name) @_kw)
  . value: (sym_lit name: (sym_name) @name)
  (#eq? @_kw "defprotocol")) @definition.protocol)

(source (list_lit
  . value: (sym_lit name: (sym_name) @_kw)
  . value: (sym_lit)
  value: (list_lit . value: (sym_lit name: (sym_name) @name)) @definition.method
  (#eq? @_kw "defprotocol")))

(source (list_lit
  . value: (sym_lit name: (sym_name) @_kw)
  . value: (sym_lit name: (sym_name) @name)
  (#eq? @_kw "definterface")) @definition.interface)

(source (list_lit
  . value: (sym_lit name: (sym_name) @_kw)
  . value: (sym_lit name: (sym_name) @name)
  (#any-of? @_kw "defrecord" "deftype")) @definition.struct)
