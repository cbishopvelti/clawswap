defmodule Clawswap.Integration.ReloadTest do
  # The watcher's page in another app's iframe tells that app when a switch is done (after its servers
  # listen again), so the app can reload: docs/page.html#reload. The app here is a plain page on another
  # localhost port that frames the watcher's page and writes down what it hears, so the example app's own
  # reload (Vite's, when its server comes back) doesn't race the check.
  use ExUnit.Case, async: false

  import Clawswap.Walkthrough.Script
  alias Clawswap.Integration

  @moduletag :integration
  @moduletag timeout: 300_000
  @host_port 27393

  setup do
    Integration.compile!()
    project = Integration.up!(Integration.project!(), :tmux)

    File.write!(Path.join(project.dir, "host.html"), """
    <!doctype html>
    <title>host</title>
    <ul id="heard"></ul>
    <iframe src="http://localhost:27390/p/#{project.id}" title="clawswap"></iframe>
    <script>
      addEventListener("message", (e) => {
        if (e.origin !== "http://localhost:27390" || e.data?.clawswap !== "switched") return;
        const li = document.createElement("li");
        li.textContent = "Switched to " + e.data.branch;
        document.getElementById("heard").append(li);
      });
    </script>
    """)

    host =
      Port.open({:spawn_executable, System.find_executable("python3")}, [
        :binary,
        args: ["-m", "http.server", "-b", "127.0.0.1", to_string(@host_port)],
        cd: project.dir
      ])

    {:os_pid, pid} = Port.info(host, :os_pid)

    on_exit(fn ->
      System.cmd("kill", [to_string(pid)])
      Integration.down!(project)
    end)

    Integration.browser!(project)
    :ok
  end

  test "the framed page tells the app a switch is done" do
    say "An app that frames the watcher's page"
    visit "http://localhost:#{@host_port}/host.html"
    in_frame "iframe[title=clawswap]", fn -> see css("li", text: "new-heading") end
    refute js(~s{return document.getElementById("heard").textContent}) =~ "Switched"

    say "A switch from anywhere (the API here): the frame posts when the app's server is back"
    {202, _} = Integration.post!("/switch", %{branch: "claude/new-heading"})
    see "Switched to claude/new-heading", timeout: 120_000
    assert {:ok, %{"switch" => %{"phase" => "done", "doneAt" => at}}} = Integration.state()
    assert is_integer(at)
  end
end
