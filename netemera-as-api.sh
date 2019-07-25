#!/bin/bash
set -Eeuo pipefail
export SHELLOPTS

# Environmnt variables
: ${CLIENT_ID:=}
: ${CLIENT_SECRET:=}
: ${CONFIGFILE:=$HOME/.config/netemera-as-api.conf}
: ${LOGLVL:=1}
: ${DEBUG:=false}
: ${TOKENFILE:="/tmp/.$(basename $0)-$(whoami).token"}
VERSION=v0.1.2
if $DEBUG; then set -x; fi;

# Functions ###################################################

usage() {
	cat <<EOF
Usage:
	netemera-as-api.sh [OPTIONS] <mode> <arguments...>

Connects and performs operations no netemera-as-api.

Modes:

  uplink <deveui> [since] [until]
    Prints uplink from specified dev eui within specified time.
    You may need to specify '--' to separate arguments from since and until strings
    If until is empty, by default it will follow the output

  downlink <deveui> <port> <payload> [<confirmed default:false>]
    Sends a single downlink to specified device
    Port is an decimal integer in base 10
    Payload is a string of bytes in hex
    Confirmed should be the string "false" or "true"

  get_downlink <deveui> [since] [until]
    Query downlink requested from network server to send to device.
    Arguments are similar to uplink mode.

  get_bothlinks <deveui> [since] [until]
    Query both downlink and uplinks from a device.
    Arguments are similar to uplink mode.

  downlink_clear <deveui>
    Clear downlinks queried on network server to device.

  refresh_token
    Refresh token stored in TOKENFILE

Options:
  -v                     Increase loglevel
  -s                     Decrese loglevel
  -c --config=STR        Specify config file to load
  -H --format-filtersse  Only filter SSE statements (only valid with *link mode)
  -B --format-space      Output bash-parsable space separated output (only valid with *link mode)
  -h --human-readable    Output human readable format (only valid with *link mode)
  -N --disable-sorting   Disable sorting the output of get_bothlinks. Only valid for this mode.
     --help              Print this help and exit

Environment variables:
	CONFIGFILE=${CONFIGFILE}
	CLIENT_ID=<private>
	CLIENT_SECRET=<private>
	LOGLVL=${LOGLVL}
	TOKENFILE=${TOKENFILE}

Examples:
	netemera-as-api.sh -- uplink ffffffffff00001b
	netemera-as-api.sh -- uplink ffffffffff000014 -7day
	netemera-as-api.sh -- uplink ffffffffff000014 -7day -1day
	netemera-as-api.sh -- downlink ffffffffff00001b 1 0101
	netemera-as-api.sh -- refresh_token
	netemera-as-api.sh -sB -- get_bothlinks ffffffffff00001b -1day now
	netemera-as-api.sh -sh -- get_bothlinks ffffffffff00001b -1hour

netemera-as-api.sh ${VERSION}
Copyright (C) 2019 Netemera under Apache License. Written by Kamil Cukrowski.
EOF
}

usage_error() {
	{
		usage
		echo 
		error "$@"
	} >&2
	exit 1
}

# logging utilities ##################################################

error() {
	echo "ERR " "$@"
}

debug() {
	if ! ${DEBUG:-false}; then return; fi;
	echo "DBG " "$@"
}

warn() {
	echo "WARN" "$@" >&2
}

fatal() {
	echo "FATAL" "$@" >&2
	exit 1
}

log() {
	if [ "$1" -le "${LOGLVL}" ]; then
		local lvl
		lvl="$1"
		shift
		echo "LOG$lvl" "$@" >&2
	fi
}

# utilities #########################################################

assert_true_or_false() {
	case "$1" in
	true|false) ;;
	*) fatal "Value of $2 is not equal to 'true' or 'false'"; ;;
	esac
}

# Print trap trace on error.
# Meant to be registered to trap
trap_err() {
	{
		echo
		echo "ERROR $BASHPID backtrace:"
		for (( i = 0; 1; ++i)); do 
			caller "$i" || break
			sed -n "$(caller "$i" | cut -d' ' -f1)p" "$(which "$0")" 
		done
	} >&2
}

tolower() {
	printf "%s" "$@" | 
	tr '[:upper:]' '[:lower:]'
}

ishexstring() {
	local tmp
	tmp="$(sed 's/[[:xdigit:]]*//' <<<"$1")"
	return "${#tmp}"
}

runcurl() {
	log 5 "$( IFS=' '; printf "curl -g %q\n" "$*"; )";
	curl -g "$@";
}

date_iso_8601() {
	# 2019-04-02T00:00:00.000Z
	date -u --date="$1" +%Y-%m-%dT%H:%M:%S.%3NZ
}

