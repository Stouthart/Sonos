<!-- 5.1 - Copyright (C) 2026 Stouthart. All rights reserved. -->

# Release notes

Highlights per version, newest first, with 1.x, 2.x and 3.x condensed per major version. 5.1 is the version distributed; the entries below it show how the scripts got there.

## 5.1 - November 2026

Clearer answers where a speaker can't do what's asked, and `pause` on a stream that only stops.

- **`pause` on a stream that stops rather than pauses:** where the speaker refuses Pause and names Stop among the actions it takes, `pause` stops the stream, as the Sonos app's button does, and the next `pause` plays it again; it exited `203` there. Two requests more, only after the refusal. A source that takes neither, as the TV, reads `Pause not available for the current source.` as before. Tested with a radio station on a Beam Ultra.
- **The sleep timer in a group:** the usage text and the README now say what `sleep` already did: the timer goes to the group's leader, so it stops every room.
- **A setting the speaker hasn't got:** a sound setting on a speaker without it, as `night` on an Era 300, reads `night not available on this speaker.`, where it read `Sonos refused GetEQ, UPnP error 402.` The exit code stays `203`.
- **Replies read more strictly:** a reply counts as the speaker's answer only with HTTP 200 and the action's response opening the body of a SOAP envelope, as a Sonos writes it, and as its refusal only with HTTP 500 and a SOAP fault there. A page that merely names the response, a redirect that carries one, an envelope that never closes, or in `soc-curl.sh` a refusal whose transfer was cut short no longer passes, so no write follows one; they exit `202`, or with curl's own code. It costs nothing measurable on a command, and under 0.2 ms on a 1,000-track queue.
- **Hardening:** `soc-curl.sh` ignores a `SOFT` or `SLOW` variable in the environment, which reached its requests, and in `soc.sh` only a single digit can reach the `eval` that opens `settings`' extra connections.

## 5.0 - November 2026

Spotify links played through the queue, and in `now` the quality of a track from a queue or the music library.

- **Spotify links:** `spotify <link>` plays a Spotify track, album or playlist from its `open.spotify.com` link or its `spotify:` address: added to the end of the queue and played from its first track, as `favorites` plays a playlist, also with shuffle on. An album or playlist goes in with one request, and the speaker reads its tracks from Spotify. The speakers play it with the household's own Spotify account, added in the Sonos app, so there's no Spotify sign-in here.
- **A track's quality from a queue or the library:** `now` shows the quality of a track whose UPnP details carry no rate, a Spotify track or another service's (Qobuz) from the queue, or a file from a share, such as `lossless 44.1 kHz 16-bit [spotify]` or `mpeg 44.1 kHz [file]`, where it showed none or the format alone. It comes from the speaker's newer interface, which port `1400` also serves over plain HTTP, and only when the speaker names that same track as the one playing: two requests more, about 40 ms, only for such a track. A track played on its own, as a Spotify favorite starts it, has none there either, and neither has a station. The bit depth shows for lossless music only, everywhere, as a lossy stream's is only what its decoder puts out.
- **Shuffle back on after a failure:** `favorites n` on a playlist, and `spotify`, switch shuffle off while the tracks go in, and now switch it on again also when adding or starting them fails, where it stayed off; the error stands.
- **Time to add an album or playlist:** `soc-curl.sh` waits up to 10 seconds for the speaker to add one, a favorite's too, where it gave up after 2 and exited `28` while the speaker read a long one from its service.

## 4.2 - November 2026

Hours in `now` and `seek`, a group's speakers held to the local network, and stricter reply checks.

- **Hours:** `now` shows a time from an hour on as `h:mm:ss`, such as `6:25 / 1:00:00`, where it counted minutes on, as `60:00`. `seek` also takes `h:mm:ss`, as a position or an offset, such as `seek 1:15:00` or `seek -1:00:00`, so a long mix can be sought past its first hour. Seconds and `min:sec` work as before, and a bare `seek` still prints whole seconds.
- **A group's speakers on the local network:** a group's leader, and the rooms `vol` and `mute` set together, must be at a private, link-local or loopback IPv4 address, as a cover must. An address elsewhere is never asked: the script exits `202`.
- **Stricter reply checks:** `soc.sh` refuses a reply without the blank line after its headers, where a response's name in a header could pass for the speaker's answer, and one whose `Content-Length` isn't a number alone, such as `400x`, or is longer than the 16 MiB cap allows. `soc-curl.sh` counts that cap in bytes also where Bash counts characters, as in UTF-8 or on Android, where a reply of multibyte text could pass it.

## 4.1 - November 2026

Sample rates written out, and every write waiting for the answer to the one before it, also in `soc-curl.sh`.

