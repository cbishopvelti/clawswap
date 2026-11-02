defmodule ClawswapWeb.PanelPage do
  @moduledoc """
  /panel: the debug panel (`ClawswapWeb.DebugPanel`) on its own, filling the page at any width, for an app
  to frame in a sidebar of its own (docs/page.html#panel). The app folds its sidebar, so the panel's 🐞
  isn't shown.
  """

  use Hologram.Page

  alias ClawswapWeb.DebugPanel

  route("/panel")

  layout(ClawswapWeb.PanelLayout)

  def init(_params, component, _server), do: component

  def template do
    ~HOLO"""
    <DebugPanel cid="debug_panel" foldable={false} />
    """
  end
end