# functions ##################################################################################

# Get's the access_token from the server and saves it into first vairable
_gettoken() {
	declare -g TOKENFILE
	local outvar
	outvar="$1"

	if [ ! -e "$TOKENFILE" ]; then
		: > "$TOKENFILE"
	fi

	local access_token expires_in aquired_on expires_on refresh_token
	unset access_token expires_in aquired_on expires_on refresh_token

	if ! source "$TOKENFILE"; then
		fatal "Parsing $TOKENFILE"
	fi

	local now;
	now=$(date +%s);

	local valid_tokenfile
	valid_tokenfile=true
	for i in access_token expires_in aquired_on expires_on refresh_token; do
		if [ -z ${!i+x} ]; then
			valid_tokenfile=false
			break
		fi
	done

	if "$valid_tokenfile"; then
		log 3 "Valid tokenfile read and found!"

		local now
		now=$(date +%s)
		if [ "$now" -lt "$expires_on" ]; then
			log 1 "Token read from cache file."
			log 3 "access_token=$access_token expires_on=$expires_on"
			declare -g "$outvar"="$access_token"
			return
		fi

		log 2 "Token from cache file expired."
		log 3 "Token $expires_on $now $aquired_on"
		: > "$TOKENFILE"
	fi

	local aquired_on
	aquired_on=$(date +%s)

	log 2 "Requesting token..."
	local resp
	resp=$(
		runcurl \
			-sS \
  			--request POST \
  			--url 'https://authorization.netemera.com/api/v2/oauth2/token' \
			--user "${CLIENT_ID}"':'"${CLIENT_SECRET}" \
  			--data 'grant_type=client_credentials&audience=https://network.netemera.com/api/v4'
	)

	local resp2
	local access_token token_type expires_in refresh_token empty
	if 
		! resp2=$(<<<"$resp" jq -r '.access_token, .token_type, .expires_in, .refresh_token') ||
		! IFS=$'\n' read -d '' -r access_token token_type expires_in refresh_token empty < <(printf "%s\0" "$resp2") ||
		[ -z "$access_token" -o -z "$token_type" -o -z "$expires_in" -o -z "$refresh_token" -o -n "$empty" ]
	then
		fatal "Could not parse token"$'\n'"$resp"
	fi

	local expires_on
	expires_on=$(( aquired_on + $expires_in ))
	declare -p access_token expires_in aquired_on expires_on refresh_token > "$TOKENFILE"

	log 1 "Requesting token success. Token expires in $expires_in seconds."
	declare -g "$outvar"="$access_token"
}

gettoken() {
	declare -g TOKENFILE
	local lockfd
	exec {lockfd}>"$TOKENFILE.lock"
	if ! timeout 3 flock "$lockfd"; then
		echo "Waiting for lock on $(readlink -f "$0") file..."
		flock "$lockfd"
	fi
	_gettoken "$@"
	flock -u "$lockfd"
}

ask() {
	gettoken token
	log 1 "Connect"

	local url 
	url="$1"
	shift
	runcurl \
  		-sSN \
		-H "Authorization: Bearer ${token}" \
  		--url "https://network.netemera.com/api/v4/$url" \
  		"$@"
  	echo
}

args_parse_timeregion() {
	local args tmp1 tmp2

	if [ "$#" -eq 1 ]; then
		args="filter[follow]=true"
	elif [ "$#" -eq 2 ]; then
		if ! tmp1=$(date_iso_8601 "$2"); then
			error "The argument $2 is an invalid date"
		fi
		args="filter[since]=$tmp1&filter[follow]=true"
	elif [ "$#" -eq 3 ]; then
		if ! tmp1=$(date_iso_8601 "$2"); then
			error "The argument $2 is an invalid date"
		fi
		if ! tmp2=$(date_iso_8601 "$3"); then
			error "The argument $3 is an invalid date"
		fi
		args="filter[since]=$tmp1&filter[until]=$tmp2"
	else
		usage_error "Too many arguments"
	fi

	printf "%s\n" "$args"
}

# If the stdin are SSE lines, we filter only the data: lines
func_format_filtersse() {
	grep --line-buffered --extended-regexp '^data:.+' | stdbuf -oL cut -d: -f2-
}

# modes ######################################################################################

