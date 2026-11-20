(lexical_declaration kind: "const" (variable_declarator name: (identifier) @variable.local (#not-match? @variable.local "^[A-Z_][A-Z\\d_]+$")))
(program (lexical_declaration kind: "const" (variable_declarator name: (identifier) @constant)))
(program (export_statement (lexical_declaration kind: "const" (variable_declarator name: (identifier) @constant))))
(shorthand_property_identifier) @variable
(shorthand_property_identifier_pattern) @variable
"=>" @keyword
(variable_declarator name: (identifier) @function value: [(arrow_function) (function_expression)])
(member_expression property: (property_identifier) @type (#match? @type "^[A-Z]"))
(regex) @string.regexp
(regex "/" @string.regexp)
