defmodule ClawswapWeb.Embeddable do
  @moduledoc """
  Lets a cross-origin isolated app embed clawswap. An app that sends `Cross-Origin-Embedder-Policy:
  require-corp` (for SharedArrayBuffer) can only frame a page, or load a script, that opts in with these
  headers. Chrome's credentialless iframes get round that; Firefox has none. The page loads nothing from
  another origin, so require-corp costs it nothing.
  """
  @behaviour Plug
  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    conn
    |> put_resp_header("cross-origin-embedder-policy", "require-corp")
    |> put_resp_header("cross-origin-resource-policy", "cross-origin")
  end
end
