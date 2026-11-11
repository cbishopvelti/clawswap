// Tells the daemon which project's page you're looking at (POST /p/<id>/focus), so a tool such as a notes
// app can follow the project you're working on through GET /focus/events. The branch page and the debug
// panel load it, framed in your app's dev chrome or opened on their own, so an app that embeds clawswap
// reports its project with no code of its own: on load, when its tab comes back into view, and when the
// page itself takes focus.
(() => {
  const match = location.pathname.match(/^\/p\/([^/]+)/);
  if (!match) return;

  const path = `/p/${match[1]}/focus`;
  const report = () => {
    if (document.visibilityState !== "visible") return;
    fetch(path, { method: "POST", headers: { "Content-Type": "application/json" }, body: "{}", keepalive: true }).catch(() => {});
  };

  report();
  document.addEventListener("visibilitychange", report);
  window.addEventListener("focus", report);
})();
