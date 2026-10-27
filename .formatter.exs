# Walkthrough scripts (and the browser tests) read as a list of commands, so they go without parens.
walkthrough = [
  say: 1,
  visit: 1,
  click: 1,
  click: 2,
  fill_in: 2,
  choose: 2,
  choose: 3,
  press: 1,
  see: 1,
  see: 2,
  refute_see: 1,
  refute_see: 2,
  in_frame: 2,
  pause: 1,
  before_load: 1
]

[
  inputs: ["{mix,.formatter}.exs", "{config,lib,app,test,examples}/**/*.{ex,exs}", "opendeck/**/*.{ex,exs}"],
  line_length: 160,
  locals_without_parens: walkthrough,
  export: [locals_without_parens: walkthrough]
]
