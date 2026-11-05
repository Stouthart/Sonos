<!-- 3.5 - Copyright (C) 2026 Stouthart. All rights reserved. -->

# Release notes

Highlights per version, newest first, with 1.x and 2.x condensed per major version. 3.5 is the version distributed; the entries below it show how the scripts got there.

## 3.5 - November 2026

Radio as the Sonos app shows it: a station by its name and its picture, and Sonos Radio by name; and music services by name. Measured with 80s80s Dance and Qobuz on a Beam Ultra.

- **A paused station by its name:** while paused, a station sends no song, and `now` printed its link's file name as the title, such as `regc-80s80sdance2523717-mp3-192-…?sABC=…`. It now prints the station's name, such as `80s80s Dance`, from one request more.
- **No `ZPSTR_` codes:** for a few seconds after Play, the speaker sends `ZPSTR_CONNECTING`, then `ZPSTR_BUFFERING`, in place of the song, and `now` printed them as the title. It now prints the station's name meanwhile, as while paused.
- **Sonos Radio by name:** its stations and their tracks showed as `[http]`, after their `x-sonos-http` links; `now` now says `[sonos-radio]`.
- **Music services by name:** a track from Qobuz, TIDAL, Deezer, Apple Music, Amazon Music, YouTube Music, SoundCloud, Plex or IDAGIO showed as its link's scheme, such as `[http]`; `now` now names the service, such as `[qobuz]`, by its number in the link, as the speakers list it. Another service keeps its scheme. Spotify played from the Sonos app's queue no longer shows `spotify` as its format: the speaker reports none for it, only for Spotify Connect.
- **A station's picture:** `artwork` printed nothing for a station whose song has no cover, as 80s80s Dance has none. It now prints the speaker's copy of the station's logo, by the station's link, from one request more. On Sonos Radio it always does, as the speaker's copy of a track's cover there can be another station's logo.

## 3.4 - November 2026

`settings` follows the Sonos app: the app's order, and only the settings the speaker has, so it now works on a speaker without Home theater. The usage screen follows the app's sections, and two options take the app's names. Measured with a Beam Ultra with a Sub Mini, and an Era 300.

- **`settings` works on any speaker:** it stopped at the first setting the speaker refused, so on an Era 300, which has no Home theater, it printed only `Sonos refused GetEQ, UPnP error 402.` and exited `203`. It now leaves out what the speaker refuses, and fails only when it refuses every setting.
- **Sub audio only with a bonded Sub:** a speaker answers for the Sub's settings without one, as an Era 300 does, so `settings` printed them for a speaker with no Sub. It now reads the topology too, and prints them only when the speaker's channel map has a Sub. That is one request more in `soc.sh`, about 7 ms, and two in `soc-curl.sh`, in the same `curl` run, about 20 ms.
- **In the app's order:** `trueplay`, `bass`, `treble`, `height`, `loudness` and `limit`, then `sub`, `sublevel` and `phase`, then `speech`, `night` and `lipsync`, and last `light` and `touch`.
- **Renamed after the app:** `level` is now `sublevel`, for the app's **Sub level**, and `led` is now `light`, for its **Status light**. The old names are gone, so a copy of `settings` saved with 3.3 needs those two lines renamed before it puts the settings back.
- **The usage screen follows the app's sections:** `height` moves to Sound, as the app has it under EQ, and Sub audio comes before Home theater. The line on `about <key>` left the usage screen for the README.
- **The 16 MiB cap counts bytes everywhere:** where Bash counts characters, as on Android, `soc.sh` measured a reply in characters, so one full of accented or other non-ASCII text could get past the cap at up to four times its size.

## 3.3 - November 2026

Groups: with the speaker in a group, playback and the queue now reach the group's leader, and `vol` and `mute` every room, with the same options. Measured with a Beam Ultra grouped with an Era 300.

