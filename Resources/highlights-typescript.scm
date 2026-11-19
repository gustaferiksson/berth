(lexical_declaration kind: "const" (variable_declarator name: (identifier) @constant))
(variable_declarator name: (identifier) @function value: [(arrow_function) (function_expression)])
(member_expression property: (property_identifier) @type (#match? @type "^[A-Z]"))
(regex) @string.regexp
(regex "/" @string.regexp)