mode_uplink() {
	declare -g output_format

	if [ "$#" -lt 1 -o "$#" -gt 3 ]; then
		usage_error "uplink: wrong number of arguments"
	fi

	local eui
	eui=$(tolower "$1")

	local args
	args=$(args_parse_timeregion "${@:1:3}")

	ask "uplink-packets/end-devices/$eui?$args" -H 'Accept: text/event-stream' -H 'Cache-Control: no-cache' -m 0 --no-buffer |
	case "$output_format" in
	format_space|format_human_readable|format_filtersse)
		func_format_filtersse |
		case "$output_format" in
		format_space|format_human_readable)
			# printf "recvTime devEui fPort fCntUp ack adr dataRate ulFreq frmPayload\n"
			jq --unbuffered -c -r '.recvTime, .devEui, .fPort, .fCntUp, .ack, .adr, .dataRate, .ulFreq, .frmPayload' |
			sed -u -e 's/^false$/0/' -e 's/^true$/1/g' |
			case "$output_format" in
			format_space)
				xargs -n9 printf "%-24s %16s %3s %5s ack:%1s adr:%1s dr:%1s f:%03.1f %s\n"
				;;
			format_human_readable)
				xargs -n9 printf "%-24s deveui:%16s port:%-3s upcnt:%-5s ack:%1s adr:%1s dr:%1s freq:%03.1f payload:%s\n"
				;;
			*) fatal "" ;;
			esac
			;;
		format_filtersse)
			jq -C --unbuffered -c .
			;;
		*) fatal ""; ;;
		esac
		;;
	"format_none") cat; ;;
	*) fatal ""; ;;
	esac
}

mode_get_downlink() {
	declare -g output_format

	if [ "$#" -lt 1 -o "$#" -gt 3 ]; then
		usage_error "get_downlink: wrong number of arguments"
	fi

	local eui
	eui=$(tolower "$1")

	local args
	args=$(args_parse_timeregion "${@:1:3}")

	ask downlink-packets/end-devices/"$eui?$args" -H 'Accept: text/event-stream' -H 'Cache-Control: no-cache' |
	case "$output_format" in
	format_filtersse|format_space|format_human_readable)
		# from the raw curl input stream filter the data: lines
		func_format_filtersse |
		case "$output_format" in
		format_space|format_human_readable)
			# extract only the fields we are interested in
			jq --unbuffered -c -r '.recvTime, .devEui, .fPort, .confirmed, .frmPayload' |
			case "$output_format" in
			format_space)
				xargs -n5 printf "%-24s %16s %3s %5s %s\n"
				;;
			format_human_readable)
				xargs -n5 printf "%-24s deveui:%16s port:%-3s confirmed:%-5s payload:%s\n"
				;;
			*) fatal ""; ;;
			esac
			;;
		format_filtersse)
			jq -C --unbuffered -c .
			;;
		*) fatal ""; ;;
		esac
		;;
	"format_none") cat; ;;
	*) fatal ""; ;;
	esac
}

