import { useState } from "react";
import BranchBadge from "./BranchBadge.jsx";
import { CLAWSWAP_URL } from "./useClawswap.js";

// A stand-in app with clawswap embedded two ways: the watcher's own Hologram page in an iframe (docked or
// floating), and BranchBadge, which talks to the JSON API directly.
export default function App() {
  const [mode, setMode] = useState("docked");
  const [count, setCount] = useState(0);
  const [frameKey, setFrameKey] = useState(0);

  return (
    <div className={`app ${mode}`}>
      <header className="topbar">
        <strong>Example app</strong>
        <BranchBadge />
        <div className="modes">
          {["docked", "floating", "hidden"].map((m) => (
            <button key={m} className={m === mode ? "on" : ""} onClick={() => setMode(m)}>
              {m}
            </button>
          ))}
        </div>
      </header>

      <main className="content">
        <h1>Your app goes here</h1>
        <p>
          This page is a stand-in for a project clawswap manages. Edit <code>src/App.jsx</code> on a branch,
          push it, and switch to it from the panel: clawswap stops this dev server, checks the branch out,
          runs <code>npm install</code> if the lockfile changed, and starts it again.
        </p>
        <p>
          State that lives only in this page resets on a switch, since the dev server restarts:{" "}
          <button onClick={() => setCount((c) => c + 1)}>clicked {count} times</button>
        </p>
        <p className="muted">
          The panel is <code>{CLAWSWAP_URL}</code> in an iframe. If it stays blank, the watcher isn't
          running (<code>clawswap up</code>), or it refuses to be framed.
        </p>
      </main>

      {mode !== "hidden" && (
        <aside className="clawswap">
          <div className="clawswap-bar">
            <span>clawswap</span>
            <button title="Reload the panel" onClick={() => setFrameKey((k) => k + 1)}>↻</button>
            <a href={CLAWSWAP_URL} target="_blank" rel="noreferrer">open ↗</a>
          </div>
          <iframe key={frameKey} src={CLAWSWAP_URL} title="clawswap" />
        </aside>
      )}
    </div>
  );
}
