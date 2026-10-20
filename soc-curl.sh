#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

BASE=http://${SONOS_IP-}:1400
# Bash before 4.1 splits long lists slowly, so it reads them in pages
PG=100
((BASH_VERSINFO[0] * 100 + BASH_VERSINFO[1] < 401)) || PG=0
CURL=(-q -s --noproxy '*' -4 -m2 -HUser-Agent: --fail-with-body '-HContent-Type: text/xml; charset="utf-8"')

# Service paths; Master channel argument
AVT=MediaRenderer/AVTransport CH='<Channel>Master</Channel>' DP=DeviceProperties RC=MediaRenderer/RenderingControl

[[ ${1-} == --xdbg ]] && {
  shift
  PS4='+\e[5G\e[36m$(((${EPOCHREALTIME/./}-_ERT+500)/1000))\e[9G\e[33m$LINENO\e[13G\e[90m>\e[15G\e[m'
  _ERT=${EPOCHREALTIME=0} _ERT=${_ERT/./} # Bash <5: nounset-safe, zero timing.
  set -x
}

# Report and exit - <code> [action] [UPnP error]
error() {
  local msg

  case $1 in
  6 | 7 | 18 | 28 | 52 | 56) msg='Network failure, Sonos offline?' ;;
  22) msg="Server error on ${2-request}." ;;
  200) msg='Missing or invalid option.' ;;
  201) msg='Missing or invalid argument.' ;;
  202) msg='Invalid response from Sonos.' ;;
  203) [[ $3 == 701 ]] && msg="$2 not available for the current source." || msg="Sonos refused $2, UPnP error $3." ;;
  204) msg="Set SONOS_IP to the speaker's IP address or .local name." ;;
  205) msg="Favorite $2 is a shortcut; play it from the Sonos app." ;;
  *) msg="Unexpected curl error $1." ;;
  esac

  printf '%s\n' "$msg" >&2
  exit "$1"
}

