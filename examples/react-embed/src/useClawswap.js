import { useCallback, useEffect, useState } from "react";

// The watcher's page and API. Override with VITE_CLAWSWAP_URL (in .env.local, say) when the config's
// port isn't 27390.
export const CLAWSWAP_URL = import.meta.env.VITE_CLAWSWAP_URL || "http://localhost:27390";

// Follows GET /state: every 2 s while a switch runs, every 10 s otherwise. A switch restarts this page's
// own dev server, so failed fetches are expected for a moment and only show as "unreachable".
export function useClawswap() {
  const [state, setState] = useState(null);
  const [error, setError] = useState(null);

  const load = useCallback(async () => {
    try {
      const res = await fetch(`${CLAWSWAP_URL}/state`);
      if (!res.ok) throw new Error(`${res.status} ${res.statusText}`);
      setState(await res.json());
      setError(null);
    } catch (e) {
      setError(e.message || String(e));
    }
  }, []);

  const running = state?.switch?.phase === "running";

  useEffect(() => {
    load();
    const id = setInterval(load, running ? 2000 : 10000);
    return () => clearInterval(id);
  }, [load, running]);

  const post = useCallback(
    async (path, body) => {
      const res = await fetch(`${CLAWSWAP_URL}${path}`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body || {})
      });
      const json = await res.json().catch(() => ({}));
      if (!res.ok) throw new Error(json.error || `${res.status} ${res.statusText}`);
      if (json.branches) setState(json);
      return json;
    },
    []
  );

  return {
    state,
    error,
    reload: load,
    switchTo: (branch) => post("/switch", { branch }),
    pull: () => post("/pull"),
    refresh: () => post("/refresh").then(setState)
  };
}
