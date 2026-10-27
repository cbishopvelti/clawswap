import { useState } from "react";
import BranchBadge from "./BranchBadge.jsx";
import BranchMenu from "./BranchMenu.jsx";
import { CLAWSWAP_URL } from "./useClawswap.js";

// A stand-in app with clawswap embedded two ways: the watcher's own Hologram page in an iframe, as a
// dropdown menu (BranchMenu), and BranchBadge, which talks to the JSON API directly.
export default function App() {
  const [count, setCount] = useState(0);

  return (
    <div className="app">
      <header className="topbar">
        <strong>Example app</strong>
        <BranchBadge />
        <BranchMenu />
      </header>

      <main className="content">
        <h1>Your app goes here</h1>
        <p>
          This page is a stand-in for a project clawswap manages. Edit <code>src/App.jsx</code> on a branch,
          push it, and switch to it from the Branches menu: clawswap stops this dev server, checks the branch
          out, runs <code>npm install</code> if the lockfile changed, and starts it again.
        </p>
        <p>
          State that lives only in this page resets on a switch, since the dev server restarts:{" "}
          <button onClick={() => setCount((c) => c + 1)}>clicked {count} times</button>
        </p>
        <p className="muted">
          The Branches menu is <code>{CLAWSWAP_URL}</code> in an iframe. If it stays blank, the watcher isn't
          running (<code>clawswap up</code>), or it refuses to be framed.
        </p>
      </main>
    </div>
  );
}
