#!/bin/sh
# Copies the clawswap plugin into OpenDeck's plugins folder (the Flatpak's if that's how OpenDeck is
# installed). OpenDeck doesn't reliably follow a symlink there, so it's a copy: run this again after
# pulling changes. OpenDeck only starts plugins when it launches, so quit it fully (tray > Quit) and start
# it again afterwards.
set -eu
src="$(cd "$(dirname "$0")" && pwd)/dev.clawswap.sdPlugin"
if [ -d "$HOME/.var/app/me.amankhanna.opendeck" ]; then
  dir="$HOME/.var/app/me.amankhanna.opendeck/config/opendeck/plugins"
else
  dir="${XDG_CONFIG_HOME:-$HOME/.config}/opendeck/plugins"
fi
mkdir -p "$dir"
rm -rf "$dir/dev.clawswap.sdPlugin"
cp -R "$src" "$dir/dev.clawswap.sdPlugin"
echo "Copied the plugin to $dir/dev.clawswap.sdPlugin"
echo "Quit OpenDeck fully (tray > Quit), start it again, then find \"clawswap branch\" under clawswap in its actions list."
