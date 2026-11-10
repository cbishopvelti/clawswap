defmodule ClawswapWeb.PanelPage do
  @moduledoc """
  /p/<id>/panel: a project's debug panel (`ClawswapWeb.DebugPanel`) on its own, filling the page at any width, for an app
  to frame in a sidebar of its own (docs/page.html#panel). The app folds its sidebar, so the panel's 🐞
  isn't shown.
  """

  use Hologram.Page

  alias ClawswapWeb.DebugPanel

  route("/p/:project/panel")
  param(:project, :string)

  layout(ClawswapWeb.PanelLayout)

  def init(params, component, _server), do: put_state(component, :id, params.project)

  def template do
    ~HOLO"""
    <DebugPanel cid="debug_panel" project={@id} foldable={false} />
    """
  end
end
