#!/bin/sh
set -u

card_name="LenovoY700TB321"
driver_dir="/sys/bus/platform/drivers/snd-sc8280xp"
device_name="sound"

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
	log_file="/run/y700-audio-card-guard-alsaucm.log"
	if alsaucm -c "$card_name" set _verb HiFi set _enadev Speaker set _enadev Mic1 >"$log_file" 2>&1; then
		log "audio UCM initialized: HiFi Speaker Mic1"
	else
		ret=$?
		err=$(cat "$log_file" 2>/dev/null || true)
		log "audio UCM init failed ret=$ret err=$err"
	fi
}

for attempt in 0 1 2 3 4 5 6 7 8 9 10 11 12; do
	if has_card; then
		log "audio card present attempt=$attempt"
		init_ucm
		exit 0
	fi

	if [ "$attempt" != 0 ] && [ -w "$driver_dir/bind" ] &&
	   [ ! -e "$driver_dir/$device_name" ]; then
		err=$(printf '%s\n' "$device_name" > "$driver_dir/bind" 2>&1)
		ret=$?
		if [ "$ret" -eq 0 ]; then
			log "audio card missing attempt=$attempt; requested platform bind"
		else
			log "audio card missing attempt=$attempt; platform bind failed ret=$ret err=$err"
		fi
	else
		log "audio card missing attempt=$attempt; waiting"
	fi

	sleep 10
done

log "audio card still missing after retries"
exit 0
