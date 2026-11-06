#!/usr/bin/env bash
# Plain shebang, unlike soc.sh: runs on any env, BusyBox's included
# No pathname expansion: nothing needs it, and list splits words
set -efuo pipefail
IFS=$'\n\t'

BASE=http://${SONOS_IP-}:1400
# 1: the option plays or queues, which in a group only its leader does, so the first request finds that one first; 2:
# found, or not needed
LEADER=0
# The GetMediaInfo reply that finding the leader got, when there was none to follow: artwork reuses it
MEDIA=''
# Bash before 4.1 splits long lists slowly, so reads pages
PG=100
((BASH_VERSINFO[0] * 100 + BASH_VERSINFO[1] < 401)) || PG=0
# Per transfer; --next resets them. A reply over 16 MiB is refused, as soc.sh's read cap does; before curl 8.4,
# --max-filesize can't stop one of unknown length, as Browse's chunked replies, so get and reply check what came
MAX=16777216
CURL=(-g --noproxy '*' -4 -m2 --max-filesize "$MAX" -HUser-Agent: --fail-with-body
  '-HContent-Type: text/xml; charset="utf-8"')

# Service paths; Master channel argument
AVT=MediaRenderer/AVTransport CH='<Channel>Master</Channel>' DP=DeviceProperties RC=MediaRenderer/RenderingControl
# C1 controls (U+0080..U+009F) in UTF-8, which [[:cntrl:]] only matches in a UTF-8 locale
C1=$'\xc2[\x80-\x9f]'

[[ ${1-} == --xdbg ]] && {
  shift
  PS4='+\e[5G\e[36m$(((${EPOCHREALTIME/./}-_ERT+500)/1000))\e[9G\e[33m$LINENO\e[13G\e[90m>\e[15G\e[m'
  _ERT=${EPOCHREALTIME=0} _ERT=${_ERT/./} # Bash <5: nounset-safe, zero timing
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
  202 | 63) msg='Invalid response from Sonos.' ;; # 63: over the reply cap
  203) [[ $3 == 701 ]] && msg="$2 not available for the current source." || msg="Sonos refused $2, UPnP error $3." ;;
  204) msg="Set SONOS_IP to the speaker's IP address or .local name." ;;
  205) msg="Favorite $2 is a shortcut; play it from the Sonos app." ;;
  *) msg="Unexpected curl error $1." ;;
  esac

  printf '%s\n' "$msg" >&2
  exit "$1"
}

