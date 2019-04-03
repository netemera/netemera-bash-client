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
	-S   filter SSE stream
	-N   Output nice formatted separated output

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

assert_true_or_false() {
	case "$1" in
	true|false) ;;
	*) fatal "Value of $2 is not equal to 'true' or 'false'"; ;;
	esac
}
usage_error() { usage >&2; echo; echo "ERROR: $@" >&2; exit 1; }
debug() { if ${DEBUG:-false}; then echo "$@"; fi; }
warn() { echo "WARNING:" "$@" >&2; }
log() { if [ "$1" -le "${LOGLVL}" ]; then shift; echo "@" "$@" >&2; fi; }
fatal() { echo "FATAL:" "$@" >&2; exit 1; }
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
trap "trap_err $?" ERR

tolower() { echo "$@" | tr '[:upper:]' '[:lower:]'; }

ishexstring() {
	local tmp
	tmp="$(sed 's/[[:xdigit:]]*//' <<<"$1")"
	return "${#tmp}"
}

curl() {
	log 5 "$(/bin/printf "%q " curl "$@"; echo)";
	command curl "$@";
}

gettoken() {
	declare -g outvar="$1"
	declare -g TOKENFILE
	local tmp expires_in access_token aquired_on expires_on

	if [ -e "$TOKENFILE" ]; then
		. "$TOKENFILE"
		local now;
		now=$(date +%s);
		if [ "$now" -lt "$expires_on" ]; then
			log 1 "Token read from cache file."
			log 3 "access_token=$access_token expires_on=$expires_on"
			eval "$outvar"="$access_token"
			return
		fi
		log 2 "Token from cache file expired."
		log 3 "Token $expires_on $now $aquired_on"
		rm "$TOKENFILE"
	fi

	log 2 "Requesting token..."
	token=$(
		curl \
			-sS \
  			--request POST \
  			--url 'https://authorization.netemera.com/api/v2/oauth2/token' \
			--user "${CLIENT_ID}"':'"${CLIENT_SECRET}" \
  			--data 'grant_type=client_credentials&audience=https://application.lorawan.netemera.com/api/v4'
	)

	gettoken_getvalue() { 
		local ret
		ret=$(printf "%s\n" "$1" | jq -r ".$2");
		if [ "$ret" = "null" ]; then
			return 1
		fi
		printf "%s\n" "$ret"
	}

	if error=$(gettoken_getvalue "$token" error); then
		if error_desc=$(gettoken_getvalue "$token" error_description); then
			fatal "Getting token from server failed with description:"$'\n'"$error_desc"
		else
			fatal "Getting token from server failed. Server returned no description."
		fi
	fi
	if ! expires_in=$(gettoken_getvalue "$token" expires_in); then
		fatal "expires_in field is missing in aquired token $token"
	fi
	if ! access_token=$(gettoken_getvalue "$token" access_token); then
		fatal "error getting field access_token in received token $token"
	fi

	aquired_on=$(date +%s)
	expires_on=$(( aquired_on + $expires_in ))
	declare -p access_token expires_in aquired_on expires_on > "$TOKENFILE"

	log 1 "Requesting token success. Token expires in $expires_in seconds."
	eval "$outvar"="$access_token"
}

ask() {
	gettoken token
	log 1 "Connect"

	local url 
	url="$1"
	shift
	curl \
  		-sS \
		-H "Authorization: Bearer ${token}" \
  		--url "https://application.lorawan.netemera.com/api/v4/$url" \
  		"$@"
  	echo
}

date_iso_8601() {
	# 2019-04-02T00:00:00.000Z
	date -u --date="$1" +%Y-%m-%dT%H:%M:%SZ
}

# Main ####################################################

NICE_OUTPUT=false
NICE_COLUMN_OUTPUT=false
while getopts "vsc:hHN" opt; do
	case "$opt" in
	v) ((LOGLVL++))||:; ;;
	s) ((LOGLVL--))||:; ;;
	h) usage; exit; ;;
	c) CONFIGFILE=$OPTARG; ;;
	H) NICE_OUTPUT=true; ;;
	N) NICE_COLUMN_OUTPUT=true; ;;
	*) usage_error "Argument '$opt' is invalid"; exit 1; ;;
	esac
done
shift $((OPTIND-1))

for i in CONFIGFILE CLIENT_ID CLIENT_SECRET CONFIGFILE TOKENFILE; do
	if eval [ -z "\"\${#$i}\"" ]; then
		fatal "Variable $i is empty"
	fi
	debug "Variable $i=${!i}"
done

# load configuration file
log 3 "Loading $CONFIGFILE"
. $CONFIGFILE

if [ $# -lt 1 ]; then
	usage; 
	exit;
fi;
mode=$1; 
shift

case "$mode" in
uplink*|downlink*)
	if [ $# -lt 1 ]; then usage_error "mode='$mode' needs argument."; fi
	eui=$(tolower $1)
	if ! ishexstring "$eui"; then fatal "eui='$eui' is not a hex string."; fi;
	;;
esac

case "$mode" in
uplink)
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

	ask "uplink-packets/end-devices/$eui?$args" -H 'Accept: text/event-stream' -H 'Cache-Control: no-cache' -m 0 --no-buffer |
	if "$NICE_OUTPUT"; then
		grep --line-buffered --extended-regexp '^data:.+' | cut -d: -f2- |
		if "$NICE_COLUMN_OUTPUT"; then
			jq -c -r '[ .recvTime, .devEui, "port=", .fPort, "fCntUp=", .fCntUp, "ack=", .ack, "adr=", .adr, "DR=", .dataRate, .ulFreq, .frmPayload ] | join(" ")'
		else
			jq --unbuffered -c .
		fi
	else
		cat
	fi
	;;
downlink)
	if [ "$#" -lt 3 ]; then usage_error "mode $mode needs more arguments"; fi;
	if (( ${#3} % 2 != 0 )); then usage_error "payload length is not dividable by 2"; fi;
	if ! ishexstring "$3"; then usage_error "payload is not a hex string"; fi;
	if (( $# == 4 )); then assert_true_or_false "$4" "confirmed"; fi;
	req=$(printf '{"data":{"type":"downlink-packet","attributes":{"fPort":%d,"confirmed":%s,"frmPayload":"%s"}}}' "$2" "${4:-false}" "$3")
	log 1 "> Request: $req" >&2
	ask downlink-packets/end-devices/$1 -H "Content-Type: application/json" --data-raw "$req"
	;;
downlink_clear)
	echo "NOT IMPLEMENTED"
	exit 1
	;;
refresh_token)
	if [ -e "$TOKENFILE" ]; then
		rm "$TOKENFILE"
	fi
	gettoken _
	;;
*)
	usage_error "Unknown mode"
	;;
esac
