# clawswap

Runs a project's dev servers in one [zellij](https://zellij.dev) or [tmux](https://github.com/tmux/tmux) session, and
switches the checkout to another branch from a Stream Deck key, its web page or the command line. A switch
stops the servers, checks the branch out, runs only what the change needs (`mix deps.get`, migrations, `npm install`...)
and starts them again.

It's made for reviewing the branches Claude pushes: the list shows the open pull requests, newest commit first, with
each one's merge status, and lights up when the branch you're on has new commits. A branch can also carry a
walkthrough, a short script that plays its change in Chrome while you watch, and `clawswap test` runs the
project's own browser tests against the session's servers.

How it fits together (a picture, not commands to run): GitHub tells the daemon about new commits through
smee.io, and the daemon switches each project's session when you ask it to from a key, a page or the command line.

```text
GitHub
  │ webhook, on a push or a pull request
  ▼
smee.io
  │ SSE
  ▼
clawswap daemon on 127.0.0.1:27390  ◀── OpenDeck keys,
  (a watcher per project)                the pages at / and /p/<id>,
  │                                      clawswap switch
  ├── zellij/tmux ──▶ each project's server panes
  │
  └── log ──▶ clawswap watch, in each session's clawswap pane
```

One daemon on 127.0.0.1:27390 runs every project you've started with `clawswap up` (each under `/p/<id>`,
all of them listed at `/`), and the Stream Deck's keys follow whichever project is selected, or are pinned to one.

It's all Elixir: the daemon is an OTP app, its page is a [Hologram](https://hologram.page) page served by Phoenix,
and the OpenDeck plugin is an Elixir script.

**Docs: [cbishopvelti.github.io/clawswap](https://cbishopvelti.github.io/clawswap/)**

## Quick start

You need Elixir 1.19+ (OTP 26+), zellij 0.44+ or tmux 3.1+, and Node.js and (on Linux) inotify-tools for Hologram's
build. [Install](https://cbishopvelti.github.io/clawswap/install.html) has the details.
clawswap runs on the Elixir its `.tool-versions` pins, not your project's, so their versions don't have to match:
run `mise install` or `asdf install` in the clone once ([its own Elixir](https://cbishopvelti.github.io/clawswap/install.html#own-elixir)).

```bash
git clone https://github.com/cbishopvelti/clawswap
cd clawswap && mix deps.get && mix compile
ln -sf "$PWD/bin/clawswap" ~/.local/bin/clawswap   # any folder on your PATH

cd <path-to-your-project>
clawswap doctor   # checks what clawswap needs is installed, and prints the fix for what isn't
clawswap init     # writes a starter clawswap.exs from what it finds; check it and commit it
clawswap up       # starts the daemon if it isn't running, and opens the session; the page is at
                  # http://127.0.0.1:27390/p/<project>, and every project's at http://127.0.0.1:27390
```

New branches show up straight away with no setup of your own: the daemon keeps one smee.io channel for every
project, and adds each repo's GitHub webhook for it the first time the repo comes in (with your `gh` login, or
`GITHUB_TOKEN`). If GitHub says no, `clawswap smee` tries again and prints what to add by hand. With no token
at all it still listens on the channel (the page says "webhook unchecked" and names it), so a webhook you add by
hand that sends there works, and the page shows it on once its first delivery comes in.

Then pick a branch on the page, press a key, or run `clawswap switch <branch>` (a PR number works too:
`clawswap switch 23`). `clawswap down` ends the project's session and takes it out of the daemon;
`clawswap daemon stop` stops the daemon. `clawswap up staging` runs it with `clawswap.staging.yml` merged over the config
([override configs](https://cbishopvelti.github.io/clawswap/configuration.html#overrides)). Run `clawswap help` for every command, and `clawswap completion install` once for Tab
completion (`clawswap re<Tab>` gives `clawswap reload`); `clawswap reload` keeps it up to date.

A minimal `clawswap.exs` (or the same as `clawswap.yml`):

```elixir
[
  servers: [web: [command: "npm run dev", port: 5173]],
  steps: [[label: "npm install", when: ["package.json", "package-lock.json"], run: "npm install"]]
]
```

## Docs

| Page | What's in it |
| --- | --- |
| [Install](https://cbishopvelti.github.io/clawswap/install.html) | Requirements, the `clawswap` command, setting up a project and its webhook |
| [Use](https://cbishopvelti.github.io/clawswap/usage.html) | `clawswap up`, the session, zellij or tmux, several projects in one daemon, and every command |
| [Configuration](https://cbishopvelti.github.io/clawswap/configuration.html) | Every key of `clawswap.exs` / `clawswap.yml`, the page's config editor, ports, environment variables |
| [Switching](https://cbishopvelti.github.io/clawswap/switching.html) | What a switch and a pull do, step by step |
| [Branch page](https://cbishopvelti.github.io/clawswap/page.html) | Each project's page, the list of projects at `/`, its marks, and embedding it in your app (iframe, a Pull button, reload after a switch) |
| [API](https://cbishopvelti.github.io/clawswap/api.html) | The JSON API, to build your own control |
| [Stream Deck](https://cbishopvelti.github.io/clawswap/opendeck.html) | Branch, pull, walkthrough and project keys, through OpenDeck or from the page over WebHID; keys follow the selected project or are pinned to one |
| [Walkthroughs](https://cbishopvelti.github.io/clawswap/walkthroughs.html) | Scripts on a branch that play its change in Chrome, how to have Claude write them, and the debug panel that steps through one or drives Chrome by hand |
| [Browser tests](https://cbishopvelti.github.io/clawswap/testing.html) | `clawswap test`: your project's Wallaby suite, several browsers at once, against the session's servers |

[examples/](examples) has bmx's config (as [`.exs`](examples/bmx.exs) and [`.yml`](examples/bmx.yml)) and
[react-embed](examples/react-embed), an app that embeds the page, builds its own control on the API, and has
walkthroughs and browser tests.

## Working on clawswap

```bash
mix test                                                     # unit tests
mix test.integration                                         # browser tests, headless
CLAWSWAP_HEADLESS=0 CLAWSWAP_SLOW=800 mix test.integration   # watch them in Chrome
```

The browser tests drive [examples/react-embed](examples/react-embed) through a real session in zellij and tmux. They
need Chrome, chromedriver of the same major version, Node.js, tmux and zellij, and ports 27390, 27391 and 27393 free
([more](https://cbishopvelti.github.io/clawswap/walkthroughs.html#tests)).

CI ([.github/workflows/ci.yml](.github/workflows/ci.yml)) runs both on every pull request and push to `main`:
`mix format --check-formatted`, `mix compile --warnings-as-errors` and `mix test`, then the browser tests, headless,
in tmux and zellij.

The docs are plain HTML and CSS in [docs/](docs), published by GitHub Pages from `main`. Edit the pages there directly,
in the same change as the feature, and keep this README to the overview: anything longer belongs in the docs. The
sidebar is repeated in every page, so a new page goes in each page's nav.
