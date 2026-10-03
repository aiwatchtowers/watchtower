; Erlang definitions, written for Watchtower (tree-sitter-erlang ships no
; tags.scm; spec §6.3). `-module` is a module; a function is a function,
; indexed at its first clause (a following declaration of the same name
; and arity is dropped in Go); `-record` is a struct, its fields fields;
; `-type` and `-opaque` are types; `-define` is a macro. Docs are the
; `%%` comments directly above a function or its `-spec` (EDoc's `@doc`
; tag dropped).
;
; Limits: names carry no arity (`add/2` and `add/3` are two rows named
; add); `-callback` declarations, anonymous funs and OTP 27 `-doc`
; attributes are not indexed; a single `%` comment is not a doc.

(module_attribute name: (atom) @name) @definition.module

(fun_decl . clause: (function_clause name: (atom) @name)) @definition.function

(record_decl name: (atom) @name) @definition.struct

(record_field name: (atom) @name) @definition.field

(type_alias name: (type_name name: (atom) @name)) @definition.type

(opaque name: (type_name name: (atom) @name)) @definition.type

(pp_define lhs: (macro_lhs name: [(var) (atom)] @name)) @definition.macro
