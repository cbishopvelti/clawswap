// Tells the daemon which project's page you're looking at (POST /p/<id>/focus), which selects it, so the
// Stream Deck keys that follow the selected project show it, and a tool such as a notes app can follow the
// project you're working on through GET /focus/events. It reports on load, when its tab comes back into
// view, and when the page itself takes focus.
//
// The branch page and the debug panel load it, framed in your app's dev chrome or opened on their own. An
// app's own page can load it too, naming its project, so its tab counts before any clawswap frame in it
// has loaded (a Branches menu that loads its frame when first opened):
//
//   <script src="http://localhost:27390/clawswap-focus.js" data-project="myapp" defer></script>
(() => {
  const script = document.currentScript;
  const project = script && script.dataset.project;
  let url;

  if (project) {
    url = new URL(`/p/${encodeURIComponent(project)}/focus`, script.src).href;
  } else {
    const match = location.pathname.match(/^\/p\/([^/]+)/);
    if (!match) return;
    url = `/p/${match[1]}/focus`;
  }

  // From an app's page this is another origin, which the daemon lets in for its project's servers
  // (a preflight first); keepalive is only for the daemon's own pages, as a preflighted keepalive
  // request isn't something every browser sends.
  const own = new URL(url, location.href).origin === location.origin;
  const report = () => {
    if (document.visibilityState !== "visible") return;
    const options = { method: "POST", headers: { "Content-Type": "application/json" }, body: "{}" };
    fetch(url, own ? { ...options, keepalive: true } : options).catch(() => {});
  };

  report();
  document.addEventListener("visibilitychange", report);
  window.addEventListener("focus", report);
})();
