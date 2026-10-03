; HCL / Terraform definitions, written for Watchtower (tree-sitter-hcl
; ships no tags.scm; spec §6.3). Top-level Terraform blocks: a `resource`
; and a `data` block are vars named by their two labels joined with a dot
; (`resource "aws_x" "name"` gives aws_x.name, joined in Go); a `module`
; is a module, a `variable` a var and an `output` a const, each named by
; its label; the attributes of a `locals` block are vars, and so are the
; top-level attributes of a plain HCL or .tfvars file. Docs are the `#`,
; `//` or `/* */` comments directly above a block (HCL has no doc-comment
; syntax).
;
; Limits: `provider`, `terraform` and other block types (Nomad's `job`,
; Packer's `source`) are not indexed, nor are nested blocks (`lifecycle`)
; and the attributes inside a block other than `locals`; a data source is
; named without Terraform's `data.` reference prefix.

(config_file (body
  (block
    (identifier) @_kw
    .
    (string_lit (template_literal) @name)
    .
    (string_lit)
    (#any-of? @_kw "resource" "data")) @definition.var))

(config_file (body
  (block
    (identifier) @_kw
    .
    (string_lit (template_literal) @name)
    (#eq? @_kw "module")) @definition.module))

(config_file (body
  (block
    (identifier) @_kw
    .
    (string_lit (template_literal) @name)
    (#eq? @_kw "variable")) @definition.var))

(config_file (body
  (block
    (identifier) @_kw
    .
    (string_lit (template_literal) @name)
    (#eq? @_kw "output")) @definition.const))

(config_file (body
  (block
    (identifier) @_kw
    (body (attribute (identifier) @name) @definition.var)
    (#eq? @_kw "locals"))))

(config_file (body (attribute (identifier) @name) @definition.var))
