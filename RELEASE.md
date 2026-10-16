<!-- 1.1 - Copyright (C) 2026 Stouthart. All rights reserved. -->

# Release notes

Highlights per version, newest first. 1.1 is the version distributed.

## 1.1 - October 2026

Product details, files from a network share, and stricter checks on replies.

- **New `about`**, printing the speaker's details from its device description: model, room, Sonos software version and build, hardware version, serial number, MAC address and API version. `about <key>` prints one field, such as `about displayVersion`, and takes any field the speaker describes; one it doesn't have prints nothing. The speaker sends that description in chunks, which `soc.sh` joins in builtin code.
- **New `file`**, playing one file from an SMB share given as `//host/share/path`, e.g. `soc.sh file //192.168.1.10/podcasts/episode.mp3`. The speaker fills in title, artist and album from the file's tags, and `now` shows the source as `file`. Files report no sample rate or bit depth, so `now` shows the format from the file's MIME type instead, such as `mpeg`.
- **`sleep` moved to Other** in the usage screen, next to `about`, `led` and `tv`. The Power section, which held only `sleep`, is gone.
- **Stricter checks on replies.**
  - A reply must be the action's own response element, and in `soc.sh` also HTTP 200. An HTML page or a UPnP fault that only mentions it no longer counts as success.
  - `soc.sh` asks the speaker to close each connection, so a server that would keep it open can't stall a command.
  - A chunked page that is cut short reports `Invalid response from Sonos.` instead of passing.
- **`speech` in `soc-curl.sh` sends its two requests at the same time**, as `soc.sh` does, rather than one after the other in a single `curl` run: about 7 ms faster.
- `speech` prints `0` as soon as Speech Enhancement turns out to be off, without waiting for the level. `soc.sh` uses `read -N` from Bash 4.1, where it was introduced, rather than 4.0.
- Comments condensed, and the obvious ones removed (code improvement).

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
