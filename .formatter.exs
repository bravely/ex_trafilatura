# Used by "mix format"
[
  # `tools/` is maintainer tooling and never ships, but the Elixir in it is read
  # and edited like the rest, so `mix format --check-formatted` covers it too.
  inputs: ["{mix,.formatter}.exs", "{config,lib,test,tools}/**/*.{ex,exs}"]
]
