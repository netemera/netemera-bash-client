#!/bin/bash
set -Eeuo pipefail
export SHELLOPTS

# Environmnt variables
: ${CLIENT_ID:=}
: ${CLIENT_SECRET:=}
: ${CONFIGFILE:=${HOME:-~}/.config/netemera-as-api.conf}
: ${LOGLVL:=1}
: ${DEBUG:=false}
: ${TOKENFILE:=/tmp/.$(basename $0).token}
VERSION=v0.1.1
if $DEBUG; then set -x; fi;

# Functions ###################################################

usage() {
	cat <<EOF
Usage:
	netemera-as-api.sh [OPTIONS] <mode> <arguments...>

Connects and performs operations no netemera-as-api.

Modes:
	uplink <deveui> [since] [until]
	downlink <deveui> <port> <payload> [<confirmed default:false>]
	downlink_clear <deveui>
	refresh_token

Options:
	-v   increase loglevel
	-s   decrese loglevel
	-c   specify config file to load
	-h   print this help and exit
	-H   Filter SSE statements (only valid with uplink mode)
	-B   Output bash-parsable space separated output (only valid with uplnk mode)

Environment variables:
	CONFIGFILE=${CONFIGFILE}
	CLIENT_ID=<private>
	CLIENT_SECRET=<private>
	LOGLVL=${LOGLVL}
	TOKENFILE=${TOKENFILE}

Examples:
	netemera-as-api.sh uplink ffffffffff00001b
	netemera-as-api.sh uplink ffffffffff000014 -7day
	netemera-as-api.sh uplink ffffffffff000014 -7day -1day
	netemera-as-api.sh downlink ffffffffff00001b 1 0101
	netemera-as-api.sh refresh_token

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

curl() {
	log 5 "$(/bin/printf "%q " curl "$@"; echo)";
	command curl "$@";
}

date_iso_8601() {
	# 2019-04-02T00:00:00.000Z
	date -u --date="$1" +%Y-%m-%dT%H:%M:%SZ
}

# functions ##################################################################################

# Get's the access_token from the server and saves it into first vairable
gettoken() {
	declare -g TOKENFILE
	local outvar
	outvar="$1"

	if [ -e "$TOKENFILE" ]; then

		if ! source "$TOKENFILE"; then
			fatal "Parsing $TOKENFILE"
		fi

		local now;
		now=$(date +%s);

		if [ "$now" -lt "$expires_on" ]; then
			log 1 "Token read from cache file."
			log 3 "access_token=$access_token expires_on=$expires_on"
			declare -g "$outvar"="$access_token"
			return
		fi

		log 2 "Token from cache file expired."
		log 3 "Token $expires_on $now $aquired_on"
		rm "$TOKENFILE"
	fi

	local aquired_on
	aquired_on=$(date +%s)

	log 2 "Requesting token..."
	local resp
	resp=$(
		curl \
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

ask() {
	gettoken token
	log 1 "Connect"

	local url 
	url="$1"
	shift
	curl \
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

# modes ######################################################################################

mode_uplink() {
	declare -g FILTER_SSE SPACE_SEPARATED_OUTPUT

	if [ "$#" -lt 1 -o "$#" -gt 3 ]; then
		usage_error "uplink: wrong number of arguments"
	fi

	local eui
	eui=$(tolower "$1")

	local args
	args=$(args_parse_timeregion "${@:1:3}")

	ask "uplink-packets/end-devices/$eui?$args" -H 'Accept: text/event-stream' -H 'Cache-Control: no-cache' -m 0 --no-buffer |
	if "$FILTER_SSE"; then
		grep --line-buffered --extended-regexp '^data:.+' | stdbuf -oL cut -d: -f2- |
		if "$SPACE_SEPARATED_OUTPUT"; then
			# printf "recvTime devEui fPort fCntUp ack adr dataRate ulFreq frmPayload\n"
			jq --unbuffered -c -r '.recvTime, .devEui, .fPort, .fCntUp, .ack, .adr, .dataRate, .ulFreq, .frmPayload' |
			sed -u -e 's/^false$/0/' -e 's/^true$/1/g' |
			xargs -n9 printf "%24s %16s %3s %5s ack:%1s adr:%1s dr:%1s f:%03.1f %s\n"
		else
			jq -C --unbuffered -c .
		fi
	else
		cat
	fi
}

mode_get_downlink() {
	declare -g FILTER_SSE SPACE_SEPARATED_OUTPUT

	if [ "$#" -lt 1 -o "$#" -gt 3 ]; then
		usage_error "get_downlink: wrong number of arguments"
	fi

	local eui
	eui=$(tolower "$1")

	local args
	args=$(args_parse_timeregion "${@:1:3}")

	ask downlink-packets/end-devices/"$eui?$args" -H 'Accept: text/event-stream' -H 'Cache-Control: no-cache' |
	if "$FILTER_SSE"; then
		grep --line-buffered --extended-regexp '^data:.+' | stdbuf -oL cut -d: -f2- |
		if "$SPACE_SEPARATED_OUTPUT"; then
			# printf "recvTime devEui fPort confirmed frmPayload\n"
			jq --unbuffered -c -r '.recvTime, .devEui, .fPort, .confirmed, .frmPayload' |
			xargs -n5 printf "%24s %16s %3s %5s %s\n"
		else
			jq -C --unbuffered -c .
		fi
	else
		cat
	fi
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
	if [ "$#" -lt 1 -o "$#" -gt 3 ]; then
		usage_error "get_downlink: wrong number of arguments"
	fi

	local childs
	childs=()

	trapf() {
		if [ ${#childs[@]} -ne 0 ]; then
			kill -s "$1" "${childs[@]}"
		fi
	}

	trap 'trapf EXIT' EXIT

	mode_uplink "$@" | sed -u 's/^/  up /' &
	childs+=("$!")

	mode_get_downlink "$@" | sed -u 's/^/down /' &
	childs+=("$!")

	wait "${childs[@]}"
}

mode_refresh_token() {
	if [ "$#" -ne 0 ]; then
		usage_error "refresh_token takes no arguments"
	fi

	if [ -e "$TOKENFILE" ]; then
		rm "$TOKENFILE"
	fi

	gettoken _
}

# Main ####################################################

trap "trap_err $?" ERR

FILTER_SSE=false
SPACE_SEPARATED_OUTPUT=false

while getopts "dvsc:hHB" opt; do
	case "$opt" in
	d) LOGLVL=100; DEBUG=true; ;;
	v) ((LOGLVL++))||:; ;;
	s) ((LOGLVL--))||:; ;;
	h) usage; exit; ;;
	c) CONFIGFILE=$OPTARG; ;;
	H) FILTER_SSE=true; ;;
	B) FILTER_SSE=true; SPACE_SEPARATED_OUTPUT=true; ;;
	*) usage_error "Argument '$opt' is invalid"; exit 1; ;;
	esac
done
shift $((OPTIND-1))

if [ $# -lt 1 ]; then
	usage; 
	exit;
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

case "$mode" in
uplink)
	mode_uplink "$@"
	;;
downlink)
	mode_downlink "$@"
	;;
get_downlink)
	mode_get_downlink "$@"
	;;
get_bothlinks)
	mode_get_bothlinks "$@"
	;;
downlink_clear)
	echo "NOT IMPLEMENTED"
	exit 1
	;;
refresh_token)
	mode_refresh_token "$@"
	;;
*)
	usage_error "Unknown mode"
	;;
esac
