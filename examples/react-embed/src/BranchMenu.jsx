import { useEffect, useRef, useState } from "react";
import { CLAWSWAP_URL } from "./useClawswap.js";

// The watcher's own Hologram page in an iframe, as a dropdown from a button in the top bar (like bmx's
// branch menu). The frame stays loaded once opened, so it keeps following a switch while the menu is
// closed. A click outside or Escape closes it.
export default function BranchMenu() {
  const [open, setOpen] = useState(false);
  const [loaded, setLoaded] = useState(false);
  const [frameKey, setFrameKey] = useState(0);
  const ref = useRef(null);

  useEffect(() => {
    if (!open) return;
    const onMouseDown = (e) => ref.current && !ref.current.contains(e.target) && setOpen(false);
    const onKeyDown = (e) => e.key === "Escape" && setOpen(false);
    document.addEventListener("mousedown", onMouseDown);
    document.addEventListener("keydown", onKeyDown);
    return () => {
      document.removeEventListener("mousedown", onMouseDown);
      document.removeEventListener("keydown", onKeyDown);
    };
  }, [open]);

  return (
    <div className="branch-menu" ref={ref}>
      <button
        className={open ? "on" : ""}
        aria-expanded={open}
        title="Switch branch"
        onClick={() => {
          setOpen(!open);
          setLoaded(true);
        }}
      >
        ⎇ Branches ▾
      </button>
      {loaded && (
        <div className="branch-menu-panel" hidden={!open}>
          <div className="branch-menu-bar">
            <span>clawswap</span>
            <button title="Reload the menu" onClick={() => setFrameKey((k) => k + 1)}>↻</button>
            <a href={CLAWSWAP_URL} target="_blank" rel="noreferrer" title="Open the full page">↗</a>
            <button title="Close" onClick={() => setOpen(false)}>✕</button>
          </div>
          <iframe key={frameKey} src={CLAWSWAP_URL} title="clawswap" />
        </div>
      )}
    </div>
  );
}
