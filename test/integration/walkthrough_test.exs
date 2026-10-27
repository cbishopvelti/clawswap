defmodule Clawswap.Integration.WalkthroughTest do
  # Walkthroughs: the ▶ buttons on the page run one in the watcher, and `clawswap walk` runs one here.
  use ExUnit.Case, async: false

  import Clawswap.Walkthrough.Script
  alias Clawswap.Integration

  @moduletag :integration
  @moduletag timeout: 400_000

  setup do
    Integration.compile!()
    project = Integration.up!(Integration.project!(), :tmux)
    on_exit(fn -> Integration.down!(project) end)
    Integration.browser!(project)
    %{project: project}
  end

  test "a branch's new walkthrough runs from its ▶ on the page" do
    say "On main, the page lists the example's walkthrough"
    visit url(:clawswap)
    see button("▶ branches-menu")

    say "After a switch, the walkthrough the branch added comes first, marked new"
    {202, _} = Integration.post!("/switch", %{branch: "claude/new-heading"})
    Integration.wait_for_branch("claude/new-heading")
    see css(".walks button:first-of-type.new", text: "new-heading"), timeout: 20_000

    say "▶ runs it in a browser of its own, and the page follows it"
    click button("▶ new-heading")
    see css(".walk-status.passed", text: "new-heading ran to the end"), timeout: 120_000
  end

  test "clawswap walk runs the branch's new walkthroughs, or those named", %{project: project} do
    {202, _} = Integration.post!("/switch", %{branch: "claude/new-heading"})
    Integration.wait_for_branch("claude/new-heading")

    {out, 0} = Integration.clawswap(project, ["walk", "--headless"])
    assert out =~ "Walkthrough new-heading"
    assert out =~ "new-heading ran to the end"
    refute out =~ "branches-menu"

    {out, 0} = Integration.clawswap(project, ["walk", "branches-menu", "--headless"])
    assert out =~ "branches-menu ran to the end"
  end

  test "a failing walkthrough says where it stopped", %{project: project} do
    File.write!(Path.join(project.work, "walkthroughs/broken.exs"), """
    say "Looking for something that isn't there"
    visit url(:web)
    see "Not on the page", timeout: 1000
    """)

    {200, _} = Integration.post!("/refresh", %{})

    say "A walkthrough that fails shows the caption and line it stopped at"
    visit url(:clawswap)
    click button("▶ broken")
    see css(".walk-status.failed", text: ~s(line 3, at "Looking for something that isn't there": Didn't see "Not on the page")), timeout: 120_000

    {out, 1} = Integration.clawswap(project, ["walk", "broken", "--headless"])
    assert out =~ ~s(broken failed: line 3)
    assert out =~ "screenshot: "
  end

  # A dev Chrome needs a display (run the tests under xvfb-run to include this).
  if System.get_env("DISPLAY") not in [nil, ""] do
    test "with a dev Chrome open, walkthroughs play in one tab of it", %{project: project} do
      port = Clawswap.Walkthrough.Browser.dev_port()
      on_exit(fn -> Clawswap.Ports.free_port(port, fn _ -> :ok end) end)
      env = [{"CLAWSWAP_HEADLESS", nil}, {"CLAWSWAP_CHROME_DEBUGGER", nil}, {"XDG_CACHE_HOME", Path.join(project.dir, "cache")}]

      {out, 0} = Integration.clawswap(project, ["browser"], env)
      assert out =~ "Dev Chrome on 127.0.0.1:#{port}"
      assert tabs(port) == ["http://localhost:5173/"]

      for _ <- 1..2 do
        {out, 0} = Integration.clawswap(project, ["walk", "branches-menu"], env)
        assert out =~ "branches-menu ran to the end"
      end

      # The one it opened at the app, and the walkthroughs' tab, used both times.
      assert tabs(port) == ["http://localhost:5173/", "http://localhost:5173/"]
    end

    defp tabs(port) do
      {:ok, {_, _, body}} = :httpc.request(:get, {~c"http://127.0.0.1:#{port}/json/list", []}, [], body_format: :binary)
      for %{"type" => "page", "url" => url} <- JSON.decode!(body), do: url
    end
  end
end