- **Playback and the queue go to the group's leader:** a group member refuses Pause, accepts Play and ignores it, and reports neither the group's track nor its queue, so `pause` said `Pause not available for the current source.` and `now` printed `0:00 / 0:00 [rincon]`. A playback or queue option now asks the speaker first whether it leads, one small request, about 20 ms, and goes to the leader if it doesn't. `now` asks only once the speaker turns out to be a member, so it costs nothing on a speaker alone. Other sound and hardware settings, and `tv`, stay with the speaker itself.
- **`vol` and `mute` set the whole group:** they set only the speaker `SONOS_IP` names, so a group's rooms drifted apart. Now every room gets the same level, unlike the Sonos app, which keeps the rooms' shares. A relative `vol` steps the speaker and the other rooms take its new level, so `vol +0` brings a group back to one level. Read, they print the speaker's own. The group's rooms are asked with the change itself, so a speaker alone takes about as long as before.
- **`now` names line-in and radio:** both showed `stream`; they're now `line-in` and `radio`, the latter also for MP3, HLS and AAC radio streams.
- **`artwork` stays on your network:** a cover on the internet over plain HTTP, such as a radio station's logo, now comes as the speaker's copy too, and a cover the speaker has no copy of prints nothing rather than the outside link. The track's address is percent-encoded in full, tabs and non-ASCII characters included.
- **Sturdier replies:** `soc.sh` finds a chunked reply by its header in any case and anywhere among the headers, takes chunk extensions, and refuses chunks that don't end as they should, at the same speed. It also refuses a reply whose body isn't as long as its `Content-Length` says, and reads the reply's verdict from its body alone, so a header can't pass for it. Both scripts refuse a reply over 16 MiB on any Bash and curl, and send a write only once the one before it took: `speech` sets the level only once the switch took. Group members are found by their attributes in any order.

## 3.2 - November 2026

Faster lists, settings and TV readings with the same options, and fuller `artwork` and `now` output. Measured with a Beam Ultra on a Mac.

- **`artwork` always gives a link on your network:** for a cover on the internet, such as Spotify's, it prints the speaker's own copy rather than the HTTPS link, so opening it doesn't leave the network.
- **`now` names the format more fully:** a track cast from a UPnP app shows its sample rate and bit depth, as in `flac 44.1kHz 16bit`, and the format drops the MIME type's `x-`, as in `flac` for `x-flac`.
- **`queue` and `favorites` are faster on Bash 4.1 and later:** they split the speaker's list in memory rather than reading it back one byte at a time, about 3.5 ms less for a 30-track queue. On any Bash, a title without an `&` also skips unescaping, about 25 µs less per entry.
- **`settings` in `soc-curl.sh` takes about 180 ms rather than 250:** one `curl` run sends its requests one after the other, where each request started its own `curl` before. `speech 1..4`, `file`, `favorites <n>` and `queue <n>` save about 6 ms the same way for each request after the first. A refused or failed request still stops the rest, with the same exit code and message as before.
- **`now` on the TV input is about 10 ms faster in `soc.sh`:** it asks for the TV's sound format alongside what is playing, and ignores that answer for other sources, at no measurable cost.
- **Every reply is checked a little faster:** a microsecond or two on Bash 5, about 6 on Bash 3.2.

## 3.1 - October 2026

`about` lists what the app shows, `settings` the speaker's settings, `now` the TV's sound format, and fixes for Android, where `soc.sh queue` failed with `Invalid response from Sonos.` when a title in the queue had an accent or another non-ASCII character. Bash on Android counts characters rather than bytes in every locale, `LC_ALL=C` included, so the scripts now count bytes themselves wherever the speaker's protocol needs it. Tested in Termux.

- **`now` on the TV input shows the format the TV sends** where music shows its quality, such as `Dolby Atmos (MAT)`, `Dolby Digital 5.1` or `No input`. For Dolby Atmos, the brackets say how it arrives: `DD+`, `TrueHD` or `MAT`.
- **`about` follows the app's About your system**, in its order: `displayName` (the model, as the app names it), `roomName`, `serialNum`, `swGen` (S1 or S2), `softwareVersion` (the app's Build) and `hardwareVersion`, then `displayVersion` and `apiVersion` as before. The others it printed, such as `modelName` and `MACAddress`, are one `about <key>` away.
- **New `settings`**, in the Hardware section, prints the settings of Sound (`vol` and `mute` aside), Home theater, Sub audio and Hardware as `option=value`. Each line works as a command again, so a saved copy puts the settings back. `soc.sh` asks for them seven at a time, in about half the time of one by one.
- **`favorites`, `queue` and `about` in `soc.sh`** read a reply the speaker sends in chunks correctly on Android, whatever its text. A title such as `Hernán Cattáneo` before the last chunk made `soc.sh` lose its place in the reply, and exit `202`.
- **`favorites <n>` in `soc.sh`** sends the request's length in bytes on Android, for a favorite whose name has non-ASCII characters. It sent the number of characters before.
- **`file`** percent-encodes non-ASCII characters as UTF-8 on Android, as it does elsewhere, in both scripts: `Café` becomes `Caf%C3%A9`, where Android sent it unencoded, and `€` becomes `%E2%82%AC` rather than `%AC`.
- **On the Mac the fixes change nothing:** the output is the same, and where Bash counts bytes `soc.sh` skips the extra work, for about a microsecond per request.

