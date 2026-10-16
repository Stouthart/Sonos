<!-- 1.0 - Copyright (C) 2026 Stouthart. All rights reserved. -->

# Release notes

Highlights per version, newest first. 1.0 is the version distributed.

## 1.0 - October 2026

The first release: playback, sound and home theater settings of a Sonos speaker from the command line, over the speaker's local UPnP interface.

- **Two versions with the same options and output.** `soc.sh` sends its requests with Bash's built-in `/dev/tcp`, so no program is started per request; `soc-curl.sh` uses `curl`, for a 2-second timeout and `.local` names.
- **Nothing to install beyond Bash** (and `curl` for `soc-curl.sh`): no `jq`, no Python, no account. Both run on the Bash macOS ships, 3.2, as well as on newer ones.
- **Options:** `now`, `artwork`, `play`, `pause` (which toggles), `stop`, `next`, `prev`, `seek`, `shuffle`, `repeat` and `sleep`; `vol`, `mute`, `bass`, `treble` and `loudness`; for soundbars `night` (**Night Sound**), `speech` (**Speech Enhancement**), `height` (**Height level**) and `tv`; and `led` for the status light.
- **`now` shows the stream's quality** as `lossy` or `lossless`, with sample rate and bit depth. The speaker reports no bit rate, so there is none to show.
- **Fast:** a request takes about 13 ms with `soc.sh` and 18.5 ms with `curl`, on Wi-Fi.
  - `speech` reads or sets its two settings in one go: two connections at once in `soc.sh`, one `curl` run in `soc-curl.sh`.
  - A relative `seek` is a single request; the speaker itself stops at the start of the track.
  - A `shuffle` or `repeat` value that is already set sends nothing.
- **Careful with what goes out and comes back.**
  - Arguments are checked before anything is sent.
  - A reply must be the speaker's answer to the request, or the script reports `Invalid response from Sonos.` (exit `202`).
  - Track text is stripped of control characters before it is printed.
- **`SONOS_IP` is required**, with no default address. `soc.sh` needs the IPv4 address; `soc-curl.sh` also takes the `.local` name.
- **Setting names follow the Sonos app's US English wording.**
