#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# IPv4 address: /dev/tcp also resolves IPv6 (~1 s for .local), and the speaker rejects other Host names
HOST=${SONOS_IP-}
# read -N is 2.5x faster than -d ''; Bash 3.2 lacks it
RD=(-d '')
((BASH_VERSINFO[0] < 4)) || RD=(-N 1048576)

# Service paths; Master channel argument
AVT=MediaRenderer/AVTransport
CH='<Channel>Master</Channel>'
DP=DeviceProperties
RC=MediaRenderer/RenderingControl

[[ ${1-} == --xdbg ]] && {
  shift
  PS4='+\e[5G\e[36m$(((${EPOCHREALTIME/./}-_ERT+500)/1000))\e[9G\e[33m$LINENO\e[13G\e[90m>\e[15G\e[m'
  : "${EPOCHREALTIME=0}" # Bash <5: avoid set -u failure; timing stays 0
  readonly _ERT=${EPOCHREALTIME/./}
  set -x
}

# Report and exit - <code> [action] [UPnP error]
error() {
  local msg

  case $1 in
  7) msg='Network failure, Sonos offline?' ;;
  200) msg='Missing or invalid option.' ;;
  201) msg='Missing or invalid argument.' ;;
  202) msg='Invalid response from Sonos.' ;;
  203) [[ $3 == 701 ]] && msg="$2 not available for the current source." || msg="Sonos refused $2, UPnP error $3." ;;
  204) msg="Set SONOS_IP to the speaker's IPv4 address." ;;
  esac

  printf '%s\n' "$msg" >&2
  exit "$1"
}

# Print the track's artwork URL; relative ones are served by the player
artwork() {
  local url

  soap "$AVT" GetPositionInfo
  didl url upnp:albumArtURI
  [[ -z $url ]] || printf '%s\n' "${url/#\//http://$HOST:1400/}"
}