- **Sample rate and bit depth written out:** `now` prints them as `44.1 kHz 16-bit`, where it printed `44.1kHz 16bit`.
- **A write waits for the one before it, also in `soc-curl.sh`:** it sent an action's follow-ups in the same `curl` run, so a reply with HTTP 200 that wasn't the speaker's answer, such as a web page, still let them through, as the playlist after shuffle off, or Play after a seek. Each now goes out once the one before it was answered, as in `soc.sh`. Group volume, where each room's level stands alone, keeps its one run.
- **A play mode it doesn't know:** `favorites n` on a playlist exits `202` for a play mode it doesn't know, as `repeat` does, rather than adding the playlist as if shuffle were off.

## 4.0 - November 2026

A station by its name in every case, and its picture with one request less; a playlist favorite from its first track, also with shuffle on.

- **A station's name, always:** `now` printed `UNKNOWN` for a station that sends no track info, as some do while starting, and Sonos Radio never fell back on its station's name. Both now print the station's name, such as `80s80s Dance`, from one request more then.
- **A playlist favorite from its first track, also with shuffle on:** `favorites n` on a playlist or album started another track while shuffle was on, even one queued before, as the speaker counts the position it reports in its shuffled order. Shuffle is now off while the playlist is added and its first track starts, then on again, which shuffles the rest.
- **One request less for a station's picture:** `artwork` reuses the speaker's answer from finding a group's leader, when there's none to follow; in a group led by another speaker it asks that one, as before.

## 3.x - October and November 2026

The Sonos app's own sections and settings, groups, radio and music services by name, and fixes for Android.

- **3.0** - New `rescan`, `limit` and `trueplay`, for a bonded Sub `level`, `phase` and `sub`, and `touch`. The usage screen follows the app's sections: Playback, Sources with the queue, Sound, Home theater, Sub audio and Hardware. That, and a `soc.sh` start in the C locale that needs `env -S`, made it a new major version. The speaker's text is handled the same in every locale.
- **3.1** - New `settings`, printing the speaker's settings as `option=value` lines that put them back as they are; `about` in the order of the app's About your system; `now` on the TV input shows the format the TV sends, such as `Dolby Atmos (MAT)`. Fixes for Android, where Bash counts characters rather than bytes, for `queue`, `favorites`, `about` and `file` with non-ASCII text.
- **3.2** - `artwork` always gives a link on the local network, the speaker's copy of a cover on the internet; `now` shows the sample rate and bit depth of a track cast from a UPnP app; faster `queue` and `favorites`, and in `soc-curl.sh` a faster `settings`, its requests in one `curl` run.
- **3.3** - Groups: playback and the queue go to the group's leader, and `vol` and `mute` set every room to one level. `now` names line-in and radio, `artwork` stays on the network for plain-HTTP covers too, and replies are sturdier: capped at 16 MiB, with a write sent only once the one before it took.
- **3.4** - `settings` in the app's order, with only what the speaker has, so it works on an Era 300 too, and Sub audio only with a bonded Sub. `level` and `led` are renamed `sublevel` and `light`, after the app. The reply cap counts bytes everywhere.
- **3.5** - Radio as the Sonos app shows it: a station's name while paused or connecting, rather than its link or a `ZPSTR_` code, its picture in `artwork`, and Sonos Radio by name. Music services by name, such as `[qobuz]`.

## 2.x - October 2026

Favorites, the queue, lip sync, and sturdier replies. The usage screen gained two sections, Sources and Queue, hence the new major version.

- **New `favorites`**, listing the app's **Sonos Favorites** and playing one by number; **new `queue` and `clear`**, listing the queue with the current track marked `>`, playing from a track and emptying it; and **new `lipsync`**, the app's **TV dialog sync**.
- **Sturdier replies:** `soc.sh` joins replies the speaker sends in chunks and rejects one cut short, and `soc-curl.sh` accepts a reply only when `curl` succeeded too.
- **Complete lists, fast on Bash 3.2:** `favorites` and `queue` read on until they have every entry, and a 1,000-track queue takes 0.6 s on Bash 3.2 rather than minutes.

## 1.x - October 2026

The first release, then product details and files from a network share.

- **1.0** - Playback, sound and home theater settings from the command line, over the speaker's local UPnP interface. Two versions with the same options and output: `soc.sh` on Bash's own `/dev/tcp`, and `soc-curl.sh` on `curl`, for a 2-second timeout and `.local` names. Nothing to install beyond Bash, the 3.2 macOS ships included, and setting names in the Sonos app's US English wording.
- **1.1** - **New `about`**, the speaker's details from its device description, and **new `file`**, playing a file from an SMB share. A reply must be the action's own response, and in `soc.sh` also HTTP 200, so a UPnP fault or an HTML page no longer counts as success.
