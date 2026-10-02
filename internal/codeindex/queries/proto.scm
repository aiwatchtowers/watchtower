; Protocol Buffers definitions, written for Watchtower (tree-sitter-proto
; ships no tags.scm; spec §6.3). A message is a struct, its fields (map
; and oneof fields too) fields; an enum is an enum, its values consts; a
; service is an interface and its rpcs methods (container = the service).
; Nested messages and enums take the enclosing message as container.
; Docs are the `//` or `/* */` comments directly above (protoc's leading
; comments).
;
; Limits: the package is not a symbol (and no container); a oneof is not
; a symbol of its own (its fields take the message as container);
; proto2 `extend` blocks, groups and options are not indexed.

(message (message_name (identifier) @name)) @definition.struct

(enum (enum_name (identifier) @name)) @definition.enum

(service (service_name (identifier) @name)) @definition.interface

(rpc (rpc_name (identifier) @name)) @definition.method

(field (identifier) @name) @definition.field

(map_field (identifier) @name) @definition.field

(oneof_field (identifier) @name) @definition.field

(enum_field (identifier) @name) @definition.const
