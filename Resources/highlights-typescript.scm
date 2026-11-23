(shorthand_property_identifier) @variable
(shorthand_property_identifier_pattern) @variable
((variable_declarator name: [
  (identifier) @variable
  (object_pattern [
    (shorthand_property_identifier_pattern) @variable
    (pair_pattern value: [(identifier) @variable (assignment_pattern left: (identifier) @variable)])
    (object_assignment_pattern left: (shorthand_property_identifier_pattern) @variable)
    (rest_pattern (identifier) @variable)
  ])
  (array_pattern [
    (identifier) @variable
    (assignment_pattern left: (identifier) @variable)
    (rest_pattern (identifier) @variable)
  ])
]) (#set! priority "declaration"))
((lexical_declaration kind: "const" (variable_declarator name: [
  (identifier) @constant
  (object_pattern [
    (shorthand_property_identifier_pattern) @constant
    (pair_pattern value: [(identifier) @constant (assignment_pattern left: (identifier) @constant)])
    (object_assignment_pattern left: (shorthand_property_identifier_pattern) @constant)
    (rest_pattern (identifier) @constant)
  ])
  (array_pattern [
    (identifier) @constant
    (assignment_pattern left: (identifier) @constant)
    (rest_pattern (identifier) @constant)
  ])
])) (#set! priority "declaration"))
((lexical_declaration kind: "const"
   (variable_declarator name: (identifier) @function value: [(arrow_function) (function_expression) (generator_function)]))
 (#set! priority "declaration"))
"=>" @keyword
(member_expression property: (property_identifier) @type (#match? @type "^[A-Z]"))
(regex) @string.regexp
(regex "/" @string.regexp)
