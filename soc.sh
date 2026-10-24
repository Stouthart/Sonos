#!/usr/bin/env -S LC_ALL=C bash
# C locale: Bash starts ~0.2 ms faster without loading a UTF-8 one
set -euo pipefail
IFS=$'\n\t'

# IPv4 only: /dev/tcp takes ~1 s for a .local name, and the speaker rejects other names
HOST=${SONOS_IP-}
# read -N (Bash 4.1+) is 2.5x faster than -d ''; older Bash splits long lists slowly, so reads pages
RD=(-d '') PG=100
((BASH_VERSINFO[0] * 100 + BASH_VERSINFO[1] < 401)) || RD=(-N 16777216) PG=0

# Service paths; Master channel argument
AVT=MediaRenderer/AVTransport CH='<Channel>Master</Channel>' DP=DeviceProperties RC=MediaRenderer/RenderingControl
# C1 controls (U+0080..U+009F) in UTF-8, which [[:cntrl:]] only matches in a UTF-8 locale
C1=$'\xc2[\x80-\x9f]'
# A 2-byte character: its length shows whether Bash counts bytes (C locale) or characters (UTF-8; Android always)
MB=$'\xc3\xa9'

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
  7) msg='Network failure, Sonos offline?' ;;
  200) msg='Missing or invalid option.' ;;
  201) msg='Missing or invalid argument.' ;;
  202) msg='Invalid response from Sonos.' ;;
  203) [[ $3 == 701 ]] && msg="$2 not available for the current source." || msg="Sonos refused $2, UPnP error $3." ;;
  204) msg="Set SONOS_IP to the speaker's IPv4 address." ;;
  205) msg="Favorite $2 is a shortcut; play it from the Sonos app." ;;
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
    v=${BASH_REMATCH[1]//&lt;/<} v=${v//&gt;/>} v=${v//&quot;/\"} v=${v//&apos;/\'} v=${v//&amp;/\&}
    v=${v//[[:cntrl:]]/} v=${v//$C1/}
    [[ -n $1 ]] && printf '%s\n' "$v" || printf '%s=%s\n' "$k" "$v"
  done
}

# Track artwork URL; the player serves relative ones
artwork() {
  local url

  soap "$AVT" GetPositionInfo
  didl url upnp:albumArtURI
  [[ -z $url ]] || printf '%s\n' "${url/#\//http://$HOST:1400/}"
}

# Request a container's children on fd 3 or 4 - <fd> <object id> [start] [count, 0 for all; default PG]
browse() {
  send "$1" MediaServer/ContentDirectory Browse \
    "<ObjectID>$2</ObjectID><BrowseFlag>BrowseDirectChildren</BrowseFlag><Filter>*</Filter><StartingIndex>${3-0}</StartingIndex><RequestedCount>${4-$PG}</RequestedCount><SortCriteria></SortCriteria>"
}

# Set REPLY to its body, joined if chunked: <hex size> CRLF <data> CRLF, up to size 0; sizes count bytes
dechunk() {
  local b c i=0 n

  b=${REPLY#*$'\r\n\r\n'}
  if [[ ${REPLY:0:${#REPLY}-${#b}} != *[Cc]hunked* ]]; then
    REPLY=$b
    return
  fi
  # By offset: cutting each chunk off the front copies the rest every time
  REPLY=''
  while [[ ${b:i:10} =~ ^([[:xdigit:]]{1,8})$'\r\n' ]] && ((n = 16#${BASH_REMATCH[1]})); do
    c=${b:i+${#BASH_REMATCH[0]}:n}
    # Counting characters, that took n of them: printf's precision cuts n bytes, and ${#c} counts them as ${b:…} does
    ((${#MB} == 2)) || printf -v c '%.*s' "$n" "$c"
    REPLY+=$c
    ((i += ${#BASH_REMATCH[0]} + ${#c} + 2))
  done
  [[ ${b:i:3} == 0$'\r\n' ]] || error 202
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
  v=${v//[[:cntrl:]]/}
  printf -v "$1" %s "${v//$C1/}"
}

# List favorites, or play favorite n; containers go through the queue - [n]
favorites() {
  local md='' uri

  if [[ -z $1 ]]; then
    browse 3 FV:2
    list FV:2
    return
  fi

  [[ $1 =~ ^[1-9][0-9]{0,4}$ ]] || error 201
  browse 3 FV:2 $(($1 - 1)) 1
  recv 3 Browse
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
  local LC_ALL=C b c i k n uri=${1#//}

  [[ $1 =~ ^//[^/]+/[^/]+/.*[^/]$ ]] || error 201
  # Percent-encode bytes outside the unreserved set, if any; spelled out, as Android's [[:alnum:]] takes é
  if [[ $uri == *[^0-9A-Za-z/._~+-]* ]]; then
    uri=''
    for ((i = 2; i < ${#1}; i++)); do
      c=${1:i:1}
      case $c in
      [0-9A-Za-z/._~+-]) uri+=$c ;;
      *)
        # Bash 3.2 sign-extends bytes above 0x7F
        printf -v n %d "'$c"
        printf -v b %.1s "$c"
        if [[ $b == "$c" ]]; then
          printf -v c %%%02X $((n & 255))
        else
          # A character, as Android's Bash takes one in every locale: its UTF-8 bytes from the code point
          ((k = 1 + (n > 2047) + (n > 65535)))
          printf -v c %%%02X $((256 - (128 >> k) | n >> 6 * k))
          while ((k--)); do
            printf -v c %s%%%02X "$c" $((128 | n >> 6 * k & 63))
          done
        fi
        uri+=$c
        ;;
      esac
    done
  fi

  soap "$AVT" SetAVTransportURI "<CurrentURI>x-file-cifs://$uri</CurrentURI><CurrentURIMetaData></CurrentURIMetaData>"
  soap "$AVT" Play '<Speed>1</Speed>'
}

# GET a page into REPLY, its chunks joined - <path>
get() {
  local rc=0

  [[ -n $HOST ]] || error 204
  { exec 3<>"/dev/tcp/$HOST/1400"; } 2>/dev/null || error 7
  printf 'GET /%s HTTP/1.1\r\nHost: %s:1400\r\nConnection: close\r\n\r\n' "$1" "$HOST" >&3
  IFS= read -r "${RD[@]}" REPLY <&3 || rc=$?
  exec 3<&-

  # read succeeds only at its cap (-N) or a NUL byte (-d ''), both cutting the page short
  ((rc)) && [[ $REPLY == 'HTTP/1.1 200 '* ]] || error 202
  dechunk
}

# Number within max; sets BASH_REMATCH - <arg> <max>
isnum() {
  [[ $1 =~ ^([+-]?)(0|[1-9][0-9]{0,3})$ && ${BASH_REMATCH[2]} -le $2 ]]
}

# Print a container's items as "n) artist / title [album]", "> " marking item cur if its res is uri;
# replies are capped, so read on to TotalMatches; page 1 is already sent on fd 3 - <object id> [cur] [uri]
list() {
  # C: faster splitting; in a variable, as Bash 3.2 takes a quoted / in a pattern for the separator
  local LC_ALL=C e='&lt;/item&gt;' i=0 it items j n t

  while :; do
    recv 3 Browse
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
    browse 3 "$1" "$i"
  done
}

# Print "artist / title [album]", then position, duration, quality (TV: input format) and source
now() {
  local bits=0 c dur fmt='' loss='' lq=(lossy lossless) pos q='' rate=0 src tvf

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

  # Topology alongside: switching to the queue needs this player's id
  send 3 "$AVT" GetMediaInfo
  send 4 ZoneGroupTopology GetZoneGroupState
  recv 3 GetMediaInfo
  tag CurrentURI
  if [[ ${BASH_REMATCH[1]} != x-rincon-queue:* ]]; then
    recv 4 GetZoneGroupState
    rincon id
    soap "$AVT" SetAVTransportURI \
      "<CurrentURI>x-rincon-queue:$id#0</CurrentURI><CurrentURIMetaData></CurrentURIMetaData>"
  else
    exec 4<&-
  fi
  soap "$AVT" Seek "<Unit>TRACK_NR</Unit><Target>$1</Target>"
  soap "$AVT" Play '<Speed>1</Speed>'
}

# List the queue, marking the current track, or play from track n - [n]
queue() {
  local cur uri

  if [[ -n $1 ]]; then
    [[ $1 =~ ^[1-9][0-9]{0,4}$ ]] || error 201
    playqueue "$1"
    return
  fi

  browse 3 Q:0
  send 4 "$AVT" GetPositionInfo
  recv 4 GetPositionInfo
  tag Track '[0-9]{1,5}'
  cur=${BASH_REMATCH[1]}
  tag TrackURI
  uri=${BASH_REMATCH[1]}
  list Q:0 "$cur" "$uri"
}

# Read an fd to EOF into REPLY; exits on fault or foreign reply - <fd> <action>
recv() {
  local rc=0

  IFS= read -r "${RD[@]}" REPLY <&"$1" || rc=$?
  case $1 in
  3) exec 3<&- ;;
  4) exec 4<&- ;;
  *) eval "exec $1<&-" ;;
  esac

  # As in get; only Browse replies come chunked, but checking costs just ~6 µs
  ((rc)) || error 202
  if [[ $REPLY == 'HTTP/1.1 200 '* ]]; then
    [[ ${REPLY:0:256} != *[Cc]hunked* ]] || dechunk
    [[ $REPLY == *[\<:]"$2"Response[[:space:]/\>]* ]] && return
  fi
  [[ $REPLY =~ '<errorCode>'([0-9]{1,4})'</errorCode>' ]] && error 203 "$2" "${BASH_REMATCH[1]}"
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

# This player's id, found by HOST in REPLY's topology - <var>
rincon() {
  [[ $REPLY =~ 'UUID=&quot;'(RINCON_[[:alnum:]]{1,32})'&quot; Location=&quot;http://'"$HOST"':1400/' ]] || error 202
  printf -v "$1" %s "${BASH_REMATCH[1]}"
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

# Connect an fd (3 or 4; settings also 5 to 9) and send a UPnP action - <fd> <service path> <action> [arguments]
# No connect timeout: an unreachable speaker blocks until the OS gives up (~75 s)
send() {
  local body n p urn=urn:schemas-upnp-org:service:${2##*/}:1

  # Here, so option and argument errors come first
  [[ -n $HOST ]] || error 204
  body="<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body><u:$3 xmlns:u=\"$urn\"><InstanceID>0</InstanceID>${4-}</u:$3></s:Body></s:Envelope>"
  n=${#body}
  # Content-Length counts bytes; counting characters, pad to a width printf counts in bytes (4 per character at most)
  ((${#MB} == 2)) || {
    printf -v p '%-*s' $((n * 4)) "$body"
    ((n = n * 5 - ${#p}))
  }

  case $1 in
  3) { exec 3<>"/dev/tcp/$HOST/1400"; } 2>/dev/null ;;
  4) { exec 4<>"/dev/tcp/$HOST/1400"; } 2>/dev/null ;;
  *) { eval "exec $1<>\"/dev/tcp/\$HOST/1400\""; } 2>/dev/null ;;
  esac || error 7
  printf 'POST /%s/Control HTTP/1.1\r\nHost: %s:1400\r\nConnection: close\r\nContent-Type: text/xml; charset="utf-8"\r\nSOAPACTION: "%s#%s"\r\nContent-Length: %d\r\n\r\n%s' \
    "$2" "$HOST" "$urn" "$3" "$n" "$body" >&"$1"
}

# Print the Sound (vol and mute aside), Home theater, Sub audio and Hardware settings as option=value
settings() {
  local i j n=15 out='' p v=()
  # Option, then the request for its value; speech takes two, its switch (no option) and level
  local r=(
    bass "$RC" GetBass ''
    limit "$RC" GetEQ '<EQType>VolumeScalingFactor</EQType>'
    loudness "$RC" GetLoudness "$CH"
    treble "$RC" GetTreble ''
    trueplay "$RC" GetRoomCalibrationStatus ''
    height "$RC" GetEQ '<EQType>HeightChannelLevel</EQType>'
    lipsync "$RC" GetEQ '<EQType>AudioDelay</EQType>'
    night "$RC" GetEQ '<EQType>NightMode</EQType>'
    '' "$RC" GetEQ '<EQType>SpeechEnhanceEnabled</EQType>'
    speech "$RC" GetEQ '<EQType>DialogLevel</EQType>'
    level "$RC" GetEQ '<EQType>SubGain</EQType>'
    phase "$RC" GetEQ '<EQType>SubPolarity</EQType>'
    sub "$RC" GetEQ '<EQType>SubEnable</EQType>'
    led "$DP" GetLEDState ''
    touch "$DP" GetButtonLockState ''
  )

  # Seven at a time, on fds 3 to 9 (Bash keeps its own above 9): ~95 ms, against ~220 ms one at a time
  for ((j = 0; j < n + 7; j++)); do
    if ((j >= 7)); then
      i=$(((j - 7) * 4))
      recv $((3 + j % 7)) "${r[i + 2]}"
      # The reply's first value; RoomCalibrationEnabled comes before Available
      [[ ${r[i + 1]} == "$DP" ]] && p='On|Off' || p='-?[0-9]{1,3}'
      [[ $REPLY =~ 'Response'[^\>]*'><'[[:alpha:]]+'>'($p)'</' ]] || error 202
      v+=("${BASH_REMATCH[1]}")
    fi
    ((j >= n)) || send $((3 + j % 7)) "${r[j * 4 + 1]}" "${r[j * 4 + 2]}" "${r[j * 4 + 3]}"
  done

  # Speech is 0 while off; LED On is 1; the touch controls are on (1) while the buttons aren't locked
  ((v[8])) || v[9]=0
  [[ ${v[13]} == On ]] && v[13]=1 || v[13]=0
  [[ ${v[14]} == Off ]] && v[14]=1 || v[14]=0
  for ((i = 0; i < ${#r[@]}; i += 4)); do
    [[ -z ${r[i]} ]] || out+=${r[i]}=${v[i / 4]}$'\n'
  done
  printf %s "$out"
}

# Send UPnP action and read its reply - <service path> <action> [arguments]
soap() {
  send 3 "$@"
  recv 3 "$2"
}

# Get or set speech enhancement (0 off, 1..4 level), both values at once - [arg]
speech() {
  local dl='<EQType>DialogLevel</EQType>' se='<EQType>SpeechEnhanceEnabled</EQType>'

  if [[ -z $1 ]]; then
    send 3 "$RC" GetEQ "$se"
    send 4 "$RC" GetEQ "$dl"
    recv 3 GetEQ
    tag CurrentValue '[01]'
    if ((BASH_REMATCH[1])); then
      recv 4 GetEQ
      tag CurrentValue '[0-4]'
      printf '%s\n' "${BASH_REMATCH[1]}"
    else
      # Off: no need to wait for the level
      exec 4<&-
      printf '0\n'
    fi
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

  soap ZoneGroupTopology GetZoneGroupState
  rincon id
  soap "$AVT" SetAVTransportURI \
    "<CurrentURI>x-sonos-htastream:$id:spdif</CurrentURI><CurrentURIMetaData></CurrentURIMetaData>"
}

usage() {
  local nm=${0##*/}

  printf '%s\n' "$nm 3.1 - Control Sonos over UPnP
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
  bass -10..10 | limit 1..100 | loudness 0..1 | mute 0..1
  treble -10..10 | trueplay 0..1 | vol 0..100

Home theater:
  height -10..10 | lipsync 0..5 | night 0..1 | speech 0..4

Sub audio:
  level -15..15 | phase 0..1 | sub 0..1

Hardware:
  about | led 0..1 | settings | touch 0..1

Omit the argument to read the current value.
Volume and seek accept a relative value (e.g. vol +5, seek -30).
Seek also accepts a min:sec position or offset (e.g. 3:39, -1:30).
About accepts a key (e.g. about modelName).
Requires SONOS_IP: the speaker's IPv4 address."
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

# Get, set or adjust (±) volume - [arg]
volume() {
  if isnum "$1" 100 && [[ -n ${BASH_REMATCH[1]} ]]; then
    # The speaker clamps to 0..100
    soap "$RC" SetRelativeVolume "$CH<Adjustment>${BASH_REMATCH[0]#+}</Adjustment>"
  else
    value Volume "$CH" 0 100 "$1"
  fi
}

(($# < 3)) || error 201
opt=${1-} arg=${2-}

case $opt in
'' | -h | --help | help | artwork | clear | next | now | pause | play | prev | previous | rescan | settings | stop | tv)
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
lipsync)
  value EQ AudioDelay 0 5 "$arg"
  ;;
loudness)
  value Loudness "$CH" 0 1 "$arg"
  ;;
mute)
  value Mute "$CH" 0 1 "$arg"
  ;;
night)
  value EQ NightMode 0 1 "$arg"
  ;;
speech)
  speech "$arg"
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
level)
  value EQ SubGain -15 15 "$arg"
  ;;
phase)
  value EQ SubPolarity 0 1 "$arg"
  ;;
sub)
  value EQ SubEnable 0 1 "$arg"
  ;;
about)
  about "$arg"
  ;;
led)
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
