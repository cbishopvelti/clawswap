# clawswap

Runs a project's dev servers in one [zellij](https://zellij.dev) or [tmux](https://github.com/tmux/tmux) session, and switches the checkout to
another branch from a Stream Deck key, the watcher's web page or the command line. A switch stops the
servers, checks the branch out, runs only what the change needs (`mix deps.get`, migrations...) and
starts them again. It's made for reviewing the branches Claude pushes: the list shows the open pull
requests, newest commit first, with each one's merge status, and lights up when the branch you're on has
new commits.

It's written in Elixir. The watcher is an OTP app, its page is a [Hologram](https://hologram.page) page
served by Phoenix, and the OpenDeck plugin is an Elixir script. It started as bmx's `devtools/bmx-dev`;
the servers and steps that were written into it are now a `clawswap.exs` in each repo
([examples/bmx.exs](examples/bmx.exs) is bmx's).

```
GitHub ──webhook── smee.io ──SSE── clawswap watch (its own pane) ──zellij/tmux── server panes
                                        ▲ 127.0.0.1:27390
              OpenDeck "clawswap branch" keys, the Hologram page at /, clawswap switch
```

The full docs are in [docs/](docs/index.html), published at
[cbishopvelti.github.io/clawswap](https://cbishopvelti.github.io/clawswap/). They're plain HTML and CSS: edit the
pages in `docs/` directly.

## Setup

1. Elixir 1.19 or newer (Hologram needs it) with Erlang/OTP 26 or newer.
2. zellij 0.44 or newer (it added `--pane-id` to its CLI), or tmux 3.1 or newer. Ubuntu's zellij package
   may be older; take the binary from [the releases](https://github.com/zellij-org/zellij/releases) or
   `cargo install --locked zellij`. tmux's package is new enough (`sudo apt install tmux`). See
   [zellij or tmux](#zellij-or-tmux) for which one clawswap uses.
3. clawswap itself:
   ```bash
   git clone https://github.com/cbishopvelti/clawswap
   cd clawswap && mix deps.get && mix compile
   ```
   Clone it anywhere. The command is `bin/clawswap` in the clone, and you run it from inside *your
   project's* repo, since that's the repo it acts on (it finds its own folder by itself):
   ```bash
   cd <path-to-your-project>
   <path-to-clawswap>/bin/clawswap status
   ```
   To type just `clawswap`, link it into a folder on your `PATH`. Run this from the clone's root, so
   `$PWD` gives the link the full path:
   ```bash
   mkdir -p ~/.local/bin && ln -sf "$PWD/bin/clawswap" ~/.local/bin/clawswap
   ```
   If `clawswap` is then "command not found", `~/.local/bin` isn't on your `PATH` (check with
   `echo $PATH`): add `export PATH="$HOME/.local/bin:$PATH"` to `~/.bashrc` or `~/.zshrc` and open a new
   terminal. The rest of this README writes `clawswap`; without the link, use
   `<path-to-clawswap>/bin/clawswap` instead.
   Hologram's compiler bundles the page's JavaScript with esbuild, which it installs with npm the first
   time, so Node.js has to be there for `mix compile`. Nothing of clawswap's own is JavaScript. On Linux
   the page also needs inotify-tools (`sudo apt install inotify-tools`), which Hologram's dev server uses
   to watch its files.
4. In your project: `clawswap init` writes a starter `clawswap.exs` at the repo root, filled in from what
   it finds there: `mix phx.server` for a Phoenix app, `npm run dev` (or pnpm, yarn) for a `package.json`
   with a `dev` script, and no servers when it can't tell. Check the servers and steps (see
   [Configuration](#configuration)) and commit it.
5. The webhook, so new branches show up straight away:
   ```bash
   clawswap smee
   ```
   makes a smee.io channel, saves it for this checkout (in `.git/clawswap.json`, never committed) and
   prints what to put in GitHub's repo Settings > Webhooks > Add webhook: the channel as Payload URL,
   content type `application/json`, and the events Branch or tag creation, Branch or tag deletion, Pull
   requests and Pushes. Without it the watcher still looks every 15 minutes, and whenever you press a key.
6. Optional: PR titles. If the `gh` CLI is logged in (or `GITHUB_TOKEN` is set), the list shows the base
   branch and then the branches with an open pull request, newest commit first, labelled by PR title. Without a
   token it shows every branch by newest commit.
7. Optional: the Stream Deck keys, through [OpenDeck](#opendeck) or straight from the watcher's page in
   Chrome ([WebHID](#stream-deck-from-the-page-webhid)).
8. Optional: [walkthroughs](#walkthroughs) need Chrome and a chromedriver of the same major version.

## Use

Run these from inside your project's repo (not clawswap's clone). `bin/clawswap` runs `mix clawswap` in
clawswap's own folder, with your repo passed along.

```bash
clawswap up                # open (or re-attach to) the session
clawswap status            # the list the keys show, and the last switch
clawswap switch <branch>   # what a key press does
clawswap pull              # pull the current branch the same way
clawswap update            # the steps for what changed since they last ran (after a manual git pull)
clawswap update --all      # every step
clawswap walk [name...]    # play walkthroughs in Chrome (default: the ones this branch added)
clawswap browser           # open a dev Chrome at your app, that walkthroughs play in
clawswap layout            # the zellij layout up opens, to start your own from (tmux: its commands)
```

Before it opens a new session, `up` runs the config's `prepare` steps (containers, say) and then the steps
for whatever changed since they last ran (all of them the first time), so the servers don't start on stale
deps. It remembers the commit in `.git/clawswap.json`.

The session has a pane for each server, one called `clawswap` (the watcher; switch output shows here) and
one for each of the config's other `panes` (one with no command is an empty shell). Ctrl+Q leaves zellij (in tmux, Ctrl+B then D); `up` again
comes back.

The watcher serves a page at `http://127.0.0.1:27390` (the config's `port`): the same list as the keys, a
button on each branch that switches to it, and Pull. It updates as a switch runs, step by step. Your app's
dev page can embed it in an iframe, or build its own control on the [API](#api);
[examples/react-embed](examples/react-embed) does both.

The ⚙ at the top of that page opens the config editor (`/settings`) in a new window, so it works from an
app's iframe too. See [Editing the config from the page](#editing-the-config-from-the-page).

Each pane with a command runs it through `bin/keep`. When the command stops (Ctrl+C, or Ctrl+C twice for the
watcher and other BEAM programs), the pane keeps a shell instead of closing, and the up arrow brings the
command back. Without it, zellij closes a pane whose command has exited when you press Ctrl+C there, and
tmux closes it as soon as the command exits.

A pull is a switch to the same branch: fast-forward, the steps it needs, servers restarted. When there's
nothing new it does nothing and leaves the servers running.

## Configuration

`clawswap.exs` is evaluated as Elixir and returns a keyword list. You can write the same config as YAML in
`clawswap.yml` (or `clawswap.yaml`) instead; see [YAML](#yaml). clawswap uses the closest one, looking from
the folder you run it in up to the repo root, so a project in a subfolder can have its own. A folder with
more than one of them is an error rather than a silent pick: keep one. Only `servers` matters
to get going; everything else has a default. A command (`command`, `run`) is a string, run with `sh -c`,
or a list of the program and its arguments. A `cwd` is relative to the repo root.

| Key | Default | What it is |
| --- | --- | --- |
| `name` | the repo folder's name | The page's heading, and the zellij tab's (or tmux window's) name. |
| `session` | `name` | The zellij or tmux session's name. |
| `multiplexer` | detected | `:zellij` or `:tmux`; CLAWSWAP_MULTIPLEXER overrides it. See [zellij or tmux](#zellij-or-tmux). |
| `base` | origin's default branch | The branch listed first. Merged branches are marked against it. |
| `port` | `27390` | The watcher's page and API. Give each project its own to run several at once. The default is out of the way of the ports dev servers usually take (3000, 4000, 5173, 8000, 8080…) so it doesn't take the one your app wants. |
| `servers` | `[]` | `[name: [command:, cwd:, port:, match:]]`: what a switch stops and starts again, each in a pane of that name, in this order. With `port`, the switch makes sure the port is free before checking out (a server left running outside the session is sent TERM, then KILL). `match` (a Regex) finds the pane by its command if it has been renamed. |
| `panes` | `[]` | `[name: [command:, cwd:]]`: other panes, left running across switches (logs, a database). A pane with no `command` is an empty shell in its `cwd` (the repo root by default): `shell: []`, or `shell: {}` in YAML. |
| `prepare` | `[]` | Steps `up` runs before it starts a new session. A step with `wait_for_port:` waits (up to 30 s) for that port to open. |
| `steps` | `[]` | `[[name:, label:, when:, run:, cwd:]]`: what a switch (or `up`, or `update`) runs when files matching `when` changed, in this order. |
| `notes` | `[]` | `[[when:, message:]]`: said after a switch that changed matching files ("restart OpenDeck"). |
| `origins` | the servers' `localhost` ports | Browser origins allowed to call the API (your app's dev page, say). |
| `layout` | generated | A zellij layout file of your own (zellij only). Name the server panes as in `servers`, and run `clawswap watch` in one. |
| `restart_when` | | More paths that restart the watcher after a switch (it always restarts when the config changes). |
| `short_name` | drops `claude/` | `fn branch -> name end`: the name shown for a branch without a PR. |
| `walkthroughs` | `walkthroughs` | The folder of [walkthroughs](#walkthroughs), relative to the config's folder. |

`when` is a Regex, a path (`"mix.lock"` is that file at the root, `"migrations/"` anything under that
folder), a function of the path, or a list of those.

```elixir
[
  servers: [
    api: [command: "iex -S mix phx.server", cwd: "api", port: 4000],
    web: [command: "npm run dev", cwd: "web", port: 5173]
  ],
  panes: [db: [command: "docker compose up postgres"], shell: []],
  prepare: [[label: "Starting Postgres", run: "docker compose up -d postgres", wait_for_port: 5432]],
  steps: [
    [label: "mix deps.get", when: ["api/mix.exs", "api/mix.lock"], run: "mix deps.get", cwd: "api"],
    [label: "Migrating", when: "api/priv/repo/migrations/", run: "mix ecto.migrate", cwd: "api"],
    [label: "npm install", when: ["web/package.json", "web/package-lock.json"], run: "npm install", cwd: "web"]
  ]
]
```

### YAML

`clawswap.yml` has the same keys, with mappings for keyword lists. Order is kept, so servers and steps run
as written. Where `.exs` takes a Regex (`when`, `restart_when`, a server's `match`), write the string
between slashes, quoted so YAML leaves the backslashes alone: `'/^docker-compose\.ya?ml$/'`. Any other string
is a path as before. Where `.exs` takes a function, write it as Elixir in a string: `short_name` is always
Elixir, and a `when` or `restart_when` string starting with `fn ` or `&` is. It's evaluated when the config
loads, so a YAML config runs code just as a `clawswap.exs` does.

```yaml
short_name: 'fn branch -> String.replace_prefix(branch, "feature/", "") end'
steps:
  - {label: mix deps.get, when: ['&String.ends_with?(&1, ".lock")', mix.exs], run: mix deps.get}
```
[examples/bmx.yml](examples/bmx.yml) is [examples/bmx.exs](examples/bmx.exs) in YAML.

```yaml
servers:
  api: {command: iex -S mix phx.server, cwd: api, port: 4000, match: '/phx\.server/'}
  web: {command: npm run dev, cwd: web, port: 5173}
panes:
  db: {command: docker compose up postgres}
  shell: {}
steps:
  - {label: mix deps.get, when: [api/mix.exs, api/mix.lock], run: mix deps.get, cwd: api}
  - {label: Migrating, when: api/priv/repo/migrations/, run: mix ecto.migrate, cwd: api}
```

Environment variables override a few keys for one run: `CLAWSWAP_PORT`, `CLAWSWAP_BASE`,
`CLAWSWAP_SESSION`, `CLAWSWAP_MULTIPLEXER`, `CLAWSWAP_SMEE` (the channel) and `CLAWSWAP_CONFIG` (another config file, read as YAML when it ends in `.yml` or `.yaml`).


### Editing the config from the page

`http://127.0.0.1:27390/settings` (the ⚙ on the branch page) edits the config clawswap is running, in its
own format: the settings above as fields, and a row for each server, pane, step and note, which you can add,
remove and move up. Save checks that clawswap can load the result before writing it, then restarts the
watcher on it. The file is part of your repo, so commit the change: a switch refuses uncommitted changes.

- A `clawswap.exs` is changed in place: only the settings you changed are rewritten, and comments, the
  Elixir in it and keys the page doesn't show stay as they were. The file is printed by Elixir's formatter,
  at the repo's `.formatter.exs` line length or the file's own widest line.
- A `clawswap.yml` is written afresh, so comments in it are lost. Regexes and Elixir go back as strings.
- A field holding something a plain field can't (a function, a variable, a Regex with options, a command
  as a list) is shown in monospace as Elixir, or as the YAML's string of Elixir, and saved as written.
- In `when` fields, a line written `/like this/` is a Regex.

### zellij or tmux

clawswap runs the session in either. Set `multiplexer: :tmux` (or `:zellij`) in `clawswap.exs`, or
`multiplexer: tmux` in `clawswap.yml`, to choose, or `CLAWSWAP_MULTIPLEXER=tmux` for one run. Without either it picks the one you run it inside (so
`clawswap up` from a tmux window opens the session in tmux and switches to it), zellij for a config with
its own `layout`, then zellij if it's installed, then tmux.

In tmux the panes are laid out as in zellij, with each one's name on its border. A switch restarts a
server's pane with `respawn-pane`, so it keeps its place and size.

## What a switch does

1. Refuses if tracked files have uncommitted changes (commit or stash them).
2. Replaces each server's pane with a "Switching..." note, which ends the server, and makes sure its port
   is free.
3. `git checkout` the branch (a new local branch tracking origin's, or fast-forwards an existing one; a
   branch that has diverged fails here).
4. Runs the steps whose `when` matches a file that changed, in the config's order.
5. Starts the servers again, even after a failed step, so you're never left without them.

If the switch changed the config, the watcher restarts itself to load the new one.

## API

The watcher listens on `127.0.0.1:<port>`. It answers this machine only, and browsers only from `origins`.

```
GET  /state                    { project, base, current, dirty, upstream: { sha, behind }, branches: [{ branch, short, sha, merged?, pr? }], webhook, switch? }
POST /switch  { branch }       202, then follow /state's switch
POST /pull                     the checkout's branch; 202 (switch.pull), or "Already up to date"
POST /refresh                  look at GitHub now
POST /claude  { branch }       open the Claude Code thread that made the branch (the checkout's without one)
POST /walk    { name }         run a walkthrough here; 202, then follow /state's walk
```

Webhook deliveries are only taken as a hint to look again; the watcher never acts on their contents, since
anyone with the channel URL could post to it.

## OpenDeck

`<path-to-clawswap>/opendeck/install.sh` (it can be run from anywhere) copies the plugin into [OpenDeck](https://github.com/nekename/OpenDeck)'s plugins
folder (run it again after updating clawswap). OpenDeck starts it as `bin/plugin`, which runs
`plugin.exs` with `elixir`, so Elixir 1.18 or newer has to be on the PATH OpenDeck sees (a version
manager that only sets it up in your shell won't do). Quit OpenDeck fully (tray > Quit) and start it
again, then drag **clawswap branch** (category clawswap) onto keys. Keys on "next branch" share the list
in deck order, row by row; the first shows the base branch. A key can name a branch instead. A
**clawswap pull** key pulls the branch the checkout is on, and a **clawswap walkthrough** key plays the
checkout's walkthrough (the first one its branch added, else the first), showing its step and how it
went. A tap switches (or pulls, or plays) when you let go.

Holding a key for half a second opens the Claude Code thread that made its branch in your browser instead
(the checkout's branch, on a pull key): the project thread its PR's description links to, or else the
session in the `Claude-Session:` trailer of its newest commit. The watcher opens it with `xdg-open` (`open`
on a Mac).

Keys show the branch's PR number and title, with a bar for its state: green is the checkout, blue means
the checkout's branch has new commits on GitHub (press it to pull them), amber is a switch in progress
with its step, red a failed one. The checkout's key also has a green outline. The top right corner marks
the merge status, as the page's list does, in GitHub's colours: ⎇ the base branch, ● an open PR (green,
and the key is tinted green), ◌ a draft PR (grey), ✓ merged into the base (purple, tinted purple), ○
neither.

Each key has a Watcher setting, empty for `http://127.0.0.1:27390`. Point keys at another project's port to
drive several projects from one deck; keys on the same watcher share its list.

## Stream Deck from the page (WebHID)

Instead of OpenDeck, the watcher's page can drive the deck itself: open it in Chrome or Edge (WebHID is
Chromium only) and press **Connect Stream Deck**, then pick the deck. Its keys show the base branch and
then the newest PRs, in deck order, row by row, with the checkout's walkthrough and Pull on the last two keys. They look like the OpenDeck
keys; tapping one switches, and holding one opens its Claude Code thread. Chrome remembers the deck, so the page opens it again when it loads and
when the deck is plugged back in.

It works while that tab is open; close it and the keys stop. Quit OpenDeck first, since both would draw on
the same keys. It knows the Stream Deck (v2), MK.2 and XL; the Mini, Neo and + aren't supported yet. On
Linux your user needs access to the deck's hidraw device: the udev rule OpenDeck installs should cover that, or
add one for vendor `0fd9`. An iframe needs `allow="hid"` for it, so press Connect on the page itself (the
narrow embed menu leaves the button out).

It's Elixir too: `app/components/stream_deck.ex` calls `navigator.hid` and a canvas through Hologram's JS
interop.

## Walkthroughs

A walkthrough is a short Elixir script on a branch that drives a browser through the branch's change, so you
watch the feature instead of clicking through it yourself. Claude writes one with the branch, in the project's
`walkthroughs/` folder; once you've switched to the branch, press its ▶ on the watcher's page (the ones the
branch added come first, outlined) and Chrome opens on your machine and plays it, slowed down, with a
caption for each part and what it's about to click outlined. The page says whether it ran to the end, or
the line and caption where it stopped.

```elixir
# walkthroughs/badge-pull.exs
say "The badge now shows how far behind the branch is"
visit url(:web)                      # the config's web server: http://localhost:5173
see css(".badge button", text: "Pull")

say "Open the Branches menu: clawswap's page, in an iframe"
click "Branches"
in_frame "iframe[title=clawswap]", fn -> see "Current" end
```

```bash
clawswap walk                  # the walkthroughs this branch added or changed
clawswap walk badge-pull       # one by name (or several)
clawswap walk --headless       # without a window, to check one passes; exits 1 if it fails
```

The commands: `say`, `visit`, `url`, `click`, `fill_in`, `choose`, `press`, `see`, `refute_see`,
`in_frame`, `js`, `before_load`, `wait_until`, `pause`, `screenshot`, and Wallaby's queries (`css`,
`button`, `link`...). Each waits for what it looks for (10 s, or `timeout:`). See
[the docs](https://cbishopvelti.github.io/clawswap/walkthroughs.html) for each one, and
[examples/react-embed/walkthroughs](examples/react-embed/walkthroughs) for a whole one.

It drives Chrome through chromedriver ([Wallaby](https://hexdocs.pm/wallaby)), so both have to be installed,
at the same major version (chromedriver from your package manager, or both from
[Chrome for Testing](https://googlechromelabs.github.io/chrome-for-testing/):
`npx @puppeteer/browsers install chrome@stable chromedriver@stable`). `CLAWSWAP_CHROME` and
`CLAWSWAP_CHROMEDRIVER` name them when they aren't on the `PATH`. Without a display (Linux with no `DISPLAY`
or `WAYLAND_DISPLAY`: CI, Claude's cloud sessions) it runs headless. `CLAWSWAP_HEADLESS=1` or `0` forces it,
`CLAWSWAP_SLOW` sets the pause before each action (600 ms with a window, 0 without).

Each walkthrough opens a Chrome window of its own, unless a dev Chrome is open: `clawswap browser` starts
one at your app, with a profile of its own (kept in `~/.cache/clawswap/chrome`, so logins stay) and a
debugging port (27392, or `CLAWSWAP_BROWSER_PORT`). While it's open, walkthroughs play in a tab of it, the same tab each time, and leave
your other tabs alone. Chrome won't open that port on your everyday profile, which is why it's a separate
window. `CLAWSWAP_CHROME_DEBUGGER` points at another Chrome's debugging address, or `off` ignores the dev
Chrome.

To have Claude write them, put this in your repo's `CLAUDE.md`:

```
With each branch that changes what the app does, add walkthroughs/<short-name>.exs: a clawswap
walkthrough (https://cbishopvelti.github.io/clawswap/walkthroughs.html) that shows the change, with a
`say` caption before each part. Check it passes with `clawswap walk --headless` before pushing.
```

A walkthrough is code run on your machine, as a branch's config and steps are.

## Tests

```bash
mix test
```

The browser tests in `test/integration` are left out of that. They copy
[examples/react-embed](examples/react-embed) into a repo of its own with a few branches, run `clawswap up` for
it in zellij and in tmux, and drive Chrome, with the walkthrough commands, through the merge marks, the
Branches menu, a switch, the config editor, the ▶ buttons and a stand-in Stream Deck. They need Chrome,
chromedriver, Node.js, tmux and zellij, and ports 27390 and 27391 free:

```bash
mix test.integration                                        # headless
CLAWSWAP_HEADLESS=0 CLAWSWAP_SLOW=800 mix test.integration  # watch them in Chrome
tmux -L clawswap-tests attach                               # and the session's panes, from another terminal
```
