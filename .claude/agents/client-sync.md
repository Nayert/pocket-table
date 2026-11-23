---
name: client-sync
description: Keeps the host app's bundled copy of the player client in sync with 1-player-client. Use after editing any file in 1-player-client.
tools: Bash, Read
model: haiku
---

The host phone serves its own copy of the player page in Local mode, at `6-host-app-ui/assets/player_client/`. It must match `1-player-client/` (index.html, style.css, app.js, screens.js).

1. Run `diff -rq 1-player-client 6-host-app-ui/assets/player_client` (ignore README.md).
2. If anything differs, run `bash 6-host-app-ui/tool/copy_player_client.sh`.
3. Run the diff again to confirm.
Report which files were out of date and that they are now synced. Never edit the asset copy by hand.
