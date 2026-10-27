import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// Port 5173 on localhost: clawswap.exs names it as the server's port, so the watcher lets this page call
// its API, and localhost (not 127.0.0.1) keeps the page and the embedded watcher on the same site.
export default defineConfig({
  plugins: [react()],
  server: { host: "localhost", port: 5173, strictPort: true }
});
