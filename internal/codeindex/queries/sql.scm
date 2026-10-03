; SQL definitions, written for Watchtower (tree-sitter-sql ships no
; tags.scm; spec §6.3). Tables and views (materialized too) are types,
; their columns fields; indexes and triggers consts; `CREATE FUNCTION` a
; function and `CREATE TYPE` a type. A schema-qualified name keeps its
; last part (`acme.items` gives items). Docs are the `--` comments
; directly above a statement; goose annotations (`-- +goose Up`) are
; skipped, and the statements after them parse as usual.
;
; SQLite triggers (`… BEGIN … END`), which the grammar cannot parse, are
; rewritten in Go before parsing (same length, positions unchanged) into a
; trigger tail it does parse, so the trigger is found and the error does
; not swallow the statements after it.
;
; Limits: the grammar is generic SQL with a PostgreSQL lean; a statement
; it fails on is not indexed (and its error can reach into the next
; statement); a column named with a keyword (`key`) is lost; procedures,
; sequences, schemas and `ALTER TABLE … ADD COLUMN` columns are not
; indexed.

(create_table
  [(keyword_table) (keyword_exists)] . (object_reference name: (identifier) @name)) @definition.type

(create_view
  [(keyword_view) (keyword_exists)] . (object_reference name: (identifier) @name)) @definition.type

(create_materialized_view
  [(keyword_view) (keyword_exists)] . (object_reference name: (identifier) @name)) @definition.type

(create_index column: (identifier) @name) @definition.const

(create_trigger
  [(keyword_trigger) (keyword_exists)] . (object_reference name: (identifier) @name)) @definition.const

(create_function
  [(keyword_function) (keyword_exists)] . (object_reference name: (identifier) @name)) @definition.function

(create_type
  [(keyword_type) (keyword_exists)] . (object_reference name: (identifier) @name)) @definition.type

(column_definition name: (identifier) @name) @definition.field