# Print the speaker's details as key=value, or one field of its device description - [key]
about() {
  local k keys=(modelName modelNumber roomName displayVersion softwareVersion hardwareVersion
    serialNum MACAddress apiVersion) v

  if [[ -n $1 ]]; then
    [[ $1 =~ ^[[:alnum:]]{2,32}$ ]] || error 201
    keys=("$1")
  fi

  get xml/device_description.xml
  for k in "${keys[@]}"; do
    # The root device's fields come before those of its embedded devices
    [[ $REPLY =~ "<$k>"([^<]*)"</$k>" ]] || continue
    v=${BASH_REMATCH[1]//&lt;/<} v=${v//&gt;/>} v=${v//&quot;/\"} v=${v//&apos;/\'} v=${v//&amp;/\&}
    v=${v//[[:cntrl:]]/}
    [[ -n $1 ]] && printf '%s\n' "$v" || printf '%s=%s\n' "$k" "$v"
  done
}

# Track artwork URL; the player serves relative ones
artwork() {
  local url

  soap "$AVT" GetPositionInfo
  didl url upnp:albumArtURI
  [[ -z $url ]] || printf '%s\n' "${url/#\//$BASE/}"
}

# Browse a container's children - <object id> [start] [count, 0 for all; default PG]
browse() {
  soap MediaServer/ContentDirectory Browse \
    "<ObjectID>$1</ObjectID><BrowseFlag>BrowseDirectChildren</BrowseFlag><Filter>*</Filter><StartingIndex>${2-0}</StartingIndex><RequestedCount>${3-$PG}</RequestedCount><SortCriteria></SortCriteria>"
}

# Print prefix, then "artist / title [album]" of REPLY's DIDL-Lite (radio: stream content as title) - <prefix>
desc() {
  local alb art q tit

  didl alb upnp:album
  didl art dc:creator
  didl tit dc:title
  didl q r:streamContent
  [[ -z $q ]] || tit=$q
  tit=$art${art:+${tit:+ / }}$tit${alb:+ [$alb]}
  printf '%s%s\n' "$1" "${tit:-UNKNOWN}"
}

# DIDL-Lite element of REPLY, unescaped, controls stripped - <var> <element>
didl() {
  local v=''

  [[ $REPLY =~ "&lt;$2&gt;"(([^&]|&[^l])*)"&lt;/$2&gt;" ]] && v=${BASH_REMATCH[1]}
  # Escaped twice: DIDL-Lite text inside SOAP; the match stops at &l, so the outer level holds no &lt;
  v=${v//&gt;/>} v=${v//&quot;/\"} v=${v//&apos;/\'} v=${v//&amp;/\&}
  v=${v//&lt;/<} v=${v//&gt;/>} v=${v//&quot;/\"} v=${v//&apos;/\'} v=${v//&amp;/\&}
  printf -v "$1" %s "${v//[[:cntrl:]]/}"
}

# List favorites, or play favorite n; containers go through the queue - [n]
favorites() {
  local md='' uri

  if [[ -z $1 ]]; then
    list FV:2
    return
  fi

  [[ $1 =~ ^[1-9][0-9]{0,4}$ ]] || error 201
  browse FV:2 $(($1 - 1)) 1
  [[ $REPLY == *'<NumberReturned>1</NumberReturned>'* ]] || error 201
  res uri
  [[ -n $uri ]] || error 205 "$1"

  [[ $REPLY =~ '&lt;r:resMD&gt;'(([^&]|&[^l])*)'&lt;/r:resMD&gt;' ]] && md=${BASH_REMATCH[1]}
  # The match stops at &l, so it holds no &lt;
  md=${md//&gt;/>} md=${md//&quot;/\"} md=${md//&apos;/\'} md=${md//&amp;/\&}

  case $uri in
  x-rincon-cpcontainer:* | x-rincon-playlist:* | file:*)
    soap "$AVT" AddURIToQueue \
      "<EnqueuedURI>$uri</EnqueuedURI><EnqueuedURIMetaData>$md</EnqueuedURIMetaData><DesiredFirstTrackNumberEnqueued>0</DesiredFirstTrackNumberEnqueued><EnqueueAsNext>0</EnqueueAsNext>"
    tag FirstTrackNumberEnqueued '[0-9]{1,5}'
    playqueue "${BASH_REMATCH[1]}"
    ;;
  *)
    soap "$AVT" SetAVTransportURI "<CurrentURI>$uri</CurrentURI><CurrentURIMetaData>$md</CurrentURIMetaData>"
    soap "$AVT" Play '<Speed>1</Speed>'
    ;;
  esac
}

# Play a file from an SMB share the speaker can read - <//host/share/path>
file() {
  local LC_ALL=C c i n uri=${1#//}

  [[ $1 =~ ^//[^/]+/[^/]+/.*[^/]$ ]] || error 201
  # Percent-encode the bytes outside the unreserved set, if there are any
  if [[ $uri == *[^[:alnum:]/._~+-]* ]]; then
    uri=''
    for ((i = 2; i < ${#1}; i++)); do
      c=${1:i:1}
      case $c in
      [[:alnum:]/._~+-]) uri+=$c ;;
      *)
        # Bash 3.2 sign-extends bytes above 0x7F
        printf -v n %d "'$c"
        printf -v c %%%02X $((n & 255))
        uri+=$c
        ;;
      esac
    done
  fi

  soap "$AVT" SetAVTransportURI "<CurrentURI>x-file-cifs://$uri</CurrentURI><CurrentURIMetaData></CurrentURIMetaData>"
  soap "$AVT" Play '<Speed>1</Speed>'
}

# GET a page into REPLY - <path>
get() {
  [[ -n ${SONOS_IP-} ]] || error 204
  REPLY=$(LC_ALL=C curl "${CURL[@]}" "$BASE/$1") || error $? "$1"
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

# Print a container's items as "n) artist / title [album]", with "> " for item cur if its res is uri;
# the speaker caps each reply, so read on until TotalMatches - <object id> [cur] [uri]
list() {
  # C: faster splitting; in a variable, as Bash 3.2 takes a quoted / in a pattern for the separator
  local LC_ALL=C e='&lt;/item&gt;' i=0 it items j n t

  while :; do
    browse "$1" "$i"
    tag TotalMatches '[0-9]{1,6}'
    n=${BASH_REMATCH[1]} j=$i
    if ((PG)); then
      # Bash 3.2: ${x//…} slows down quadratically or worse, so cut item by item
      items=() t=$REPLY
      while [[ $t == *"$e"* ]]; do
        it=${t%%"$e"*}
        items+=("$it")
        t=${t:${#it}+${#e}}
      done
      items+=("$t")
    else
      IFS=$'\x1e' read -r -d '' -a items <<<"${REPLY//"$e"/$'\x1e'}" || :
    fi

    for it in "${items[@]}"; do
      [[ $it == *'&lt;item '* ]] || continue
      REPLY=$it
      # Current: same track number and URI, as the queue may not be the source
      if ((++i == ${2-0})) && res t && [[ $t == "${3-}" ]]; then
        desc "$i) > "
      else
        desc "$i) "
      fi
    done
    # A page that brings nothing new ends it too
    ((i < n && i > j)) || return 0
  done
}

# Print "artist / title [album]", then position, duration, quality and source
now() {
  local bits=0 dur fmt='' loss='' lq=(lossy lossless) pos q='' rate=0 src

  soap "$AVT" GetPositionInfo
  secs pos RelTime
  secs dur TrackDuration
  didl q r:streamInfo
  [[ $q =~ (^|,)bd:([0-9]{1,2})(,|$) ]] && bits=$((10#${BASH_REMATCH[2]}))
  [[ $q =~ (^|,)sr:([0-9]{4,6})(,|$) ]] && rate=$((10#${BASH_REMATCH[2]}))
  [[ $q =~ (^|,)l:([01])(,|$) ]] && loss=${BASH_REMATCH[2]}
  # Files report no stream info, only the format in their MIME type
  [[ $REPLY =~ 'protocolInfo=&quot;'[[:alnum:].-]+':'[^:]*':audio/'([[:alnum:].+-]+)':' ]] && fmt=${BASH_REMATCH[1]}

  # Source: the URI scheme, or for Virtual Line-In the service after the comma
  tag TrackURI
  src=${BASH_REMATCH[1]%%:*}
  case $src in
  x-file-cifs) src='file' ;;
  x-sonos-htastream) src=tv ;;
  x-sonos-vli) src=${BASH_REMATCH[1]#*,} src=${src%%:*} ;;
  *) src=${src#x-} src=${src#sonos-} src=${src#sonosapi-} src=${src#rincon-} ;;
  esac
  src=${src//[^[:alnum:]._-]/}

  # kHz as %g would print it, without its locale switch
  if ((rate)); then
    q=$((rate % 1000 + 1000)) q=${q#1} q=${q%0} q=${q%0} q=${q%0} rate=" $((rate / 1000))${q:+.$q}kHz"
  else
    rate=''
  fi

  ((bits)) && bits=" ${bits}bit" || bits=''
  q=${fmt:+ $fmt}${loss:+ ${lq[loss]}}$rate$bits
  desc ''
  printf '%d:%02d / %d:%02d%s [%s]\n' $((pos / 60)) $((pos % 60)) $((dur / 60)) $((dur % 60)) "${q:+ -$q}" \
    "${src:-UNKNOWN}"
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

# Play the queue from track n, switching to it first if needed - <n>
playqueue() {
  local id

  soap "$AVT" GetMediaInfo
  tag CurrentURI
  if [[ ${BASH_REMATCH[1]} != x-rincon-queue:* ]]; then
    rincon id
    soap "$AVT" SetAVTransportURI \
      "<CurrentURI>x-rincon-queue:$id#0</CurrentURI><CurrentURIMetaData></CurrentURIMetaData>"
  fi
  soap "$AVT" Seek "<Unit>TRACK_NR</Unit><Target>$1</Target>"
  soap "$AVT" Play '<Speed>1</Speed>'
}

# Print the reply to a UPnP action; curl replaces the subshell it runs in - <service path> <action> [arguments]
post() {
  local urn=urn:schemas-upnp-org:service:${1##*/}:1

  LC_ALL=C exec curl "${CURL[@]}" "-HSOAPACTION: \"$urn#$2\"" "$BASE/$1/Control" \
    -d "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body><u:$2 xmlns:u=\"$urn\"><InstanceID>0</InstanceID>${3-}</u:$2></s:Body></s:Envelope>"
}

# List the queue, marking the current track, or play from track n - [n]
queue() {
  local cur uri

  if [[ -n $1 ]]; then
    [[ $1 =~ ^[1-9][0-9]{0,4}$ ]] || error 201
    playqueue "$1"
    return
  fi

  # One at a time: next to another curl, the Browse reply stalls ~100 ms in 1 run of 4
  soap "$AVT" GetPositionInfo
  tag Track '[0-9]{1,5}'
  cur=${BASH_REMATCH[1]}
  tag TrackURI
  uri=${BASH_REMATCH[1]}
  list Q:0 "$cur" "$uri"
}

# Check REPLY to an action; exits on fault, curl error or foreign reply - <action> [curl status]
reply() {
  ((${2-0} == 0)) && [[ $REPLY == *[\<:]"$1"Response[[:space:]/\>]* ]] && return
  [[ $REPLY =~ '<errorCode>'([0-9]{1,4})'</errorCode>' ]] && error 203 "$1" "${BASH_REMATCH[1]}"
  ((${2-0} == 0)) || error "$2" "$1"
  error 202
}

# res URI of REPLY's DIDL-Lite item, escaped once as in a SOAP body - <var>
res() {
  local v=''

  [[ $REPLY =~ '&lt;res'([^&]|&quot;|&amp;)*'&gt;'(([^&]|&[^l])*)'&lt;/res&gt;' ]] && v=${BASH_REMATCH[2]}
  # The match stops at &l, so it holds no &lt;
  v=${v//&gt;/>} v=${v//&quot;/\"} v=${v//&apos;/\'} v=${v//&amp;/\&}
  printf -v "$1" %s "$v"
}

# This player's id - <var>
rincon() {
  get xml/device_description.xml
  tag UDN 'uuid:RINCON_[[:alnum:]]{1,32}'
  printf -v "$1" %s "${BASH_REMATCH[1]#uuid:}"
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

  # Relative: one request; the speaker stops at 0:00, and past the end skips to the next track
  [[ -z $sign ]] || unit=TIME_DELTA
  printf -v val '%s%d:%02d:%02d' "$sign" $((val / 3600)) $((val / 60 % 60)) $((val % 60))
  soap "$AVT" Seek "<Unit>$unit</Unit><Target>$val</Target>"
}

# Send UPnP action; sets REPLY, exits on fault or foreign reply - <service path> <action> [arguments]
soap() {
  local rc=0

  # Here, so option and argument errors come first
  [[ -n ${SONOS_IP-} ]] || error 204
  REPLY=$(post "$@") || rc=$?
  reply "$2" "$rc"
}

# Get or set speech enhancement (0 off, 1..4 level) - [arg]
speech() {
  local dl='<EQType>DialogLevel</EQType>' se='<EQType>SpeechEnhanceEnabled</EQType>'

  if [[ -z $1 ]]; then
    # One after the other: a second curl alongside can lose its exit status, and stalls up to ~200 ms
    soap "$RC" GetEQ "$se"
    tag CurrentValue '[01]'
    if ((BASH_REMATCH[1])); then
      soap "$RC" GetEQ "$dl"
      tag CurrentValue '[0-4]'
      printf '%s\n' "${BASH_REMATCH[1]}"
    else
      # Off: the level doesn't matter, so don't ask for it
      printf '0\n'
    fi
  elif [[ $1 =~ ^[0-4]$ ]]; then
    # Level 0 is accepted but ignored; off is a separate switch
    soap "$RC" SetEQ "$se<DesiredValue>$(($1 > 0))</DesiredValue>"
    (($1 == 0)) || soap "$RC" SetEQ "$dl<DesiredValue>$1</DesiredValue>"
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

# Switch to the TV input; the stream URI needs this player's id
tv() {
  local id

  rincon id
  soap "$AVT" SetAVTransportURI \
    "<CurrentURI>x-sonos-htastream:$id:spdif</CurrentURI><CurrentURIMetaData></CurrentURIMetaData>"
}

usage() {
  local nm=${0##*/}

  printf '%s\n' "$nm 2.0 - Control Sonos over UPnP
Copyright (C) 2026 Stouthart. All rights reserved.

Usage: $nm <option> [argument]

Playback:
  artwork | next | now | pause | play | prev | stop
  repeat 0..2 | seek 0..3599 | shuffle 0..1

Sources:
  favorites 1..n | file //host/share/path | tv

Queue:
  clear | queue 1..n

Audio:
  bass -10..10 | height -10..10 | lipsync 0..5 | loudness 0..1 | mute 0..1
  night 0..1 | speech 0..4 | treble -10..10 | vol 0..100

Other:
  about | led 0..1 | sleep 0..120

Omit the argument to read the current value.
Volume and seek accept a relative value (e.g. vol +5, seek -30).
Seek also accepts a min:sec position or offset (e.g. 3:39, -1:30).
About accepts a key (e.g. about modelName).
Requires SONOS_IP: the speaker's IP address or .local name."
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
    # The speaker clamps to 0..100
    soap "$RC" SetRelativeVolume "$CH<Adjustment>${BASH_REMATCH[0]#+}</Adjustment>"
  else
    value "$RC" Volume Volume "$CH" 0 100 "$1"
  fi
}

(($# < 3)) || error 201
opt=${1-} arg=${2-}

# No-argument options
case $opt in
'' | -h | --help | help | artwork | clear | next | now | pause | play | prev | previous | stop | tv)
  (($# < 2)) || error 201
  ;;
esac

case $opt in
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
favorites | favourites | favs)
  favorites "$arg"
  ;;
file)
  file "$arg"
  ;;
tv)
  tv
  ;;
clear)
  soap "$AVT" RemoveAllTracksFromQueue
  ;;
queue | playqueue)
  queue "$arg"
  ;;
bass)
  value "$RC" Bass Bass '' -10 10 "$arg"
  ;;
height)
  value "$RC" EQ Value '<EQType>HeightChannelLevel</EQType>' -10 10 "$arg"
  ;;
lipsync)
  value "$RC" EQ Value '<EQType>AudioDelay</EQType>' 0 5 "$arg"
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
about)
  about "$arg"
  ;;
led)
  led "$arg"
  ;;
sleep)
  timer "$arg"
  ;;
'' | -h | --help | help)
  usage
  ;;
*)
  error 200
  ;;
esac

exit
