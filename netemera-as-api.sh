#!/bin/bash
set -euo pipefail; export SHELLOPTS

# Environmnt variables
: ${CLIENT_ID:=}
: ${CLIENT_SECRET:=}
: ${AUTHORIZATION_HOST:=}
: ${APPLICATION_HOST:=}
: ${CONFFILE:=netemera-as-api.conf}
: ${LOGLVL:=2}
: ${CURLOPTS:=}
: ${DEBUG:=false}
: ${TOKENFILE:=/tmp/.$(basename $0).token}
: ${NO_FILTER:=false}
VERSION=v0.1.0
if $DEBUG; then set -x; fi;

# Functions ###################################################

usage() {
	cat <<EOF
Usage:
	netemera-as-api.sh [OPTIONS] <mode> <arguments...>

Modes:
	application_uplink <app_id>
	uplink <dev_eui> [<from_time>] [<until_time>]
	downlink <dev_eui> <f_port> <frm_payload> [<confirmed default:false>]
	downlink_clear <dev_eui>
	refresh_token

Options:
	-v   increase loglevel
	-s   decrese loglevel
	-c   specify config file to load
	-h   print this help and exit

Configuration files:
	/etc/${CONFFILE}
	~/.${CONFFILE}

Configuration variables:
	CLIENT_ID=
	CLIENT_SECRET=
	AUTHORIZATION_HOST=
	APPLICATION_HOST=
	LOGLVL=${LOGLVL}
	TOKENFILE=${TOKENFILE}

Examples:
	netemera-as-api.sh uplink ffffffffff00001b
	netemera-as-api.sh uplink ffffffffff000014 -7day
	netemera-as-api.sh uplink ffffffffff000014 -7day -1day
	netemera-as-api.sh downlink ffffffffff00001b 1 0101
	netemera-as-api.sh refresh_token

netemera-as-api.sh ${VERSION}
Copyright (C) 2018 Netemera under Apache License. Written by Kamil Cukrowski.
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
	echo "Backtrace is: " >&2; 
	for ((i=0;1;++i));do caller "$i" >&2||break; done;
	sed -n $(caller $((i-1))|cut -d' ' -f1)"p" $0;
}
trap "trap_err" ERR

tolower() { echo "$@" | tr '[:upper:]' '[:lower:]'; }

ishexstring() {
	local tmp
	tmp="$(sed 's/[[:xdigit:]]*//' <<<"$1")"
	return "${#tmp}"
}

curl() {
	log 10 curl "$@";
	command curl "$@";
}

gettoken() {
	local -n outvar="$1"
	declare -g TOKENFILE
	local tmp expires_in access_token aquired_on expires_on
	if [ -e "$TOKENFILE" ]; then
		tmp=$(cat "$TOKENFILE" | sed 's/^\([^=]*\)=.*/\1/')
		if ! local $tmp; then
			log 2 "error reading variable names from TOKENFILE=$TOKENFILE"
			rm "$TOKENFILE"
		else
			. "$TOKENFILE"
			local now;
			now=$(date +%s);
			if [ "$now" -lt "$expires_on" ]; then
				log 2 "Token read from cache file."
				log 3 "access_token=$access_token expires_on=$expires_on"
				outvar="$access_token"
				return
			fi
			log 2 "Token from cache file expired."
			log 3 "Token $expires_on $now $aquired_on"
			rm "$TOKENFILE"
		fi
	fi

	log 2 "Requesting token..."
	token=$(
		curl -sS \
		--request POST \
		--url "https://${AUTHORIZATION_HOST}/api/v1/oauth2/token?grant_type=client_credentials&audience=https://${APPLICATION_HOST}/api/v3" \
		--user "${CLIENT_ID}"':'"${CLIENT_SECRET}"
	)
	token=$(echo "$token" \
		| sed -n '/^{/,$p' \
		| sed 's/^{//;s/}$//' \
		| tr ',' '\n' \
		| sed 's/^"\(.*\)"[[:space:]]*:[[:space:]]*\(.*\)[[:space:]]*$/\1=\2/'
	)
	gettoken_getvalue() { echo "$1" | grep "^$2=" | sed -n "s/^$2=//;s/^\"//;s/\"$//;p;"; }
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
	expires_on=$(date --date="+ $expires_in seconds" +%s)
	{
		echo "$token"
		for i in aquired_on expires_on; do
			echo "$i=\"${!i}\""
		done
	} > "$TOKENFILE"
	log 2 "Requesting token success. Token expires in $expires_in seconds."
	outvar="$access_token"
}

ask() {
	local url token
	url=https://"$APPLICATION_HOST"/api/v3/"$1"
	# remove multiple ////,  but leave https://
	url=$(sed -e 's#[/]\+#/#g' -e 's#/#//#' <<<"$url")
	shift
	gettoken token
	log 3 "token_length=${#token}"
	log 1 "Connect"
	curl -sS \
		-H "Authorization: Bearer ${token}" \
		"$@" \
		"$url" \
		${CURLOPTS}
	echo # api/v2 does not return new line
}