# Unescaped DIDL-Lite element of REPLY's track metadata, controls stripped - <var> <element>
didl() {
  local i v=''

  [[ $REPLY =~ "&lt;$2&gt;"(([^&]|&[^l])*)"&lt;/$2&gt;" ]] && v=${BASH_REMATCH[1]}
  # SOAP escapes the DIDL-Lite markup, which escapes its own text
  for i in 1 2; do
    v=${v//&lt;/<} v=${v//&gt;/>} v=${v//&quot;/\"} v=${v//&apos;/\'} v=${v//&amp;/\&}
  done
  printf -v "$1" %s "${v//[[:cntrl:]]/}"
}

# Number within max; sets BASH_REMATCH - <arg> <max>
isnum() {
  [[ $1 =~ ^([+-]?)(0|[1-9][0-9]{0,3})$ && ${BASH_REMATCH[2]} -le $2 ]]
}

# Get or set status light - [0..1]
led() {
  local states=(Off On)

  if [[ -z $1 ]]; then
    soap "$DP" GetLEDState
    tag CurrentLEDState 'On|Off'
    [[ ${BASH_REMATCH[1]} == On ]] && printf '1\n' || printf '0\n'
  elif [[ $1 =~ ^[01]$ ]]; then
    soap "$DP" SetLEDState "<DesiredLEDState>${states[$1]}</DesiredLEDState>"
  else
    error 201
  fi
}

now() {
  local alb art bits=0 dur loss='' lq=(lossy lossless) pos q='' rate=0 src tit

  soap "$AVT" GetPositionInfo
  secs pos RelTime
  secs dur TrackDuration
  didl alb upnp:album
  didl art dc:creator
  didl tit dc:title
  # Radio: stream content replaces the title
  didl q r:streamContent
  [[ -z $q ]] || tit=$q
  didl q r:streamInfo
  [[ $q =~ (^|,)bd:([0-9]{1,2})(,|$) ]] && bits=$((10#${BASH_REMATCH[2]}))
  [[ $q =~ (^|,)sr:([0-9]{4,6})(,|$) ]] && rate=$((10#${BASH_REMATCH[2]}))
  # Lossless flag
  [[ $q =~ (^|,)l:([01])(,|$) ]] && loss=${BASH_REMATCH[2]}

  # Source from the URI scheme; Virtual Line-In names its service after the comma
  tag TrackURI
  src=${BASH_REMATCH[1]%%:*}
  case $src in
  x-sonos-htastream) src=tv ;;
  x-sonos-vli) src=${BASH_REMATCH[1]#*,} src=${src%%:*} ;;
  *) src=${src#x-} src=${src#sonos-} src=${src#sonosapi-} src=${src#rincon-} ;;
  esac
  src=${src//[^[:alnum:]._-]/}

  tit=$art${art:+${tit:+ / }}$tit${alb:+ [$alb]}
  # kHz as %g prints it, without the locale switch %g needs
  if ((rate)); then
    q=$((rate % 1000 + 1000)) q=${q#1} q=${q%0} q=${q%0} q=${q%0}
    rate=" $((rate / 1000))${q:+.$q}kHz"
  else
    rate=''
  fi
  ((bits)) && bits=" ${bits}bit" || bits=''
  q=${loss:+ ${lq[loss]}}$rate$bits
  printf '%s\n%d:%02d / %d:%02d%s [%s]\n' "${tit:-UNKNOWN}" $((pos / 60)) $((pos % 60)) $((dur / 60)) $((dur % 60)) \
    "${q:+ -$q}" "${src:-UNKNOWN}"
}

# Get or set repeat (0 off, 1 one, 2 all) or shuffle - <0 repeat | 1 shuffle> [arg]
playmode() {
  local i modes=(NORMAL REPEAT_ONE REPEAT_ALL SHUFFLE_NOREPEAT SHUFFLE_REPEAT_ONE SHUFFLE) r s

  [[ -z $2 || $2 =~ ^[0-2]$ && $2 -le $((2 - $1)) ]] || error 201
  soap "$AVT" GetTransportSettings
  tag PlayMode '[A-Z_]{1,20}'
  case ${BASH_REMATCH[1]} in
  NORMAL) i=0 ;;
  REPEAT_ONE) i=1 ;;
  REPEAT_ALL) i=2 ;;
  SHUFFLE_NOREPEAT) i=3 ;;
  SHUFFLE_REPEAT_ONE) i=4 ;;
  SHUFFLE) i=5 ;;
  *) error 202 ;;
  esac
  r=$((i % 3)) s=$((i / 3))

  if [[ -z $2 ]]; then
    (($1)) && printf '%s\n' "$s" || printf '%s\n' "$r"
  else
    (($1)) && s=$2 || r=$2
    ((s * 3 + r == i)) || soap "$AVT" SetPlayMode "<NewPlayMode>${modes[s * 3 + r]}</NewPlayMode>"
  fi
}

# Pause while playing, otherwise play
playpause() {
  soap "$AVT" GetTransportInfo
  tag CurrentTransportState '[A-Z_]{1,32}'
  case ${BASH_REMATCH[1]} in
  PLAYING | TRANSITIONING) soap "$AVT" Pause ;;
  *) soap "$AVT" Play '<Speed>1</Speed>' ;;
  esac
}

# Read the reply on fd 3 or 4; sets REPLY, exits on fault or foreign reply - <fd> <action>
recv() {
  IFS= read -r "${RD[@]}" REPLY <&"$1" || :
  case $1 in
  3) exec 3<&- ;;
  *) exec 4<&- ;;
  esac

  [[ $REPLY == *"$2"Response* ]] && return
  [[ $REPLY =~ '<errorCode>'([0-9]{1,4})'</errorCode>' ]] && error 203 "$2" "${BASH_REMATCH[1]}"
  error 202
}

