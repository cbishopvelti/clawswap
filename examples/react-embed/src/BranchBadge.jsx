import { useState } from "react";
import { useClawswap } from "./useClawswap.js";

// A small control of the app's own, built on the watcher's JSON API rather than its page: the branch the
// checkout is on, what a switch is doing, and a picker to switch. Checks that CORS lets this origin in.
export default function BranchBadge() {
  const { state, error, switchTo, pull } = useClawswap();
  const [message, setMessage] = useState(null);

  if (error && !state) {
    return <div className="badge off" title={error}>clawswap unreachable</div>;
  }
  if (!state) return <div className="badge">clawswap…</div>;

  const sw = state.switch;
  const phase = sw?.phase;
  const act = (p) => p.then(() => setMessage(null), (e) => setMessage(e.message));

  return (
    <div className={`badge ${phase || ""} ${state.upstream?.behind ? "behind" : ""}`}>
      <span className="label">branch</span>
      <select
        value={state.current || ""}
        disabled={phase === "running"}
        onChange={(e) => act(switchTo(e.target.value))}
      >
        {state.current && !state.branches.some((b) => b.branch === state.current) && (
          <option value={state.current}>{state.current}</option>
        )}
        {state.branches.map((b) => (
          <option key={b.branch} value={b.branch}>
            {b.pr ? `#${b.pr.number} ${b.pr.title}` : b.short}
          </option>
        ))}
      </select>
      <button disabled={phase === "running"} onClick={() => act(pull())}>
        Pull{state.upstream?.behind ? ` (${state.upstream.behind})` : ""}
      </button>
      {phase === "running" && <span className="status">→ {sw.target}: {sw.step || "starting"}</span>}
      {phase === "failed" && <span className="status">{sw.error}</span>}
      {state.dirty && <span className="status">uncommitted changes</span>}
      {(message || error) && <span className="status">{message || error}</span>}
    </div>
  );
}