# Print the speaker's details as key=value, or one device description field - [key]
about() {
  local k keys=(displayName roomName serialNum swGen softwareVersion hardwareVersion displayVersion apiVersion) v

  if [[ -n $1 ]]; then
    [[ $1 =~ ^[[:alnum:]]{2,32}$ ]] || error 201
    keys=("$1")
  fi

  get xml/device_description.xml
  for k in "${keys[@]}"; do
    # The root device's fields precede its embedded devices'
    [[ $REPLY =~ "<$k>"([^<]*)"</$k>" ]] || continue
    v=${BASH_REMATCH[1]}
    [[ $v != *'&'* ]] || v=${v//&lt;/<} v=${v//&gt;/>} v=${v//&quot;/\"} v=${v//&apos;/\'} v=${v//&amp;/\&}
    v=${v//[[:cntrl:]]/} v=${v//$C1/}
    [[ -n $1 ]] && printf '%s\n' "$v" || printf '%s=%s\n' "$k" "$v"
  done
}

# Track artwork URL on the network: relative ones are the player's, and for art elsewhere, as Spotify's on HTTPS, the
# player serves its own copy by the track's URI
artwork() {
  local kind uri url

  soap "$AVT" GetPositionInfo
  didl url upnp:albumArtURI
  tag TrackURI
  origin kind "${BASH_REMATCH[1]}"
  # A station's own picture, as the Sonos app shows it, by the station's URI: Sonos Radio's always, as the speaker's
  # copy of a track's cover there can be another station's logo; another station's when its song has none. From
  # the GetMediaInfo that finding the leader got, else one request more
  if [[ $kind == sonos-radio || ($kind == radio && -z $url) ]]; then
    if [[ -n $MEDIA ]]; then REPLY=$MEDIA; else soap "$AVT" GetMediaInfo; fi
    didl url upnp:albumArtURI
    tag CurrentURI
    uri=${BASH_REMATCH[1]}
  else
    res uri
  fi
  if [[ $url == /* ]]; then
    url=$BASE$url
  elif [[ -n $url ]] && ! lan "$url"; then
    # Elsewhere, as Spotify's on HTTPS or a station's logo on the internet: the speaker's copy by the track's URI, or
    # the station's, unescaped once (res and CurrentURI keep one level for SOAP), or none when there's no URI to ask by
    url=''
    [[ -z $uri ]] || {
      uri=${uri//&amp;/\&} # Unquoted: quoted, Bash 3.2 keeps the \; bare, from Bash 5.2 & stands for the match
      pct uri "$uri" '0-9A-Za-z._~-'
      url="$BASE/getaa?s=1&u=$uri"
    }
  fi
  [[ -z $url ]] || printf '%s\n' "$url"
}

# Browse a container's children - <object id> [start] [count, 0 for all; default PG]
browse() {
  soap MediaServer/ContentDirectory Browse \
    "<ObjectID>$1</ObjectID><BrowseFlag>BrowseDirectChildren</BrowseFlag><Filter>*</Filter><StartingIndex>${2-0}</StartingIndex><RequestedCount>${3-$PG}</RequestedCount><SortCriteria></SortCriteria>"
}

# The source of a track URI, as SOAP escapes it: the URI scheme, or for Virtual Line-In the service after the comma;
# line-in and radio by name, as both stream; a music service by its number, Sonos Radio's on radio too; and a group
# member's own as group - <var> <uri>
origin() {
  local n='' re='[?&;]sid=([0-9]{1,5})(&|$)' s=${2%%:*}

  # The service's number in a Sonos link's query, as x-sonos-http:…?sid=31; the ; of an escaped &amp;
  [[ $2 != x-sonos* || ! $2 =~ $re ]] || n=${BASH_REMATCH[1]}
  case $s in
  x-file-cifs) s='file' ;;
  x-sonos-htastream) s=tv ;;
  x-sonos-vli) s=${2#*,} s=${s%%:*} ;;
  x-rincon) s=group ;;
  x-rincon-stream) s=line-in ;;
  aac | hls-radio | x-rincon-mp3radio | x-sonosapi-hls | x-sonosapi-radio | x-sonosapi-stream) s=radio ;;
  *)
    # The common on-demand services by the numbers the speakers list them by (ListAvailableServices); any other by
    # its link's scheme, as http
    case $n in
    2) s=deezer ;;
    31) s=qobuz ;;
    160) s=soundcloud ;;
    174) s=tidal ;;
    201) s=amazon-music ;;
    204) s=apple-music ;;
    212) s=plex ;;
    271) s=idagio ;;
    284) s=youtube-music ;;
    *) s=${s#x-} s=${s#sonos-} s=${s#sonosapi-} s=${s#rincon-} ;;
    esac
    ;;
  esac
  # Sonos Radio, 303: its stations and the tracks they play
  [[ $n != 303 ]] || s=sonos-radio
  printf -v "$1" %s "${s//[^[:alnum:]._-]/}"
}

# Print prefix, then "artist / title [album]" of REPLY's DIDL-Lite (radio: stream content as title) - <prefix>
desc() {
  local alb art q tit

  didl alb upnp:album
  didl art dc:creator
  didl tit dc:title
  didl q r:streamContent
  # Not the speaker's own state while it connects, ZPSTR_CONNECTING or ZPSTR_BUFFERING, which the Sonos app hides
  [[ -z $q || $q == ZPSTR_* ]] || tit=$q
  tit=$art${art:+${tit:+ / }}$tit${alb:+ [$alb]}
  printf '%s%s\n' "$1" "${tit:-UNKNOWN}"
}

# DIDL-Lite element of REPLY, unescaped, controls stripped - <var> <element>
didl() {
  local v=''

  [[ $REPLY =~ "&lt;$2&gt;"(([^&]|&[^l])*)"&lt;/$2&gt;" ]] && v=${BASH_REMATCH[1]}
  # Escaped twice: DIDL-Lite text inside SOAP; the match stops at &l, so the outer level holds no &lt;
  [[ $v != *'&'* ]] || {
    v=${v//&gt;/>} v=${v//&quot;/\"} v=${v//&apos;/\'} v=${v//&amp;/\&}
    v=${v//&lt;/<} v=${v//&gt;/>} v=${v//&quot;/\"} v=${v//&apos;/\'} v=${v//&amp;/\&}
  }
  v=${v//[[:cntrl:]]/}
  printf -v "$1" %s "${v//$C1/}"
}

# List favorites, or play favorite n; containers go through the queue - [n]
favorites() {
  local add md='' mode off='' uri

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
    # With shuffle on, the speaker mixes the tracks added into its shuffled order and counts positions in that, so the
    # one it reports may be another's, even one queued before: shuffle off while they're added and the first starts,
    # then on again, which shuffles the rest and keeps that one playing. Left off if the speaker refuses on the way
    soap "$AVT" GetTransportSettings
    tag PlayMode '[A-Z_]{1,20}'
    mode=${BASH_REMATCH[1]}
    case $mode in
    SHUFFLE_NOREPEAT) off=NORMAL ;;
    SHUFFLE) off=REPEAT_ALL ;;
    SHUFFLE_REPEAT_ONE) off=REPEAT_ONE ;;
    esac
    add=("$AVT" AddURIToQueue
      "<EnqueuedURI>$uri</EnqueuedURI><EnqueuedURIMetaData>$md</EnqueuedURIMetaData><DesiredFirstTrackNumberEnqueued>0</DesiredFirstTrackNumberEnqueued><EnqueueAsNext>0</EnqueueAsNext>")
    # Shuffle off in the same curl run: the add's reply comes last
    if [[ -n $off ]]; then soap "$AVT" SetPlayMode "<NewPlayMode>$off</NewPlayMode>" "${add[@]}"; else soap "${add[@]}"; fi
    tag FirstTrackNumberEnqueued '[0-9]{1,5}'
    playqueue "${BASH_REMATCH[1]}"
    [[ -z $off ]] || soap "$AVT" SetPlayMode "<NewPlayMode>$mode</NewPlayMode>"
    ;;
  *)
    soap "$AVT" SetAVTransportURI "<CurrentURI>$uri</CurrentURI><CurrentURIMetaData>$md</CurrentURIMetaData>" \
      "$AVT" Play '<Speed>1</Speed>'
    ;;
  esac
}

# Play a file from an SMB share the speaker can read - <//host/share/path>
file() {
  local uri

  [[ $1 =~ ^//[^/]+/[^/]+/.*[^/]$ ]] || error 201
  # The path's slashes and + stay
  pct uri "${1#//}" '0-9A-Za-z/._~+-'

  soap "$AVT" SetAVTransportURI "<CurrentURI>x-file-cifs://$uri</CurrentURI><CurrentURIMetaData></CurrentURIMetaData>" \
    "$AVT" Play '<Speed>1</Speed>'
}

# Point BASE at the leader that REPLY's x-rincon URI names, as a group member's does: it refuses Pause (UPnP error 701),
# ignores Play, and reports neither the group's track nor its queue. 1 if REPLY names none
follow() {
  local id loc

  [[ $REPLY =~ '>x-rincon:'(RINCON_[[:alnum:]]{1,32})'</' ]] || return 1
  id=${BASH_REMATCH[1]}
  soap ZoneGroupTopology GetZoneGroupState
  member loc Location UUID "$id&quot;" || error 202
  [[ $loc =~ ^http://([0-9]{1,3}(\.[0-9]{1,3}){3}):1400/ ]] || error 202
  BASE=http://${BASH_REMATCH[1]}:1400
}

# GET a page into REPLY - <path>
get() {
  [[ -n ${SONOS_IP-} ]] || error 204
  REPLY=$(LC_ALL=C curl -q -s "${CURL[@]}" "$BASE/$1") || error $? "$1"
  ((${#REPLY} <= MAX)) || error 63
}

# Number within max; sets BASH_REMATCH - <arg> <max>
isnum() {
  [[ $1 =~ ^([+-]?)(0|[1-9][0-9]{0,3})$ && ${BASH_REMATCH[2]} -le $2 ]]
}

# An http URL on the local network, at a private, link-local or loopback IPv4 address: as a UPnP server's cover - <url>
lan() {
  [[ $1 =~ ^http://((10|127)\.[0-9]{1,3}|192\.168|169\.254|172\.(1[6-9]|2[0-9]|3[01]))(\.[0-9]{1,3}){2}(:[0-9]{1,5})?(/|$) ]]
}

# Play and queue on the group's leader: one small request alone, another for a group member - before soap posts
leader() {
  LEADER=2
  soap "$AVT" GetMediaInfo
  # Kept for artwork, unless it named a leader: that one's own is asked then
  if follow; then MEDIA=''; else MEDIA=$REPLY; fi
}

# Print a container's items as "n) artist / title [album]", "> " marking item cur if its res is uri;
# replies are capped, so read on to TotalMatches - <object id> [cur] [uri]
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
      # In memory: read would take a here-string through a pipe, one byte at a time
      IFS=$'\x1e'
      # shellcheck disable=SC2206 # split on the separator alone; no pathname expansion (set -f)
      items=(${REPLY//"$e"/$'\x1e'})
      IFS=$'\n\t'
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

# An attribute of the topology member in REPLY whose attribute by starts with value, escaped as the reply has it, so
# value can end in &quot; to match whole; attributes in any order - <var> <attribute> <by> <value>
member() {
  local m rest=$REPLY

  while [[ $rest == *'&lt;ZoneGroupMember '* ]]; do
    rest=${rest#*'&lt;ZoneGroupMember '}
    # Up to the tag's end: a value's own > comes escaped twice
    m=" ${rest%%'&gt;'*}"
    [[ $m == *" $3=&quot;$4"* && $m =~ ' '"$2"'=&quot;'([^&]*)'&quot;' ]] || continue
    printf -v "$1" %s "${BASH_REMATCH[1]}"
    return 0
  done
  return 1
}

# Get or set mute; in a group, on every room - [0..1]
mute() {
  if [[ -z $1 ]]; then
    value Mute "$CH" 0 1 ''
  elif [[ $1 =~ ^[01]$ ]]; then
    together SetMute DesiredMute "$1"
  else
    error 201
  fi
}

# Print "artist / title [album]", then position, duration, quality (TV: input format) and source
now() {
  local bits=0 c dur fmt='' link loss='' lq=(lossy lossless) pos q='' rate=0 src t tvf u

  soap "$AVT" GetPositionInfo
  # A group member names its leader in place of a track: that one tells. No request more for a speaker alone
  if ((LEADER == 0)) && follow; then
    LEADER=2
    now
    return
  fi
  secs pos RelTime
  secs dur TrackDuration
  didl q r:streamInfo
  [[ $q =~ (^|,)bd:([0-9]{1,2})(,|$) ]] && bits=$((10#${BASH_REMATCH[2]}))
  [[ $q =~ (^|,)sr:([0-9]{4,6})(,|$) ]] && rate=$((10#${BASH_REMATCH[2]}))
  [[ $q =~ (^|,)l:([01])(,|$) ]] && loss=${BASH_REMATCH[2]}
  # Files report no stream info, only the format in their MIME type (x-flac as flac); a cast from a UPnP app
  # also carries its own rate and bit depth
  [[ $REPLY =~ 'protocolInfo=&quot;'[[:alnum:].-]+':'[^:]*':audio/'([[:alnum:].+-]+)':' ]] && fmt=${BASH_REMATCH[1]#x-}
  # Spotify from the Sonos app's queue: audio/x-spotify names the service, not a format
  [[ $fmt != spotify ]] || fmt=''
  ((rate == 0)) && [[ $REPLY =~ 'sampleFrequency=&quot;'([0-9]{4,7})'&quot;' ]] && rate=$((10#${BASH_REMATCH[1]}))
  ((bits == 0)) && [[ $REPLY =~ 'bitsPerSample=&quot;'([0-9]{1,2})'&quot;' ]] && bits=$((10#${BASH_REMATCH[1]}))

  tag TrackURI
  link=${BASH_REMATCH[1]}
  origin src "$link"

  # kHz as %g would print it, without its locale switch
  if ((rate)); then
    q=$((rate % 1000 + 1000)) q=${q#1} q=${q%0} q=${q%0} q=${q%0} rate=" $((rate / 1000))${q:+.$q}kHz"
  else
    rate=''
  fi

  ((bits)) && bits=" ${bits}bit" || bits=''
  q=${fmt:+ $fmt}${loss:+ ${lq[loss]}}$rate$bits
  # A station, Sonos Radio's too, with no title, as some send while starting, or one that's no more than its link's
  # file name, as while it's paused and sends no song, or while the speaker connects (desc): its name from
  # GetMediaInfo instead, one request more then
  if [[ $src == radio || $src == sonos-radio ]]; then
    didl t dc:title
    didl c r:streamContent
    [[ $c != ZPSTR_* ]] || c=''
    u=${link%%\?*} u=${u##*/}
    [[ -n $c || (-n $t && (-z $u || ${t%%\?*} != "$u")) ]] || soap "$AVT" GetMediaInfo
  fi
  desc ''
  if [[ $src == tv ]]; then
    # The input format's code, by name; an unknown one shows as a number
    soap "$DP" GetZoneInfo
    tag HTAudioIn '[0-9]{1,10}'
    c=${BASH_REMATCH[1]}
    tvf='|0=No input connected|2=Stereo|7=Dolby Digital 2.0|18=Dolby Digital 5.1|21=No input|22=No audio'
    tvf+='|59=Dolby Atmos (DD+)|61=Dolby Atmos (TrueHD)|63=Dolby Atmos (MAT)|33554434=PCM 2.0|33554454=PCM 2.0 no audio'
    tvf+='|33554488=Dolby Digital 2.0|33554490=Dolby Digital Plus 2.0|33554492=Dolby TrueHD 2.0'
    tvf+='|33554494=Dolby Multichannel PCM 2.0|84934658=Multichannel PCM 5.1|84934713=Dolby Digital 5.1'
    tvf+='|84934714=Dolby Digital Plus 5.1|84934716=Dolby TrueHD 5.1|84934718=Dolby Multichannel PCM 5.1'
    tvf+='|84934721=DTS 5.1|118489090=Multichannel PCM 7.1|118489146=Dolby Digital Plus 7.1'
    tvf+='|118489148=Dolby TrueHD 7.1'
    [[ $tvf =~ "|$c="([^|]*) ]] && q+=" ${BASH_REMATCH[1]}" || q+=" format $c"
  fi
  printf '%d:%02d / %d:%02d%s [%s]\n' $((pos / 60)) $((pos % 60)) $((dur / 60)) $((dur % 60)) "${q:+ -$q}" \
    "${src:-UNKNOWN}"
}

# Get or set an On/Off device property as 0 or 1 - <property> <state for 0> <state for 1> [0..1]
onoff() {
  local states=("$2" "$3")

  if [[ -z $4 ]]; then
    soap "$DP" "Get$1"
    tag "Current$1" 'On|Off'
    [[ ${BASH_REMATCH[1]} == "$3" ]] && printf '1\n' || printf '0\n'
  elif [[ $4 =~ ^[01]$ ]]; then
    soap "$DP" "Set$1" "<Desired$1>${states[$4]}</Desired$1>"
  else
    error 201
  fi
}

# Percent-encode text outside the kept characters, given as a bracket expression's inside: bytes, or a character's
# UTF-8 bytes, as Android's Bash takes characters in every locale; spelled out, as Android's [[:alnum:]] takes é
# - <var> <text> <kept>
pct() {
  local LC_ALL=C b c i k n out=''

  if [[ $2 != *[^$3]* ]]; then
    printf -v "$1" %s "$2"
    return
  fi
  for ((i = 0; i < ${#2}; i++)); do
    c=${2:i:1}
    case $c in
    [$3]) out+=$c ;;
    *)
      # Bash 3.2 sign-extends bytes above 0x7F
      printf -v n %d "'$c"
      printf -v b %.1s "$c"
      if [[ $b == "$c" ]]; then
        printf -v c %%%02X $((n & 255))
      else
        # A character: its UTF-8 bytes from the code point
        ((k = 1 + (n > 2047) + (n > 65535)))
        printf -v c %%%02X $((256 - (128 >> k) | n >> 6 * k))
        while ((k--)); do
          printf -v c %s%%%02X "$c" $((128 | n >> 6 * k & 63))
        done
      fi
      out+=$c
      ;;
    esac
  done
  printf -v "$1" %s "$out"
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
      "<CurrentURI>x-rincon-queue:$id#0</CurrentURI><CurrentURIMetaData></CurrentURIMetaData>" \
      "$AVT" Seek "<Unit>TRACK_NR</Unit><Target>$1</Target>" "$AVT" Play '<Speed>1</Speed>'
  else
    soap "$AVT" Seek "<Unit>TRACK_NR</Unit><Target>$1</Target>" "$AVT" Play '<Speed>1</Speed>'
  fi
}

# Print the replies to UPnP actions, one after the other; curl replaces the subshell it runs in. A service path may
# name another speaker, as http://<address>:1400/<path>. With SOFT set, on through a refusal, each reply followed by
# US and its HTTP status, 000 for none - <service path> <action> [arguments] [<service path> <action> <arguments>]...
post() {
  local args=() early=--fail-early u urn w=$'\x1e'

  # SOFT: on through a failure, each reply with its HTTP status and curl's own for that transfer (curl 7.75)
  [[ -z ${SOFT-} ]] || early=--no-fail-early w=$'\x1f%{http_code}:%{exitcode}\x1e'

  while :; do
    urn=urn:schemas-upnp-org:service:${1##*/}:1
    u=$1
    [[ $u == http://* ]] || u=$BASE/$1
    ((${#args[@]} == 0)) || args+=(--next)
    args+=("${CURL[@]}" -w "$w" "-HSOAPACTION: \"$urn#$2\"" "$u/Control"
      -d "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body><u:$2 xmlns:u=\"$urn\"><InstanceID>0</InstanceID>${3-}</u:$2></s:Body></s:Envelope>")
    (($# > 3)) || break
    shift 3
  done
  # One process, one request after the other; --fail-early stops at the first failure and keeps its status. Sonos
  # refuses an action with HTTP 500, so the ones after it aren't sent; a 200 is the action done
  LC_ALL=C exec curl -q -s "$early" "${args[@]}"
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
  ((${#REPLY} <= MAX)) || error 63
  # Globs start with a literal after *, so the match skips ahead instead of trying a bracket at every byte
  ((${2-0} == 0)) && [[ $REPLY == *:"$1"Response[[:space:]/\>]* || $REPLY == *\<"$1"Response[[:space:]/\>]* ]] && return
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

# Send UPnP actions; sets REPLY to the last reply and REPLIES to the others, exits on fault, curl error or foreign
# reply - <service path> <action> [arguments] [<service path> <action> <arguments>]...
soap() {
  local r rc=0

  # Here, so option and argument errors come first
  [[ -n ${SONOS_IP-} ]] || error 204
  ((LEADER != 1)) || leader
  r=$(post "$@") || rc=$?
  REPLIES=()
  # curl ends each reply with RS and stops at the first failure, so replies followed by another got through
  while (($# > 3)) && [[ $r == *$'\x1e'?* ]]; do
    REPLY=${r%%$'\x1e'*}
    r=${r:${#REPLY}+1}
    reply "$2"
    REPLIES+=("$REPLY")
    shift 3
  done
  REPLY=${r%$'\x1e'}
  reply "$2" "$rc"
}

# Print the settings as option=value in the Sonos app's order: Sound (vol and mute aside), Sub audio, Home theater and
# Hardware. One the speaker hasn't got is left out, as Home theater on an Era 300, and Sub audio without a bonded Sub
settings() {
  local a calls=() cms code fault='' hts i out='' p parts rc v=()
  # Option, then the request for its value; speech takes two, its switch (no option) and level
  local r=(
    trueplay "$RC" GetRoomCalibrationStatus ''
    bass "$RC" GetBass ''
    treble "$RC" GetTreble ''
    height "$RC" GetEQ '<EQType>HeightChannelLevel</EQType>'
    loudness "$RC" GetLoudness "$CH"
    limit "$RC" GetEQ '<EQType>VolumeScalingFactor</EQType>'
    sub "$RC" GetEQ '<EQType>SubEnable</EQType>'
    sublevel "$RC" GetEQ '<EQType>SubGain</EQType>'
    phase "$RC" GetEQ '<EQType>SubPolarity</EQType>'
    '' "$RC" GetEQ '<EQType>SpeechEnhanceEnabled</EQType>'
    speech "$RC" GetEQ '<EQType>DialogLevel</EQType>'
    night "$RC" GetEQ '<EQType>NightMode</EQType>'
    lipsync "$RC" GetEQ '<EQType>AudioDelay</EQType>'
    light "$DP" GetLEDState ''
    touch "$DP" GetButtonLockState ''
    # No option either: for whether a Sub is bonded, the speaker's own address and the topology
    '' "$DP" GetZoneInfo ''
    '' ZoneGroupTopology GetZoneGroupState ''
  )

  [[ -n ${SONOS_IP-} ]] || error 204
  # One curl, one request after the other: ~175 ms, against ~255 ms with a curl each. On through a refusal, a setting
  # the speaker hasn't got: no value
  for ((i = 0; i < ${#r[@]}; i += 4)); do
    calls+=("${r[i + 1]}" "${r[i + 2]}" "${r[i + 3]}")
  done
  a=$(SOFT=1 post "${calls[@]}") || : # Its status is the last request's; each reply's comes with it
  # In memory, at once: cut one by one, the topology's length made it ~35 ms
  IFS=$'\x1e'
  # shellcheck disable=SC2206 # split on the separator alone; no pathname expansion (set -f)
  parts=($a)
  IFS=$'\n\t'
  ((${#parts[@]} == ${#r[@]} / 4)) || error 202 # Fewer replies than requests: curl stopped
  for ((i = 0; i < ${#r[@]}; i += 4)); do
    REPLY=${parts[i / 4]}
    code=${REPLY##*$'\x1f'} REPLY=${REPLY%$'\x1f'*}
    rc=${code#*:} code=${code%%:*}
    ((${#REPLY} <= MAX)) || error 63
    # A transfer that failed by itself, as one cut short, holds no setting; a refusal comes as HTTP 500, curl's 22
    ((rc == 0 || rc == 22)) || error "$rc" "${r[i + 2]}"
    if [[ $code == 200 ]]; then
      reply "${r[i + 2]}" # This action's own reply, not another's
      # The reply's first value; RoomCalibrationEnabled comes before Available. The speaker's address, and the
      # topology whole
      case ${r[i + 2]} in
      GetZoneInfo) p='<IPAddress>([0-9.]{7,15})</IPAddress>' ;;
      GetZoneGroupState) p='^(.*)$' ;;
      *)
        [[ ${r[i + 1]} == "$DP" ]] && p='On|Off' || p='-?[0-9]{1,3}'
        p="Response[^>]*><[[:alpha:]]+>($p)</"
        ;;
      esac
      [[ $REPLY =~ $p ]] || error 202
      v+=("${BASH_REMATCH[1]}")
    elif [[ $REPLY =~ '<errorCode>'([0-9]{1,4})'</errorCode>' ]]; then
      [[ -n $fault ]] || fault="${r[i + 2]} ${BASH_REMATCH[1]}"
      v+=('')
    else
      error 22 "${r[i + 2]}"
    fi
  done

  # A speaker answers the Sub's settings without one: its channel map tells, with a Sub on SW, as
  # RINCON_A:LF,RF;RINCON_B:SW (a soundbar's HTSatChanMapSet, a speaker's ChannelMapSet). Its member is the one at its
  # own address, as SONOS_IP may be a name
  if [[ -n ${v[6]} ]]; then
    [[ -n ${v[15]} && -n ${v[16]} ]] || error 202
    REPLY=${v[16]}
    member hts HTSatChanMapSet Location "http://${v[15]}:1400/" || hts=''
    member cms ChannelMapSet Location "http://${v[15]}:1400/" || cms=''
    [[ $hts$cms == *[:,]SW* ]] || v[6]='' v[7]='' v[8]=''
  fi
  # Speech is 0 while off; the light On is 1; the touch controls are on (1) while the buttons aren't locked
  [[ -z ${v[9]} ]] || ((v[9])) || v[10]=0
  [[ -z ${v[13]} ]] || { [[ ${v[13]} == On ]] && v[13]=1 || v[13]=0; }
  [[ -z ${v[14]} ]] || { [[ ${v[14]} == Off ]] && v[14]=1 || v[14]=0; }
  for ((i = 0; i < ${#r[@]}; i += 4)); do
    [[ -z ${r[i]} || -z ${v[i / 4]} ]] || out+=${r[i]}=${v[i / 4]}$'\n'
  done
  # Nothing at all is no speaker's settings: the first refusal, as the option itself would report it
  [[ -n $out ]] || error 203 "${fault% *}" "${fault#* }"
  printf %s "$out"
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
      # Off: no need to ask for the level
      printf '0\n'
    fi
  elif [[ $1 =~ ^[0-4]$ ]]; then
    # Level 0 is accepted but ignored; off is a separate switch
    if (($1)); then
      soap "$RC" SetEQ "$se<DesiredValue>1</DesiredValue>" "$RC" SetEQ "$dl<DesiredValue>$1</DesiredValue>"
    else
      soap "$RC" SetEQ "$se<DesiredValue>0</DesiredValue>"
    fi
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

# Set the volume or mute, and in a group every room's to the speaker's new one, as one level. The group's rooms are
# asked in the same curl, one request more; a bonded Sub or surround isn't a room: it follows its main speaker. The
# speaker gets its value again with the others: none is skipped by address - <action> <element> <value>
together() {
  local calls=() e=$2 id ids loc to=$3

  soap "$RC" "$1" "$CH<$2>$3</$2>" ZoneGroupTopology GetZoneGroupAttributes
  tag CurrentZonePlayerUUIDsInGroup '[[:alnum:]_,]*'
  ids=${BASH_REMATCH[1]},
  [[ $ids == *,?* ]] || return 0
  # A relative step: the others take where the speaker ended
  [[ $1 != SetRelativeVolume ]] || {
    REPLY=${REPLIES[0]}
    tag NewVolume '[0-9]{1,3}'
    to=${BASH_REMATCH[1]} e=DesiredVolume
  }

  soap ZoneGroupTopology GetZoneGroupState
  while [[ $ids == RINCON_* ]]; do
    id=${ids%%,*} ids=${ids#*,}
    member loc Location UUID "$id&quot;" || error 202
    [[ $loc =~ ^http://([0-9]{1,3}(\.[0-9]{1,3}){3}):1400/ ]] || error 202
    calls+=("http://${BASH_REMATCH[1]}:1400/$RC" "Set${e#Desired}" "$CH<$e>$to</$e>")
  done
  # One curl, one room after the other
  soap "${calls[@]}"
}

# Get or set Trueplay tuning - [0..1]
trueplay() {
  if [[ -z $1 ]]; then
    soap "$RC" GetRoomCalibrationStatus
    tag RoomCalibrationEnabled '[01]'
    printf '%s\n' "${BASH_REMATCH[1]}"
  elif [[ $1 =~ ^[01]$ ]]; then
    soap "$RC" SetRoomCalibrationStatus "<RoomCalibrationEnabled>$1</RoomCalibrationEnabled>"
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

  printf '%s\n' "$nm 4.0 - Control Sonos over UPnP
Copyright (C) 2026 Stouthart. All rights reserved.

Usage: $nm <option> [argument]

Playback:
  next | pause | play | prev | stop
  repeat 0..2 | seek 0..3599 | shuffle 0..1
  artwork | now | sleep 0..120

Sources:
  favorites 1..n | file //host/share/path | tv
  clear | queue 1..n | rescan

Sound:
  bass -10..10 | height -10..10 | limit 1..100 | loudness 0..1
  mute 0..1 | treble -10..10 | trueplay 0..1 | vol 0..100

Sub audio:
  phase 0..1 | sub 0..1 | sublevel -15..15

Home theater:
  lipsync 0..5 | night 0..1 | speech 0..4

Hardware:
  about | light 0..1 | settings | touch 0..1

Omit the argument to read the current value.
Volume and seek accept a relative value (e.g. vol +5, seek -30).
Seek also accepts a min:sec position or offset (e.g. 3:39, -1:30).
In a group, playback and the queue go to its leader; vol and mute
set every room to the same level.
Requires SONOS_IP: the speaker's IP address or .local name."
}

# Get or set a min..max RenderingControl value, EQ by its type - <action> <arguments | EQ type> <min> <max> [arg]
value() {
  local a=$2 e=$1

  [[ $1 != EQ ]] || a="<EQType>$2</EQType>" e=Value
  if [[ -z $5 ]]; then
    soap "$RC" "Get$1" "$a"
    tag "Current$e" '-?[0-9]{1,3}'
    printf '%s\n' "${BASH_REMATCH[1]}"
  elif [[ $5 =~ ^(0|-?[1-9][0-9]{0,2})$ ]] && (($5 >= $3 && $5 <= $4)); then
    soap "$RC" "Set$1" "$a<Desired$e>$5</Desired$e>"
  else
    error 201
  fi
}

# Get, set or adjust (±) volume; in a group, every room's - [arg]
volume() {
  if [[ -z $1 ]]; then
    value Volume "$CH" 0 100 ''
  elif ! isnum "$1" 100; then
    error 201
  elif [[ -n ${BASH_REMATCH[1]} ]]; then
    # The speaker clamps to 0..100
    together SetRelativeVolume Adjustment "${BASH_REMATCH[0]#+}"
  else
    together SetVolume DesiredVolume "$1"
  fi
}

(($# < 3)) || error 201
opt=${1-} arg=${2-}

case $opt in
'' | -h | --help | help | artwork | clear | next | now | pause | play | prev | previous | rescan | settings | stop | tv)
  (($# < 2)) || error 201
  ;;
esac

# Playback and the queue on the group's leader; sound, hardware and the TV on the speaker itself, and now asks the
# leader only once it knows there is one
case $opt in
artwork | clear | file | next | pause | play | playqueue | prev | previous | queue | repeat | seek | shuffle | sleep | stop)
  LEADER=1
  ;;
favorites | favourites | favs)
  [[ -z $arg ]] || LEADER=1 # Listed from any player: the household's
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
sleep)
  timer "$arg"
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
rescan)
  # Empty: keep the library's album artist setting
  soap MediaServer/ContentDirectory RefreshShareIndex '<AlbumArtistDisplayOption></AlbumArtistDisplayOption>'
  ;;
bass)
  value Bass '' -10 10 "$arg"
  ;;
height)
  value EQ HeightChannelLevel -10 10 "$arg"
  ;;
limit)
  value EQ VolumeScalingFactor 1 100 "$arg"
  ;;
loudness)
  value Loudness "$CH" 0 1 "$arg"
  ;;
mute)
  mute "$arg"
  ;;
treble)
  value Treble '' -10 10 "$arg"
  ;;
trueplay)
  trueplay "$arg"
  ;;
vol | volume)
  volume "$arg"
  ;;
phase)
  value EQ SubPolarity 0 1 "$arg"
  ;;
sub)
  value EQ SubEnable 0 1 "$arg"
  ;;
sublevel)
  value EQ SubGain -15 15 "$arg"
  ;;
lipsync)
  value EQ AudioDelay 0 5 "$arg"
  ;;
night)
  value EQ NightMode 0 1 "$arg"
  ;;
speech)
  speech "$arg"
  ;;
about)
  about "$arg"
  ;;
light)
  onoff LEDState Off On "$arg"
  ;;
settings)
  settings
  ;;
touch)
  # The speaker locks the buttons: touch controls are on while the lock is off
  onoff ButtonLockState On Off "$arg"
  ;;
'' | -h | --help | help)
  usage
  ;;
*)
  error 200
  ;;
esac

exit
