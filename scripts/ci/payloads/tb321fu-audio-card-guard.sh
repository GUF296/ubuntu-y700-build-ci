#!/bin/sh
set -eu

card_name="LenovoY700TB321"
driver_dir="/sys/bus/platform/drivers/snd-sc8280xp"
device_name="sound"
ucm_log=${Y700_AUDIO_UCM_LOG:-/run/y700-audio-card-guard-alsaucm.log}

log()
{
	msg="$*"
	echo "$msg"
	logger -t y700-audio-card-guard "$msg" 2>/dev/null || true
}

has_card()
{
	grep -q "$card_name" /proc/asound/cards 2>/dev/null
}

init_ucm()
{
	if alsaucm -c "$card_name" set _verb HiFi set _enadev Speaker set _enadev Mic1 >"$ucm_log" 2>&1; then
		log "audio UCM initialized: HiFi Speaker Mic1"
		return 0
	else
		ret=$?
		err=$(cat "$ucm_log" 2>/dev/null || true)
		log "audio UCM init failed ret=$ret err=$err"
		return "$ret"
	fi
}

if has_card; then
	log "audio card present"
	init_ucm
	exit $?
fi

if [ -w "$driver_dir/bind" ] && [ ! -e "$driver_dir/$device_name" ]; then
	if err=$(printf '%s\n' "$device_name" > "$driver_dir/bind" 2>&1); then
		log "audio card missing; requested platform bind"
	else
		ret=$?
		log "audio card missing; platform bind failed ret=$ret err=$err"
		exit "$ret"
	fi

	for attempt in 1 2 3 4 5; do
		sleep 1
		if has_card; then
			log "audio card appeared after bind attempt=$attempt"
			init_ucm
			exit $?
		fi
	done
else
	log "audio card missing; platform device is already bound or bind is unavailable"
fi

log "audio card is not ready; systemd will retry"
exit 1
