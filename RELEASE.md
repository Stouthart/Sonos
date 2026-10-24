<!-- 3.1 - Copyright (C) 2026 Stouthart. All rights reserved. -->

# Release notes

Highlights per version, newest first, with 1.x and 2.x condensed per major version. 3.1 is the version distributed; the entries below it show how the scripts got there.

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
