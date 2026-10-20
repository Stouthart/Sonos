<!-- 2.0 - Copyright (C) 2026 Stouthart. All rights reserved. -->

# Release notes

Highlights per version, newest first. 2.0 is the version distributed.

## 2.0 - October 2026

Favorites, the queue, lip sync, and sturdier replies. The usage screen has two new sections, Sources and Queue, and `file` and `tv` moved into Sources, hence the new major version.

- **New `favorites`**, listing the app's **Sonos Favorites** by number, and playing one with `favorites <n>` (aliases: `favourites`, `favs`). A station or track plays at once; a playlist or album is added to the end of the queue and played from its first track. A favorite that is only a shortcut into the app, such as Sonos Radio's own, reports that instead (exit `205`).
- **New `queue` and `clear`**, in a new Queue section of the usage screen. `queue` lists the queue like the first line of `now`, with the current track marked `>`, and `queue <n>` plays from track _n_, switching to the queue when another source is playing (alias: `playqueue`). `clear` empties it. In `soc.sh` the list and the position are read at the same time; `soc-curl.sh` reads them one after the other, as two `curl` runs at once made the long reply stall for about 100 ms in one run of four.
- **New `lipsync`**, the app's **TV dialog sync**, also listed as **Audio delay (lip sync)**: it delays the TV's sound in steps from 0 to 5, to match a picture that lags behind it. The speaker refuses anything outside 0..5, which `lipsync` checks before sending. In the Audio section, next to `night`, `speech` and `height`.
- **New Sources section** in the usage screen, after Playback, for the options that pick what plays: `favorites`, `file` and `tv`. `file` moved there from Playback, `tv` from Other.
- **Sturdier replies.**
  - `soc.sh` joins the chunks that Browse replies come in, which every 4 KB could break a title or address in a list or a favorite. It walks the chunks by offset, so joining doesn't copy the rest of a long reply for every chunk.
  - `soc.sh` fails rather than accept a reply cut short at its read limit, now 16 MiB.
  - `soc-curl.sh` only accepts a reply when `curl` succeeded too, so an HTTP error or a cut-off transfer no longer passes.
- **`favorites` and `queue` read on** while the speaker caps a reply, until they have every entry, and stop if a reply brings nothing new.
- **Fast lists on Bash 3.2.** Its pattern replacement slows down sharply with size, so before Bash 4.1 a list is cut up entry by entry, and read in pages of 100. A 29-track queue takes 50 ms rather than a second, and a 1,000-track one 0.6 s rather than minutes.
- **`speech` in `soc-curl.sh` sends its two requests one after the other again.** Run alongside, a failed second request could pass unnoticed, as its `curl` exit status was lost, and two `curl` runs at once stalled for up to 200 ms in some runs. A reading now takes about 38 ms rather than 27 ms when nothing stalls.
- `soc.sh` joins any reply the speaker sends in chunks, not just Browse replies, in case a software update chunks others too.
- `now`'s first line and the queue entries share one formatter, and `tv` and `queue` one player ID lookup (code improvement).

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