# H:MM:SS element of REPLY as seconds, 0 if absent - <var> <element>
secs() {
  if [[ $REPLY =~ "<$2>"([0-9]{1,3}):([0-5][0-9]):([0-5][0-9])"</$2>" ]]; then
    printf -v "$1" %d $((10#${BASH_REMATCH[1]} * 3600 + 10#${BASH_REMATCH[2]} * 60 + 10#${BASH_REMATCH[3]}))
  else
    printf -v "$1" 0
  fi
}

# Get or seek position (±) - [sec | min:sec]
seek() {
  local pos sign unit=REL_TIME val

  if [[ -z $1 ]]; then
    soap "$AVT" GetPositionInfo
    secs pos RelTime
    printf '%s\n' "$pos"
    return
  elif isnum "$1" 3599; then
    val=${BASH_REMATCH[2]} sign=${BASH_REMATCH[1]}
  elif [[ $1 =~ ^([+-]?)([0-5]?[0-9]):([0-5][0-9])$ ]]; then
    val=$((10#${BASH_REMATCH[2]} * 60 + 10#${BASH_REMATCH[3]})) sign=${BASH_REMATCH[1]}
  else
    error 201
  fi

  # Relative in one request: the speaker stops at the start and skips to the next track past the end
  [[ -z $sign ]] || unit=TIME_DELTA
  printf -v val '%s%d:%02d:%02d' "$sign" $((val / 3600)) $((val / 60 % 60)) $((val % 60))
  soap "$AVT" Seek "<Unit>$unit</Unit><Target>$val</Target>"
}

# Connect fd 3 or 4 and send a UPnP action - <fd> <service path> <action> [arguments]
# The speaker ends each reply by closing; an unreachable one blocks the connect until the OS gives up (~75 s)
send() {
  local body urn=urn:schemas-upnp-org:service:${2##*/}:1

  # Here rather than up front, so option and argument errors come first
  [[ -n $HOST ]] || error 204
  body="<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\">\
<s:Body><u:$3 xmlns:u=\"$urn\"><InstanceID>0</InstanceID>${4-}</u:$3></s:Body></s:Envelope>"
  # case: a literal fd is 3 µs cheaper than eval
  case $1 in
  3) { exec 3<>"/dev/tcp/$HOST/1400"; } 2>/dev/null ;;
  *) { exec 4<>"/dev/tcp/$HOST/1400"; } 2>/dev/null ;;
  esac || error 7
  # Bodies are ASCII, so characters equal bytes
  printf 'POST /%s/Control HTTP/1.1\r\nHost: %s:1400\r\nContent-Type: text/xml; charset="utf-8"\r\nSOAPACTION: "%s#%s"\r\nContent-Length: %d\r\n\r\n%s' \
    "$2" "$HOST" "$urn" "$3" "${#body}" "$body" >&"$1"
}

# Send UPnP action and read its reply - <service path> <action> [arguments]
soap() {
  send 3 "$@"
  recv 3 "$2"
}

# Get or set speech enhancement (0 off, 1..4 level); both values travel at once over two connections - [arg]
speech() {
  local dl='<EQType>DialogLevel</EQType>' on se='<EQType>SpeechEnhanceEnabled</EQType>'

  if [[ -z $1 ]]; then
    send 3 "$RC" GetEQ "$se"
    send 4 "$RC" GetEQ "$dl"
    recv 3 GetEQ
    tag CurrentValue '[01]'
    on=${BASH_REMATCH[1]}
    recv 4 GetEQ
    tag CurrentValue '[0-4]'
    ((on)) && printf '%s\n' "${BASH_REMATCH[1]}" || printf '0\n'
  elif [[ $1 =~ ^[0-4]$ ]]; then
    # Level 0 is accepted but ignored; off is a separate switch
    send 3 "$RC" SetEQ "$se<DesiredValue>$(($1 > 0))</DesiredValue>"
    (($1 == 0)) || send 4 "$RC" SetEQ "$dl<DesiredValue>$1</DesiredValue>"
    recv 3 SetEQ
    (($1 == 0)) || recv 4 SetEQ
  else
    error 201
  fi
}

# Match REPLY element; sets BASH_REMATCH[1] or exits - <element> [value pattern]
tag() {
  [[ $REPLY =~ "<$1>"(${2-[^<]*})"</$1>" ]] || error 202
}

# Get, set (min) or cancel (0) sleep timer - [arg]
timer() {
  local t=''

  if [[ -z $1 ]]; then
    soap "$AVT" GetRemainingSleepTimerDuration
    tag RemainingSleepTimerDuration '([0-9]{1,2}:[0-5][0-9]:[0-5][0-9])?'
    [[ -z ${BASH_REMATCH[1]} ]] || printf '%s\n' "${BASH_REMATCH[1]}"
  elif isnum "$1" 120 && [[ -z ${BASH_REMATCH[1]} ]]; then
    ((BASH_REMATCH[2] == 0)) || printf -v t '%02d:%02d:00' $((BASH_REMATCH[2] / 60)) $((BASH_REMATCH[2] % 60))
    soap "$AVT" ConfigureSleepTimer "<NewSleepTimerDuration>$t</NewSleepTimerDuration>"
  else
    error 201
  fi
}

# Switch to the HDMI input; the stream URI needs the player's id, found by its address in the topology
tv() {
  soap ZoneGroupTopology GetZoneGroupState
  [[ $REPLY =~ 'UUID=&quot;'(RINCON_[[:alnum:]]{1,32})'&quot; Location=&quot;http://'"$HOST"':1400/' ]] || error 202
  soap "$AVT" SetAVTransportURI \
    "<CurrentURI>x-sonos-htastream:${BASH_REMATCH[1]}:spdif</CurrentURI><CurrentURIMetaData></CurrentURIMetaData>"
}

usage() {
  local nm=${0##*/}

  printf '%s\n' "$nm 1.0 - Control Sonos over UPnP
Copyright (C) 2026 Stouthart. All rights reserved.

Usage: $nm <option> [argument]

Power:
  sleep 0..120

Playback:
  artwork | next | now | pause | play | prev | stop
  repeat 0..2 | seek 0..3599 | shuffle 0..1

Audio:
  bass -10..10 | height -10..10 | loudness 0..1 | mute 0..1
  night 0..1 | speech 0..4 | treble -10..10 | vol 0..100

Other:
  led 0..1 | tv

Omit the argument to read the current value.
Volume and seek accept a relative value (e.g. vol +5, seek -30).
Seek also accepts a min:sec position or offset (e.g. 3:39, -1:30).
Requires SONOS_IP: the speaker's IPv4 address."
}

# Get or set min..max value - <service> <action> <element> <arguments> <min> <max> [arg]
value() {
  if [[ -z $7 ]]; then
    soap "$1" "Get$2" "$4"
    tag "Current$3" '-?[0-9]{1,3}'
    printf '%s\n' "${BASH_REMATCH[1]}"
  elif [[ $7 =~ ^(0|-?[1-9][0-9]{0,2})$ ]] && (($7 >= $5 && $7 <= $6)); then
    soap "$1" "Set$2" "$4<Desired$3>$7</Desired$3>"
  else
    error 201
  fi
}

# Get, set or adjust (±) volume - [arg]
volume() {
  if isnum "$1" 100 && [[ -n ${BASH_REMATCH[1]} ]]; then
    # Speaker clamps the result to 0..100
    soap "$RC" SetRelativeVolume "$CH<Adjustment>${BASH_REMATCH[0]#+}</Adjustment>"
  else
    value "$RC" Volume Volume "$CH" 0 100 "$1"
  fi
}

(($# < 3)) || error 201
opt=${1-}
arg=${2-}

# No-argument options
case $opt in
'' | -h | --help | help | artwork | next | now | pause | play | prev | previous | stop | tv)
  (($# < 2)) || error 201
  ;;
esac

case $opt in
sleep)
  timer "$arg"
  ;;
artwork)
  artwork
  ;;
next)
  soap "$AVT" Next
  ;;
now)
  now
  ;;
pause)
  playpause
  ;;
play)
  soap "$AVT" Play '<Speed>1</Speed>'
  ;;
prev | previous)
  soap "$AVT" Previous
  ;;
repeat)
  playmode 0 "$arg"
  ;;
seek)
  seek "$arg"
  ;;
shuffle)
  playmode 1 "$arg"
  ;;
stop)
  soap "$AVT" Stop
  ;;
bass)
  value "$RC" Bass Bass '' -10 10 "$arg"
  ;;
height)
  value "$RC" EQ Value '<EQType>HeightChannelLevel</EQType>' -10 10 "$arg"
  ;;
loudness)
  value "$RC" Loudness Loudness "$CH" 0 1 "$arg"
  ;;
mute)
  value "$RC" Mute Mute "$CH" 0 1 "$arg"
  ;;
night)
  value "$RC" EQ Value '<EQType>NightMode</EQType>' 0 1 "$arg"
  ;;
speech)
  speech "$arg"
  ;;
treble)
  value "$RC" Treble Treble '' -10 10 "$arg"
  ;;
vol | volume)
  volume "$arg"
  ;;
led)
  led "$arg"
  ;;
tv)
  tv
  ;;
'' | -h | --help | help)
  usage
  ;;
*)
  error 200
  ;;
esac

exit
