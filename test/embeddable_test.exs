defmodule ClawswapWeb.EmbeddableTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  # Brill's pages are cross-origin isolated: without these, Firefox won't show clawswap's page in their
  # Branches menu.
  test "a cross-origin isolated app can frame the page and load its scripts" do
    conn = ClawswapWeb.Embeddable.call(conn(:get, "/p/brill"), [])

    assert get_resp_header(conn, "cross-origin-embedder-policy") == ["require-corp"]
    assert get_resp_header(conn, "cross-origin-resource-policy") == ["cross-origin"]
  end
end