sse_parse() {
	# https://www.w3.org/TR/2015/REC-eventsource-20150203/
	local line="" field="" value=""
	local data="" events="" id=""
	local last_event_ID_string=""
	local reconnection_time="1000"
	sse_parse_field_event() {
		local field value tmp
		local -g events data id reconnection_time
		field=$1
		value=$2
		case "$field" in
			event) events="$value"; ;;
			data) data+="$value"$'\n'; ;;
			id) id="$value"; ;;
			retry)
				tmp="$(sed 's/[0-9]//g' <<<"$value")"
				if [ -z "$tmp" ]; then
					# set the event stream's reconnection time to that integer.
					log 3 "Reconnection time is not supprted"
					reconnection_time="$value"
				else
					# Otherwise, ignore the field.
					log 4 "Field 'retry' ignored cause not only ASCII digits. value='$value'"
				fi
				;;
			*)
				log 1 "Field='$field' with value='$value' is ignored."
				;;
		esac
	}
	while read line; do 
		log 5 "sse_parse: Read line='$line'"
		case "$line" in
		"@"*)
			# lines starting with @ are logs in our program
			echo "$line"
			;;
		"")
			# If the line is empty (a blank line)
			# Dispat-ech the event, as defined below.
			# 1. Set the last event ID string of the event source to value of the last event ID
			# buffer
			last_event_ID_string="$id"
			# 2. If the data buffer is an empty string, set the data buffer and the event type 
			# buffer to the empty string and abort these steps.
			if [ -n "$data" ]; then
				# 3. If the data buffer's last character is a U+000A LINE FEED (LF) character, then 
				# remove the last character from the data buffer.
				if [ "${data: -1}" == $'\n' ]; then
					data="${data::-1}"
				fi
				# 4. Create an event that us...
				# 5. type not supported
				echo "$data" | sed -e '/^$/d'
				# 6. Set the data buffer and the event type buffer to the empty string.
				id=""
			fi
			data="" events=""
			;;
		:) 
			# If the line starts with a U+003A COLON character (:)
			# Ignore the line.
			;;
		*:*)
			# If the line contains a U+003A COLON character (:)
			# Collect the characters on the line before the first U+003A COLON character (:), and 
			# let field be that string.
			field=$(sed 's/\([^:]*\):.*/\1/' <<<"$line")
			value=$(sed 's/[^:]*:[ ]\?\(.*\)/\1/' <<<"$line")
			sse_parse_field_event "$field" "$value"
			;;
		*) 
			# Otherwise, the string is not empty but does not contain a U+003A COLON character (:)
			# The steps to process the field given a field name and a field value depend on the 
			# field name, as given in the following list. Field names must be compared literally, 
			# with no case folding performed.
			sse_parse_field_event "$line" ""
			;;
		esac
	done
}


# Main ####################################################

CMDCONFFILE=""
while getopts "vsc:h" opt; do
	case "$opt" in
	v) ((LOGLVL++)); ;;
	s) ((LOGLVL--)); ;;
	h) usage; exit; ;;
	c) CMDCONFFILE=$OPTARG; ;;
	*) usage; ;;
	esac
done
shift $((OPTIND-1))

# load configuration file
if [ -n "$CMDCONFFILE" ]; then
	log 3 "Loading $CMDCONFFILE"
	. $CMDCONFFILE
else
	for d in /etc "$HOME/.config"; do
		if [ -e "$d/$CONFFILE" ]; then
			log 3 "Loading $d/$CONFFILE ..."
			. "$d/$CONFFILE"
		fi
	done
fi

for i in CLIENT_ID CLIENT_SECRET AUTHORIZATION_HOST APPLICATION_HOST  TOKENFILE; do
	if eval [ -z "\"\${#$i}\"" ]; then
		fatal "Variable $i is empty"
	fi
	debug "Variable $i=${!i}"
done

if [ $# -lt 1 ]; then usage; exit; fi;
mode=$1; shift

case "$mode" in
application*|uplink*|downlink*)
	if [ $# -lt 1 ]; then usage_error "mode='$mode' needs argument."; fi
	eui=$(tolower $1)
	if ! ishexstring "$eui"; then fatal "eui='$eui' is not a hex string."; fi;
	;;
esac

case "$mode" in
application_uplink)
	ask uplink-packets/applications/$eui \
		-H 'Accept: text/event-stream' -H 'Cache-Control: no-cache' -m 0
	;;
uplink|uplink_hist)
	if [ $# -eq 1 ]; then
		# uplink
		ask uplink-packets/end-devices/$eui \
			-H 'Accept: text/event-stream' -H 'Cache-Control: no-cache' -m 0 --no-buffer \
		| {
			if ${NO_FILTER:-false}; then 
				exec cat; 
			else
				sse_parse
			fi
		}
	else
		# old uplink_hist
		from_time=$(date --date="$2" -u +%Y-%m-%dT%H:%M:%SZ)
		str="from_time=${from_time}"
		if [ $# -ge 3 ]; then
			until_time=$(date --date="$3" -u +%Y-%m-%dT%H:%M:%SZ)
			str+="&until_time=${until_time}"
		fi
		if [ $# -ge 4 ]; then usage_error "Too many arguments for mode=$mode"; fi;
		ask "uplink-packets/end-devices/$eui?${str}"
	fi
	;;
downlink)
	if [ $# -lt 2 ]; then usage_error "mode $mode needs more arguments"; fi;
	if (( ${#3} % 2 != 0 )); then usage_error "payload length is not dividable by 2"; fi;
	if ! ishexstring "$3"; then usage_error "payload is not a hex string"; fi;
	if (( $# == 4 )); then assert_true_or_false "$4" "confirmed"; fi;
	req="{\"dev_eui\":\"$1\",\"f_port\":$2,\"frm_payload\":\"$3\",\"confirmed\":${4-false}}"
	log 1 "> Request: $req" >&2
	ask downlink-packets/end-devices/$1 --data-raw "$req" -H "Content-Type: application/json"
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
