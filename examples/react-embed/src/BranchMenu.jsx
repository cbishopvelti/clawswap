import { useEffect, useRef, useState } from "react";
import { CLAWSWAP_URL } from "./useClawswap.js";

// The watcher's own Hologram page in an iframe, as a dropdown from a button in the top bar (like bmx's
// branch menu). The frame loads with the page and is only hidden while the menu is closed, so it keeps
// following a switch, and it tells clawswap when this tab comes into view, so the Stream Deck's keys show
// this project as soon as you switch to the tab, menu opened or not. A click outside or Escape closes it.
export default function BranchMenu() {
  const [open, setOpen] = useState(false);
  const [frameKey, setFrameKey] = useState(0);
  const ref = useRef(null);

  // When a switch is done (its servers listen again), the framed page says so, and the app reloads. Vite
  // would reload anyway when its server comes back; an app without that (Phoenix, say) needs this. A key
  // pressed in the frame never reaches this page, so the framed page says Escape too.
  useEffect(() => {
    const onMessage = (e) => {
      if (e.origin !== new URL(CLAWSWAP_URL).origin) return;
      if (e.data?.clawswap === "switched") location.reload();
      if (e.data?.clawswap === "escape") setOpen(false);
    };
    addEventListener("message", onMessage);
    return () => removeEventListener("message", onMessage);
  }, []);

  useEffect(() => {
    if (!open) return;
    // On window, in the capture phase, so nothing in the page can stop them.
    const onPointerDown = (e) => ref.current && !ref.current.contains(e.target) && setOpen(false);
    const onKeyDown = (e) => e.key === "Escape" && setOpen(false);
    addEventListener("pointerdown", onPointerDown, true);
    addEventListener("keydown", onKeyDown, true);
    return () => {
      removeEventListener("pointerdown", onPointerDown, true);
      removeEventListener("keydown", onKeyDown, true);
    };
  }, [open]);

  return (
    <div className="branch-menu" ref={ref}>
      <button
        className={open ? "on" : ""}
        aria-expanded={open}
        title="Switch branch"
        onClick={() => setOpen(!open)}
      >
        ⎇ Branches ▾
      </button>
      <div className="branch-menu-panel" hidden={!open}>
        <div className="branch-menu-bar">
          <span>clawswap</span>
          <button title="Reload the menu" onClick={() => setFrameKey((k) => k + 1)}>↻</button>
          <a href={CLAWSWAP_URL} target="_blank" rel="noreferrer" title="Open the full page">↗</a>
          <button title="Close" onClick={() => setOpen(false)}>✕</button>
        </div>
        <iframe key={frameKey} src={CLAWSWAP_URL} title="clawswap" />
      </div>
    </div>
  );
}
