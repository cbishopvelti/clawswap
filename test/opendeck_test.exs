defmodule Clawswap.OpenDeckTest do
  use ExUnit.Case, async: true

  alias Clawswap.OpenDeck

  @home %{"HOME" => "/home/me"}

  test "finds the plugins folder: the override, the Flatpak's, XDG_CONFIG_HOME's, then ~/.config's" do
    assert OpenDeck.plugins_dir(Map.put(@home, "CLAWSWAP_OPENDECK_PLUGINS", "/x/plugins"), true) == "/x/plugins"
    assert OpenDeck.plugins_dir(@home, true) == "/home/me/.var/app/me.amankhanna.opendeck/config/opendeck/plugins"
    assert OpenDeck.plugins_dir(Map.put(@home, "XDG_CONFIG_HOME", "/cfg"), false) == "/cfg/opendeck/plugins"
    assert OpenDeck.plugins_dir(@home, false) == "/home/me/.config/opendeck/plugins"
  end

  test "starts OpenDeck by the override, the Flatpak, or opendeck on the PATH" do
    all = fn name -> "/usr/bin/#{name}" end
    none = fn _ -> nil end
    assert OpenDeck.start_command(Map.put(@home, "CLAWSWAP_OPENDECK_CMD", "~/OpenDeck.AppImage"), true, all) == "~/OpenDeck.AppImage"
    assert OpenDeck.start_command(@home, true, all) == "flatpak run me.amankhanna.opendeck"
    assert OpenDeck.start_command(@home, false, all) == "opendeck"
    assert OpenDeck.start_command(@home, false, none) == nil
  end

  test "copies the plugin, keeping bin/plugin executable" do
    dir = Path.join(System.tmp_dir!(), "clawswap-opendeck-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    target = OpenDeck.install(dir)
    assert File.exists?(Path.join(target, "manifest.json"))
    assert Bitwise.band(File.stat!(Path.join(target, "bin/plugin")).mode, 0o100) != 0
  end
end
