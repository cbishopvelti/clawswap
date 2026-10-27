# The watcher runs its refreshes and switches under this supervisor; the app starts it, and so does this
# when the tests run without the app.
unless Process.whereis(Clawswap.TaskSupervisor), do: Task.Supervisor.start_link(name: Clawswap.TaskSupervisor)
# The browser tests (test/integration) need Chrome, chromedriver, tmux and zellij: mix test.integration.
ExUnit.start(exclude: [:integration])
