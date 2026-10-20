<!-- 2.0 - Copyright (C) 2026 Stouthart. All rights reserved. -->

# Control Sonos over UPnP

A small Bash script that controls a **Sonos** speaker from the command line, over your local network. It talks to the speaker's local UPnP interface on port `1400`: no app, no cloud, no account, and nothing to install beyond Bash. Handy for shell aliases, Apple Shortcuts, Stream Deck buttons, or Home Assistant `shell_command`.

Two interchangeable versions are included:

| Script        | Uses              | Best for                                                                                              |
| ------------- | ----------------- | ----------------------------------------------------------------------------------------------------- |
| `soc.sh`      | Bash's `/dev/tcp` | Speed: no program is started per request, about 2 ms faster than `curl` on a Mac and 20 ms on Android |
| `soc-curl.sh` | `curl`            | A 2-second timeout when the speaker is unreachable, and `.local` names                                |

Both take the same options and print the same output.

This is **version 2.0**. The [release notes](RELEASE.md) list what each version changed.

## Requirements

- **Bash** 3.2 or newer (the version macOS ships is fine). `soc.sh` needs Bash's `/dev/tcp`, which the macOS Bash has.
- **curl** 7.76 or newer, for `soc-curl.sh` only (macOS ships it)
- A Sonos speaker reachable on your network

Developed and tested on macOS with a **Sonos Beam Ultra** (Sonos software 27.1). Other Sonos speakers should work; `night`, `speech`, `height`, `lipsync` and `tv` need a soundbar that has those settings. Linux and Windows (Git Bash, WSL) should work but are untested.

## Installation

```bash
git clone https://github.com/Stouthart/Sonos.git
cd Sonos
chmod +x soc.sh soc-curl.sh
```

Optionally put it on your `PATH` under a shorter name:

```bash
sudo install -m 755 soc.sh /usr/local/bin/soc
```

## Configuration

Both scripts require `SONOS_IP`. There is no default:

```bash
export SONOS_IP=192.168.1.42
```

Add that line to your `~/.zshrc` or `~/.bashrc` to make it permanent. The Sonos app shows the address under the speaker's **About** settings as **IP address**. Reserve it in your router, so the speaker keeps it.

`soc.sh` needs the IPv4 address. Bash's `/dev/tcp` also looks up IPv6 for a name, which costs about a second for a `.local` name, and the speaker rejects requests addressed to any other name. `soc-curl.sh` also accepts the speaker's `.local` name (`Sonos-<MAC address>.local`), at about 3 ms extra per request.

## Usage

```
soc.sh <option> [argument]
```

Options print the current value when called without an argument. Only `vol` and `seek` accept a **relative** value prefixed with `+` or `-`; for `bass`, `treble` and `height` a minus sign is part of the value. Write numbers without leading zeros: `vol 8`, not `vol 08`.

Options that only act (`play`, `vol 40`) print nothing; the exit code tells you whether they worked. An option that takes no argument rejects one, so `stop now` fails rather than stopping. Arguments are checked before anything is sent.

### Playback

| Option           | Description                                  |
| ---------------- | -------------------------------------------- |
| `now`            | Show formatted now playing info              |
| `artwork`        | Show the artwork URL for the current track   |
| `play` / `stop`  | Transport control                            |
| `pause`          | Pause while playing, otherwise play          |
| `next` / `prev`  | Skip track (alias: `previous`)               |
| `seek [0..3599]` | Get the position in seconds, or seek to it   |
| `shuffle [0..1]` | Get or set shuffle                           |
| `repeat [0..2]`  | Get or set repeat: 0 off, 1 one track, 2 all |

`now` prints artist, title and album on the first line, and position, duration, quality and source on the second. Missing fields are dropped rather than filled in; on radio, the stream's own text replaces the title. Quality is `lossy` or `lossless`, sample rate and bit depth, as far as the speaker reports them. It reports no bit rate, and for a file none of these, so `now` shows the format from the file's MIME type instead, such as `mpeg` for MP3. The source is taken from the stream address, such as `spotify` or `tv`, and reads `UNKNOWN` when there is none.

`artwork` prints the URL of the current track's artwork, either the streaming service's own link or an image the speaker serves itself, so `open -u "$(soc.sh artwork)"` shows it on macOS. With no artwork it prints nothing and succeeds.

A bare `seek` prints the position in whole seconds. To move, pass seconds or a `min:sec` position (`seek 219` and `seek 3:39` are the same jump), either with an optional `+` or `-`. Both forms top out at `3599` and `59:59`, and the seconds in `min:sec` are always two digits. A relative seek is a single request: the speaker stops at the start of the track, and past the end it moves on to the next one. A source that can't seek makes the speaker refuse it (exit `203`).

