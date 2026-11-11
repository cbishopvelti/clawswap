defmodule ClawswapWeb.PanelLayout do
  @moduledoc "The layout of /panel (`ClawswapWeb.PanelPage`): the page alone, without the debug panel beside it."

  use Hologram.Component

  alias Hologram.UI.Runtime

  def template do
    ~HOLO"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>clawswap debug panel</title>
        <link rel="stylesheet" href="/clawswap.css" />
        <script src="/clawswap-focus.js" defer></script>
        <Runtime />
      </head>
      <body class="panel-only">
        <slot />
      </body>
    </html>
    """
  end
end
