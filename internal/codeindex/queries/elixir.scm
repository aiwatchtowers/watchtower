; Elixir definitions, from upstream tree-sitter-elixir tags.scm (spec
; §6.3), with the reference captures dropped. Changes from upstream:
; defprotocol is a protocol (upstream: module), defmacro/defmacrop are
; macros (upstream: function), and a def counts only directly in a module,
; protocol or impl body — not one quoted inside a function or a macro.
; Docs are the @moduledoc/@doc attributes, read in Go; a # comment never
; is one.
;
; Limits: module attributes, defstruct fields, defimpl blocks and
; multi-clause functions beyond their first clause's name (each clause is a
; row) are not told apart.

(call
  target: (identifier) @_kw
  (arguments [(alias) @name (dot) @name])
  (#eq? @_kw "defmodule")) @definition.module

(call
  target: (identifier) @_kw
  (arguments [(alias) @name (dot) @name])
  (#eq? @_kw "defprotocol")) @definition.protocol

(call
  target: (identifier) @_scope
  (do_block
    (call
      target: (identifier) @_kw
      (arguments
        [
          (identifier) @name
          (call target: (identifier) @name)
          (binary_operator left: (call target: (identifier) @name) operator: "when")
        ])
      (#any-of? @_kw "def" "defp" "defdelegate" "defguard" "defguardp" "defn" "defnp")) @definition.function)
  (#any-of? @_scope "defmodule" "defprotocol" "defimpl"))

(call
  target: (identifier) @_scope
  (do_block
    (call
      target: (identifier) @_kw
      (arguments
        [
          (identifier) @name
          (call target: (identifier) @name)
          (binary_operator left: (call target: (identifier) @name) operator: "when")
        ])
      (#any-of? @_kw "defmacro" "defmacrop")) @definition.macro)
  (#any-of? @_scope "defmodule" "defprotocol" "defimpl"))
