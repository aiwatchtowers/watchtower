; JavaScript-only definitions, run after javascript.scm for plain
; JavaScript: class fields, which TypeScript's grammar names
; public_field_definition (typescript.scm). Not in upstream.

(class_body
  (field_definition property: (property_identifier) @name) @definition.field)
