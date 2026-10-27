# clawswap's config for this example: a Vite + React dev server on 5173 that embeds the watcher's page.
# Paths are worked out from this file's folder, so it works both copied to the root of a repo of its own
# and left at examples/react-embed with CLAWSWAP_CONFIG pointing at it (see README.md).
here = __DIR__
in_clawswap = String.ends_with?(here, "examples/react-embed")
prefix = if in_clawswap, do: "examples/react-embed/", else: ""

[
  name: "react-embed",
  port: 8790,
  servers: [
    # The port makes the watcher let http://localhost:5173 call its API (BranchBadge does).
    web: [command: "npm run dev", cwd: here, port: 5173, match: ~r/npm run dev|vite/]
  ],
  prepare: [
    [label: "npm install", run: "test -d node_modules || npm install", cwd: here]
  ],
  steps: [
    [name: "npm", label: "npm install", when: [prefix <> "package.json", prefix <> "package-lock.json"], run: "npm install", cwd: here]
  ]
]
