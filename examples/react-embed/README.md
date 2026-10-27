# react-embed

A Vite + React app to try embedding clawswap in a project's own page. It's a test target, so it's
JavaScript; clawswap itself isn't. It embeds clawswap two ways:

- **The watcher's page in an iframe** (`http://localhost:8790`), docked beside the app or floating over it.
- **`BranchBadge`**, a control of the app's own in the top bar, built on the watcher's JSON API
  (`GET /state`, `POST /switch`, `POST /pull`): the checkout's branch as a picker, Pull with how far
  behind it is, and the step a switch is on. It checks that the API's CORS lets the app's origin in.

`clawswap.exs` runs `npm run dev` as the `web` server on 5173 and runs `npm install` when
`package.json` or `package-lock.json` change. Because 5173 is the server's port, the watcher allows
`http://localhost:5173` to call its API without an `origins` entry.

## Try it

clawswap needs a repo to manage, with branches on a remote, so give the example one of its own:

```bash
cp -r examples/react-embed ~/react-embed && cd ~/react-embed
git init -b main && git add . && git commit -m "react-embed"
gh repo create react-embed --private --source . --push   # or any remote
clawswap up
```

Open `http://localhost:5173`. Push a branch that changes `src/App.jsx` (or adds a dependency), then
switch to it from the panel or the badge: the dev server stops, the branch is checked out, `npm install`
runs if the lockfile changed, and the page comes back with the change.

Without clawswap running, `npm install && npm run dev` still shows the app, with "clawswap unreachable"
in the top bar and an empty panel.

It can also run in place, in a clone of clawswap that isn't the one clawswap runs from (a switch checks
out the whole repo, and the branch has to have this folder):

```bash
CLAWSWAP_CONFIG=examples/react-embed/clawswap.exs clawswap up
```

## Things this tests

- **Framing.** Neither clawswap's endpoint nor Hologram sets `X-Frame-Options` or `frame-ancestors`, so
  the page frames. If that changes, the panel goes blank and the browser console says why.
- **Same site.** Hologram's session cookie is `SameSite=Lax`. `localhost:5173` and `localhost:8790` are the
  same site (ports don't count), so the framed page gets its cookie. Mixing `localhost` and `127.0.0.1`
  makes them cross-site, so use `localhost` for both (Vite is pinned to it in `vite.config.js`).
- **Restarts.** A switch kills this dev server, so the app reloads and its state resets, while the
  framed page keeps its own connection to the watcher and follows the switch to the end.
- **Another port.** Set `VITE_CLAWSWAP_URL` (in `.env.local`) when `clawswap.exs`'s `port` isn't 8790.