`shuffle` and `repeat` set one combined play mode, so each first reads the current mode; a value that is already set sends nothing.

### Sources

| Option             | Description                                                          |
| ------------------ | -------------------------------------------------------------------- |
| `favorites [1..n]` | List favorites, or play favorite _n_ (aliases: `favourites`, `favs`) |
| `file <path>`      | Play a file from an SMB share                                        |
| `tv`               | Switch to the TV input                                               |

`favorites` lists the app's **Sonos Favorites**, numbered from 1 in the app's order. `favorites 2` plays the second: a station or track replaces what is playing, and a playlist or album is added to the end of the queue and played from its first track. Some favorites are only shortcuts into the app, such as the Sonos Radio ones Sonos adds itself; they have nothing to play over UPnP and exit `205`. Playing a station or playlist favorite is untested so far, as the test speaker has only shortcuts.

`file` plays one file from an SMB share, given as `//host/share/path` including the file's extension, e.g. `soc.sh file //192.168.1.10/podcasts/episode.mp3`. It replaces what is playing, and `now` shows the source as `file`. The speaker needs read access to the share; a share in its music library works with the login stored there. Characters other than letters, digits and `/._~+-` are percent-encoded, so names with spaces work as they are.

`tv` first looks up the speaker's own player ID, which the TV input's address contains, as does the queue's.

### Queue

| Option         | Description                                                 |
| -------------- | ----------------------------------------------------------- |
| `queue [1..n]` | List the queue, or play from track _n_ (alias: `playqueue`) |
| `clear`        | Empty the queue                                             |

The queue is numbered from 1, and the current track is marked with a leading `>`. Entries are laid out like the first line of `now`. Nothing is marked while another source plays, such as Spotify Connect. `queue 5` plays from track 5, and switches to the queue first when another source is playing. `clear` is the app's **Clear queue**.

`queue` and `favorites` read on while the speaker caps a reply, until they have every entry. Before Bash 4.1 they read 100 entries at a time, as older Bash splits long text slowly.

### Audio

| Option             | Description                                      |
| ------------------ | ------------------------------------------------ |
| `vol [0..100]`     | Get or set volume (alias: `volume`)              |
| `mute [0..1]`      | Get or set mute                                  |
| `bass [-10..10]`   | Get or set bass                                  |
| `treble [-10..10]` | Get or set treble                                |
| `loudness [0..1]`  | Get or set loudness                              |
| `night [0..1]`     | Get or set Night Sound                           |
| `speech [0..4]`    | Get or set Speech Enhancement: 0 off, 1..4 level |
| `height [-10..10]` | Get or set the height channel level              |
| `lipsync [0..5]`   | Get or set TV dialog sync: 0 off, 1..5 delay     |

A relative `vol` is applied by the speaker, which keeps the result within 0..100.

`night` is the app's **Night Sound**. `height` is the app's **Height level**, the height channel level for immersive audio formats.

`speech` is the app's **Speech Enhancement**, where 1..4 are its four levels, from low to max. The speaker keeps the on/off switch and the level as separate settings: a bare `speech` reads both in one go and prints the level, or `0` when it is off. `speech 0` turns the switch off and leaves the level alone.

`lipsync` is the app's **TV dialog sync**, also listed as **Audio delay (lip sync)**: it delays the sound from the TV, from `0` (none) to `5` (most), to match a picture that lags behind it. The speaker refuses other values.

### Other

| Option           | Description                                               |
| ---------------- | --------------------------------------------------------- |
| `about [key]`    | Show model, room, software, hardware, serial and MAC      |
| `led [0..1]`     | Get or set the status light                               |
| `sleep [0..120]` | Show the sleep timer, set it in minutes, or cancel it (0) |

`about` prints the speaker's details as `key=value`, under the speaker's own field names: `modelName`, `modelNumber`, `roomName`, `displayVersion` (the Sonos software version the app shows), `softwareVersion` (its build), `hardwareVersion`, `serialNum`, `MACAddress` and `apiVersion`. `about <key>` prints one value, and takes any field of the speaker's device description, such as `about memory`; a field the speaker doesn't have prints nothing.

`sleep` is the app's **Sleep timer**. A bare `sleep` prints the time left as `HH:MM:SS`, or nothing when no timer is set. It takes whole minutes, and no relative value.

`help`, or no arguments at all, prints the built-in usage screen; `-h` and `--help` do the same.

## Examples