mode_downlink() {
	if [ "$#" -lt 1 -o "$#" -gt 4 ]; then
		usage_error "downlink: wrong number of arguments"
	fi

	local eui
	eui=$(tolower "$1")

	if [ "$#" -lt 3 ]; then usage_error "mode $mode needs more arguments"; fi;
	if (( ${#3} % 2 != 0 )); then usage_error "payload length is not dividable by 2"; fi;
	if ! ishexstring "$3"; then usage_error "payload is not a hex string"; fi;
	if (( $# == 4 )); then assert_true_or_false "$4" "confirmed"; fi;
	req=$(printf '{"data":{"type":"downlink-packet","attributes":{"fPort":%d,"confirmed":%s,"frmPayload":"%s"}}}' "$2" "${4:-false}" "$3")
	log 1 "> Request: $req" >&2
	ask downlink-packets/end-devices/"$eui" -H "Content-Type: application/json" --data-raw "$req"
}

mode_get_bothlinks() {
	declare -g get_bothlinks_disable_sorting

	if [ "$#" -lt 1 -o "$#" -gt 3 ]; then
		usage_error "get_bothlinks: wrong number of arguments"
	fi

	set -m

	# global, so that trap_exit can touch it
	declare -a -g childs
	childs=()

	declare -a -g fifo
	fifo=$(mktemp -u)
	mkfifo "$fifo"

	# redirect a file descriptor, so system can buffer the output
	# without it curl may exit prematurely
	exec 10<>"$fifo"

	killtree() { 
    	for p in $(pstree -p "$1" | grep -o "([[:digit:]]*)" |grep -o "[[:digit:]]*" | tac | grep -v "$1"); do
        	kill "$p" || :
    	done
	}

	trap_exit() {
		set +E
		set +e
		set +u
		set +o pipefail
		declare -g childs fifo

		echo "Exiting..." >&2

		# I don't care who you are and what you do.
		# I have a prticular set of skill.
		# I will find you. And I will kill you.
		killtree "$BASHPID" || :
		killtree "$$" || :

		# different ways of killing all the childs
		[ "${#childs[@]}" -ne 0 ] && kill -s 9 "${childs[@]}" || :
		tmp=$(ps -s $BASHPID -o pid=) || :
		[ -n "$tmp" ] && kill -s 9 $tmp || :
		pkill -P $BASHPID -s 9 || :

		sleep 0.1
		kill $(jobs -p) || :
		wait "${childs[@]}" "$tmp" || :
		wait || :

		exec 10<&- || :
		rm -f -r "$fifo" || :
	}

	trap 'trap_exit EXIT' EXIT

	# start uplink in background. Append the lines with something
	mode_uplink "$@" | sed -u 's/^/  UP /' >&10 &
	childs+=("$!")
	sleep 0.1
	if ! kill -s 0 "${childs[-1]}" 2>/dev/null; then
		fatal "Problem running uplink mode!"
	fi

	# start downlink in background. Append the lines with something
	mode_get_downlink "$@" | sed -u 's/^/DOWN /' >&10 &
	childs+=("$!")
	sleep 0.1
	if ! kill -s 0 "${childs[-1]}" 2>/dev/null; then
		fatal "Problem running downlink mode!"
	fi

	if [ "$get_bothlinks_disable_sorting" != "true" ]; then
		# ok, now sort the lines that were queried in the history using datestamps
		{
			# give them some time to get up
			timeout 1 cat <&10 || :
			# query the lines until no lines are available within timeout
			while IFS= read -t 0.1 line; do
				printf "%s\n" "$line"
			done <&10
		} |
		# extract the time and put it as the first field in line
		sed -E '
			# hold the line
			h
			# extract only the time part
			s/.... ([^ ]*) .*/\1/
			# remove any nonnumbers
			s/[^0-9]*//g
			# sometimes lines are missing the subseconds field, ie. 
			# look like this:              2019-07-25T10:11:55Z
			# inseat of looking like this: 2019-07-25T10:11:55.665Z
			# this will screw sorting, so add zeros on the end
			s/^[0-9]{14}$/&000/
			# now all the lines have to have exactly 17 [0-9] characters!
			/^[0-9]{17}$/!{
				G
				s/.*/-1 Sed internal failure! The line is: &/
				q 1
			}
			# append grab the hold space
			G
			# replace the newline with a space
			s/\n/ /
		' |
		# sort via first field only - save speed
		# disable last sort - save speed
		sort -t' ' -s -n -k1.1 |
		# lastly remove the sorting field
		cut -d' ' -f2-
	fi

	# query the events from the fifo
	cat <&10
}

mode_refresh_token() {
	if [ "$#" -ne 0 ]; then
		usage_error "refresh_token takes no arguments"
	fi

	: > "$TOKENFILE"

	gettoken _
}

# Main ####################################################

trap "trap_err $?" ERR

args=$(getopt \
	-n netemera-as-api.sh  \
	-o dvschHB \
	-l help,config:,human-readable,filter-sse \
	-- "$@")
eval set -- "$args"
output_format="format_none"
get_bothlinks_disable_sorting=false
while (($#)); do
	case "$1" in
	-d) LOGLVL=100; DEBUG=true; ;;
	-v) ((LOGLVL++))||:; ;;
	-s) ((LOGLVL--))||:; ;;
	--help) usage; exit; ;;
	-c|--config) CONFIGFILE=$2; shift; ;;
	-H|--format-filtersse) output_format="format_filtersse"; ;;
	-B|--format-space) output_format="format_space"; ;;
	-h|--human-redable) output_format="format_human_readable"; ;;
	-N|--disable-sorting) get_bothlinks_disable_sorting=true; ;;
	*) shift; break;
	esac
	shift
done

if [ $# -lt 1 ]; then
	usage; 
	exit 1;
fi;
mode=$1; 
shift

# load configuration file
log 3 "Loading $CONFIGFILE"
. $CONFIGFILE

for i in CONFIGFILE CLIENT_ID CLIENT_SECRET CONFIGFILE TOKENFILE; do
	debug "Variable $i=${!i}"
	if [ -z "${!i}" ]; then
		fatal "Variable $i is empty"
	fi
done

case "$output_format" in 
"format_none"|"format_filtersse"|"format_space"|"format_human_readable") ;;
*) fatal "$output_format is invalid $output_format"; ;;
esac

case "$mode" in
uplink|downlink|get_downlink|get_bothlinks|refresh_token)
	mode_"$mode" "$@"
	;;
downlink_clear)
	fatal "NOT IMPLEMENTED YET"
	;;
*)
	usage_error "Unknown mode"
	;;
esac
