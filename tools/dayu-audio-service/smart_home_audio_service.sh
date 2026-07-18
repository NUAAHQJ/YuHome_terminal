#!/system/bin/sh

CAPTURE_PORT=19101
PLAYBACK_PORT=19102
LOG_FILE=/data/local/tmp/smart_home_audio_service.log

log_message() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG_FILE"
}

find_usb_card() {
  for id_file in /proc/asound/card*/id; do
    if [ ! -r "$id_file" ]; then
      continue
    fi
    card_id=$(cat "$id_file" 2>/dev/null)
    if [ "$card_id" = "BAR" ]; then
      card_path=${id_file%/id}
      card_name=${card_path##*/card}
      echo "$card_name"
      return 0
    fi
  done
  return 1
}

configure_usb_card() {
  card="$1"
  amixer -c "$card" sset PCM unmute >/dev/null 2>&1
  amixer -c "$card" sset PCM 90% >/dev/null 2>&1
  amixer -c "$card" sset Mic cap 95% >/dev/null 2>&1
  amixer -c "$card" sset "Auto Gain Control" on >/dev/null 2>&1
}

capture_loop() {
  last_card=""
  while true; do
    card=$(find_usb_card)
    if [ -z "$card" ]; then
      last_card=""
      sleep 1
      continue
    fi
    if [ "$card" != "$last_card" ]; then
      configure_usb_card "$card"
      log_message "capture device hw:$card,0"
      last_card="$card"
    fi
    arecord -q -D "plughw:$card,0" -t raw -f S16_LE -r 16000 -c 1 \
      --period-size=3840 --buffer-size=15360 2>>"$LOG_FILE" | \
      /bin/busybox nc -u -w 1 127.0.0.1 "$CAPTURE_PORT"
    sleep 1
  done
}

playback_loop() {
  last_card=""
  while true; do
    card=$(find_usb_card)
    if [ -z "$card" ]; then
      last_card=""
      sleep 1
      continue
    fi
    if [ "$card" != "$last_card" ]; then
      configure_usb_card "$card"
      log_message "playback device plughw:$card,0"
      last_card="$card"
    fi
    /bin/busybox nc -l -p "$PLAYBACK_PORT" -w 2 | \
      aplay -q -D "plughw:$card,0" -t raw -f S16_LE -r 48000 -c 1 \
      --period-size=960 --buffer-size=3840 2>>"$LOG_FILE"
    sleep 1
  done
}

log_message "service starting"
capture_loop &
capture_pid=$!
playback_loop &
playback_pid=$!

trap 'kill "$capture_pid" "$playback_pid" 2>/dev/null; exit 0' TERM INT
wait
