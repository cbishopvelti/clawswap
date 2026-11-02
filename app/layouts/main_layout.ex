defmodule ClawswapWeb.MainLayout do
  use Hologram.Component

  alias ClawswapWeb.DebugPanel
  alias Hologram.UI.Runtime

  def template do
    ~HOLO"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>clawswap</title>
        <link rel="stylesheet" href="/clawswap.css" />
        <Runtime />
      </head>
      <body>
        <div class="with-panel">
          <div class="page"><slot /></div>
          <DebugPanel cid="debug_panel" />
        </div>
      </body>
    </html>
    """
  end
end
