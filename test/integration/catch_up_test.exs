defmodule Clawswap.Integration.CatchUpTest do
  # PR #78: `clawswap up` opens the session at once and leaves the catch-up to its clawswap pane. The
  # daemon drops a project no pane follows soon after up, so the pane has to follow the project while it
  # catches up, or a slow step takes the project's page (and its Stream Deck keys) away until it's done.
  use ExUnit.Case, async: false

  alias Clawswap.Integration

  @moduletag :integration
  @moduletag timeout: 300_000
  # Down from the daemon's two minutes, for the test.
  @first_attach_ms 2_000

  setup do
    Integration.compile!()
    project = Integration.project!()
    on_exit(fn -> Integration.down!(project) end)
    %{project: project}
  end

  test "a slow catch-up keeps the project in the daemon", %{project: project} do
    File.write!(Path.join(project.work, "clawswap.slow.exs"), """
    [prepare: [[label: "Slow prepare", run: "sleep 12"]]]
    """)

    # up! names the project the API calls go to, but it only returns once the catch-up is done.
    :persistent_term.put({Integration, :id}, project.id)
    up = Task.async(fn -> Integration.up!(project, :tmux, "main", ["slow"], [{"CLAWSWAP_FIRST_ATTACH_MS", "#{@first_attach_ms}"}]) end)

    Integration.wait_for(fn -> match?({:ok, _}, Integration.state()) end, 120_000, "the project on the daemon")
    # Well past the time the daemon gives a project for its pane to follow it, with the catch-up still going.
    Process.sleep(@first_attach_ms * 3)
    refute Integration.http_ok?("http://localhost:27391/"), "the catch-up was meant to still be running"
    assert {:ok, %{"current" => %{"branch" => "main"}}} = Integration.state()

    Task.await(up, 180_000)
    assert {:ok, %{"current" => %{"branch" => "main"}}} = Integration.state()
  end
end
