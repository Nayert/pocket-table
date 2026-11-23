#!/usr/bin/env bash
# Copies the player web page (layer 1) into this app's assets, so the phone
# can serve it in Local mode. Run after editing anything in 1-player-client.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
src="$here/../1-player-client"
dest="$here/assets/player_client"
mkdir -p "$dest"
cp "$src"/index.html "$src"/style.css "$src"/app.js "$src"/screens.js "$dest"/
echo "Copied player client into $dest"
