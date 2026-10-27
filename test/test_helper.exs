# The watcher runs its refreshes and switches under this supervisor; the app starts it, and so does this
# when the tests run without the app.
unless Process.whereis(Clawswap.TaskSupervisor), do: Task.Supervisor.start_link(name: Clawswap.TaskSupervisor)
ExUnit.start()