## 3.0 - October 2026

A library rescan, the volume limit, Trueplay, the Sub and the touch controls, and a faster start. The usage screen now follows the app: Playback keeps the app's own controls together, the queue joined Sources, Audio became Sound and Home theater, Sub audio is new, and Other became Hardware. That, and a `soc.sh` start that needs `env -S`, make this a new major version. The Sub options need a Sub bonded to the speaker; tested with a Sub Mini.

- **New `rescan`**, the app's **Scan for new content**, in the Sources section: the speaker rescans the shares in its music library. It returns at once while the scan runs.
- **New `limit`**, the app's **Volume limit**, in percent, in the Sound section. The speaker scales the volume to it rather than capping it, so `vol` still runs from 0 to 100.
- **New `trueplay`**, the app's **Trueplay tuning** switch, in the Sound section: `trueplay 0` turns the room's tuning off, `trueplay 1` back on. Tuning the room still needs the app.
- **New `level`**, the app's **Sub level**, from -15 to 15. The speaker stores any level it is sent, even far outside the app's range, so `level` checks for -15..15 before sending.
- **New `phase`**, the app's **Phase control** for the Sub: `phase 1` sets it to 180°, `phase 0` back to 0°. The app shows it only while Trueplay tuning is off (`trueplay 0`).
- **New `sub`**, the app's **Sonos Sub** switch: `sub 0` turns the Sub off and leaves its level alone, `sub 1` turns it back on.
- **New `touch`**, the app's **Touch controls**, in the Hardware section: `touch 0` turns them off, `touch 1` back on.
- **Playback has a third line** on the usage screen, for `artwork`, `now` and `sleep`, so the first two hold the app's own playback controls. `sleep` moved there from Other, as the app keeps the sleep timer with what is playing.
- **The queue joins Sources** on the usage screen, as its second line: `clear` and `queue`.
- **Sound and Home theater** replace the usage screen's Audio section, named as in the app: Home theater holds `height`, `lipsync`, `night` and `speech`, and Sound the rest.
- **Hardware** replaces Other on the usage screen, as in the app, for `about`, `led` and `touch`.
- **Faster start.** `soc.sh` starts Bash in the C locale (`#!/usr/bin/env -S LC_ALL=C bash`), which spares it loading a UTF-8 locale: about 0.2 ms less per command. On a system whose `env` lacks `-S`, such as BusyBox or older Linux, run it as `bash soc.sh`, or use `soc-curl.sh`, whose plain `#!/usr/bin/env bash` runs anywhere.
- **The speaker's text is handled the same in every locale.** C1 control characters (U+0080 to U+009F) are now stripped everywhere; before, `favorites` and `queue` let them through, and the other options stripped them only in a UTF-8 locale. Zero-width joiners, as in emoji sequences and in Persian or Indic text, are no longer dropped.
- **`queue <n>` switches to the queue sooner** in `soc.sh`: it looks up the player's ID alongside the current source, which saves a round trip (about 8 ms) when another source is playing.
- **`soc-curl.sh` sends one request per command**, even when `SONOS_IP` contains `{}` or `[]`, which `curl` would otherwise expand into several addresses.

## 2.x - October 2026

Favorites, the queue, lip sync, and sturdier replies. The usage screen gained two sections, Sources and Queue, hence the new major version.

- **New `favorites`**, listing the app's **Sonos Favorites** and playing one by number; **new `queue` and `clear`**, listing the queue with the current track marked `>`, playing from a track and emptying it; and **new `lipsync`**, the app's **TV dialog sync**.
- **Sturdier replies:** `soc.sh` joins replies the speaker sends in chunks and rejects one cut short, and `soc-curl.sh` accepts a reply only when `curl` succeeded too.
- **Complete lists, fast on Bash 3.2:** `favorites` and `queue` read on until they have every entry, and a 1,000-track queue takes 0.6 s on Bash 3.2 rather than minutes.

## 1.x - October 2026

The first release, then product details and files from a network share.

- **1.0** - Playback, sound and home theater settings from the command line, over the speaker's local UPnP interface. Two versions with the same options and output: `soc.sh` on Bash's own `/dev/tcp`, and `soc-curl.sh` on `curl`, for a 2-second timeout and `.local` names. Nothing to install beyond Bash, the 3.2 macOS ships included, and setting names in the Sonos app's US English wording.
- **1.1** - **New `about`**, the speaker's details from its device description, and **new `file`**, playing a file from an SMB share. A reply must be the action's own response, and in `soc.sh` also HTTP 200, so a UPnP fault or an HTML page no longer counts as success.