```bash
soc.sh vol                   # -> 30
soc.sh vol 25                # set volume to 25
soc.sh vol +5                # five louder
soc.sh mute 1                # mute

soc.sh now
# Massive Attack / Teardrop [Mezzanine]
# 1:44 / 5:29 - lossless 44.1kHz 16bit [spotify]

soc.sh artwork               # https://i.scdn.co/image/ab67616d...
soc.sh pause                 # pause, or resume when paused
soc.sh next                  # next track
soc.sh file //192.168.1.10/podcasts/episode.mp3   # play a file from a share

soc.sh favorites             # 1) Discover Sonos Radio
                             # 2) BBC Radio 6 Music
soc.sh favorites 2           # play BBC Radio 6 Music

soc.sh queue                 # 1) Nick Cave / Red Right Hand [Let Love In]
                             # 2) > Nick Cave / Loverman [Let Love In]
soc.sh queue 1               # back to Red Right Hand
soc.sh clear                 # empty the queue

soc.sh seek                  # -> 104
soc.sh seek 3:39             # jump to 3:39
soc.sh seek +30              # skip forward half a minute
soc.sh seek -1:30            # and back a minute and a half

soc.sh tv                    # switch to the TV
soc.sh speech                # -> 1
soc.sh speech 3              # Speech Enhancement, third level
soc.sh night 1               # Night Sound on
soc.sh height -2             # a little less height
soc.sh lipsync 2             # delay the TV's sound a little

soc.sh sleep 45              # sleep timer: 45 minutes
soc.sh sleep                 # -> 00:44:59
soc.sh sleep 0               # cancel it

soc.sh about                 # modelName=Sonos Beam Ultra, roomName=..., ...
soc.sh about displayVersion  # -> 27.1
```

Useful shell aliases:

```bash
alias vol='soc.sh vol'
alias np='soc.sh now'
```

## Exit codes

| Code                                                   | Meaning                                                                |
| ------------------------------------------------------ | ---------------------------------------------------------------------- |
| `0`                                                    | Success                                                                |
| `7`, plus `6`, `18`, `28`, `52`, `56` in `soc-curl.sh` | Network failure: speaker offline, timed out or wrong address           |
| `22` (`soc-curl.sh`)                                   | Server error: an HTTP error from the speaker without a UPnP fault      |
| `200`                                                  | Missing or invalid option                                              |
| `201`                                                  | Missing or invalid argument                                            |
| `202`                                                  | Invalid response: the reply is not the speaker's answer to the request |
| `203`                                                  | The speaker refused the action (UPnP fault)                            |
| `204`                                                  | `SONOS_IP` is not set                                                  |
| `205`                                                  | The favorite is a shortcut, with nothing to play over UPnP             |

A refused action names the action and the UPnP error code, as in `Sonos refused SetEQ, UPnP error 402.` Error 701 means the current source can't do it, and reads `<Action> not available for the current source.` instead. `soc-curl.sh` exits with any other curl error code, as `Unexpected curl error N.`

`soc.sh` has no timeout. A reachable address that refuses the connection fails at once, but an address where nothing answers blocks until the operating system gives up, about 75 seconds on macOS. Use `soc-curl.sh` if that matters.

## Debugging

Pass `--xdbg` as the very first argument to trace execution with per-line timings. The trace runs on any Bash the scripts support; the millisecond column needs Bash 5.0 or newer and reads `0` below it:

```bash
./soc.sh --xdbg vol +5
```

## Notes

- The UPnP actions are Sonos's own and unofficial. They may change with a software update.
- Requests are plain HTTP on the local network, without authentication. Anything on the same network can control the speaker.
- Text from the speaker is stripped of control characters before it is printed, so it pastes cleanly into a terminal or a pipe.

### Device quirks

- **Spotify Connect** runs through the speaker's Virtual Line-In. Skipping and seeking work, but the speaker accepts shuffle and repeat changes and then ignores them: set those in Spotify. Seeking while paused resumes playback.
- **No bit rate:** the speaker reports sample rate, bit depth and whether a stream is lossless, but no bit rate.
- **Speech Enhancement level 0** is accepted but ignored by the speaker, which is why `speech 0` uses the separate switch.
- **No remote restart:** the speaker's old `/reboot` page answers `403 Forbidden`, and the restart the app uses needs a Sonos account login.

## Credits

Setting names are quoted from the Sonos app's own US English strings, so the wording here matches what you see in the app.

## License

Copyright (C) 2026 Stouthart. All rights reserved.

_The scripts in this repository are free for personal use. However, they are NOT published under a software license. This implies - as stated in the [GitHub Docs] - that standard copyright law applies, meaning the owner retains all rights to the source code and no one may reproduce, distribute, or create derivative works from this work._

[GitHub Docs]: https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/licensing-a-repository
