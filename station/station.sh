#!/bin/bash
# MiNERVA-FM station — headless, container-native radio engine.
# Indexes $MUSIC_DIR, then continuously picks a random track, publishes
# now-playing to the metadata bridge, and decodes it to PCM on the shared FIFO
# that the persistent ffmpeg encoder streams to Icecast.
# Decoders: ffmpeg+libgme (VGM/VGZ/SPC/NSF/...), ffmpeg+libopenmpt (MOD/XM/
# IT/S3M/...) and sidplayfp (SID) — no PulseAudio, tmux, or AUR players
# required. The extension lists below must stay in sync with EXTS in
# minerva-indexer.sh, or tracks are indexed but never decoded (or vice versa).

MUSIC_DIR="${MUSIC_DIR:-/music}"; MUSIC_DIR="${MUSIC_DIR%/}"
# Catalogue is written to a writable dir (mount /data as a volume to persist it),
# so the music mount can stay read-only.
CSV="${CATALOGUE:-/data/vgm_catalogue.csv}"
FIFO="${FIFO:-/tmp/radio.pcm}"
BRIDGE_URL="${BRIDGE_URL:-http://127.0.0.1:8088/update}"
BRIDGE_TOKEN="${BRIDGE_TOKEN:-changeme}"
MAX_TRACK="${MAX_TRACK:-300}"
SID_DURATION="${SID_DURATION:-180}"
SPC_MIN_DURATION="${SPC_MIN_DURATION:-60}"

SCHEMES=(gameboy gameboy_pocket bbc_micro pico8 cga nes minerva c64 zx_spectrum)
CHARS=("#" "|" ":" "+" "*" "=" "!" ">" "%" "@" "^" "~" "-" "o" "x")
log(){ echo "[station] $*" >&2; }

# --- build the catalogue from the mounted music if it isn't there yet ---
mkdir -p "$(dirname "$CSV")"
if [ ! -s "$CSV" ]; then
    log "indexing $MUSIC_DIR ..."
    OUTPUT_CSV="$CSV" /app/minerva-indexer.sh "$MUSIC_DIR" >&2 2>&1 || true
fi
if [ ! -s "$CSV" ]; then
    log "no playable music in $MUSIC_DIR — idling (mount your collection at /music)."
    while true; do sleep 3600; done
fi
log "catalogue ready: $(( $(wc -l < "$CSV") - 1 )) tracks"

parse_row(){
    mapfile -t F < <(python3 -c '
import sys,csv
r=next(csv.reader([sys.argv[1]]),[])
for i in (4,5,6,7,8,9): print(r[i] if i<len(r) else "")' "$1")
    CAT_ID="${F[0]}"; TLD="${F[1]}"; PLATFORM="${F[2]}"; GAME="${F[3]}"; FILE="${F[4]}"; META="${F[5]}"
}
publish(){
    local json
    json=$(python3 -c 'import json,sys;print(json.dumps(dict(id=sys.argv[1],platform=sys.argv[2],game=sys.argv[3],track=sys.argv[4],scheme=sys.argv[5],char=sys.argv[6])))' "$@") || return 0
    curl -fsS -m 5 -X POST "$BRIDGE_URL" -H "Authorization: Bearer $BRIDGE_TOKEN" \
        -H "Content-Type: application/json" --data "$json" >/dev/null 2>&1 || true
}

# --- skip support -----------------------------------------------------------
# POST /admin/skip → bridge → kill -USR1 $(cat /tmp/station.pid)
# The signal interrupts the current `wait`, the decoder is killed, and the
# loop immediately advances to the next track.
DECODER_PID=""
_skip() { [ -n "$DECODER_PID" ] && kill "$DECODER_PID" 2>/dev/null || true; }
trap _skip SIGUSR1
echo $$ > /tmp/station.pid

# Open the FIFO once for writing; the encoder reads it continuously, so it never
# sees EOF between tracks. This blocks until the encoder opens the read end.
exec 3>"$FIFO"
log "on air."

# Helper: run a decoder pipeline in the background, record its PID, and wait.
# SIGUSR1 interrupts wait; _skip() kills the decoder; loop advances.
_decode() {
    "$@" &
    DECODER_PID=$!
    wait "$DECODER_PID" 2>/dev/null || true
    DECODER_PID=""
}

while true; do
    row=$(tail -n +2 "$CSV" | grep -v '^[[:space:]]*$' | shuf -n 1)
    [ -z "$row" ] && { sleep 1; continue; }
    parse_row "$row"
    if [ -n "$PLATFORM" ] && [ "$PLATFORM" != "$TLD" ]; then
        path="$MUSIC_DIR/$TLD/$PLATFORM/$GAME/$FILE"
    else
        path="$MUSIC_DIR/$TLD/$GAME/$FILE"
    fi
    [ -f "$path" ] || { log "missing: $path"; continue; }

    scheme="${SCHEMES[$RANDOM % ${#SCHEMES[@]}]}"
    char="${CHARS[$RANDOM % ${#CHARS[@]}]}"
    log "▶ ${PLATFORM} / ${GAME//_/ } / ${FILE%.*}"
    publish "$CAT_ID" "$PLATFORM" "${GAME//_/ }" "${FILE%.*}" "$scheme" "$char"

    ext="${FILE##*.}"; ext="${ext,,}"
    case "$ext" in
        sid)
            dur=$(printf '%d:%02d' $((SID_DURATION/60)) $((SID_DURATION%60)))
            # Pipeline: sidplayfp → ffmpeg. $! is the ffmpeg PID; killing it
            # causes sidplayfp to get SIGPIPE and exit cleanly.
            { sidplayfp -t"$dur" -w- "$path" 2>/dev/null \
              | ffmpeg -hide_banner -loglevel error -i - -f s16le -ar 44100 -ac 2 - >&3 2>/dev/null; } &
            DECODER_PID=$!; wait "$DECODER_PID" 2>/dev/null || true; DECODER_PID="" ;;
        spc)
            dur="$META"; [[ "$dur" =~ ^[0-9]+$ ]] || dur=120
            [ "$dur" -lt "$SPC_MIN_DURATION" ] && dur="$SPC_MIN_DURATION"
            [ "$dur" -gt "$MAX_TRACK" ] && dur="$MAX_TRACK"
            _decode ffmpeg -hide_banner -loglevel error -t "$dur" -i "$path" -f s16le -ar 44100 -ac 2 - >&3 ;;
        vgm|vgz|nsf|nsfe|gbs|ay|kss|hes|gym|sap)
            _decode ffmpeg -hide_banner -loglevel error -t "$MAX_TRACK" -i "$path" -f s16le -ar 44100 -ac 2 - >&3 ;;
        mod|xm|it|s3m|mptm|mtm|med|okt|669|far|dbm|psm|ptm|mdl|dsm|amf|gdm|\
        stm|ult|umx|mo3|j2b|imf|digi|dmf|dtm|ams|mt2|plm|nst|wow|m15)
            # libopenmpt reports a real length, but a module with a pattern loop
            # can report a very long one — hold it to MAX_TRACK.
            _decode ffmpeg -hide_banner -loglevel error -t "$MAX_TRACK" -i "$path" -f s16le -ar 44100 -ac 2 - >&3 ;;
        mp3|flac|wav|ogg|opus)
            _decode ffmpeg -hide_banner -loglevel error -i "$path" -f s16le -ar 44100 -ac 2 - >&3 ;;
        *) log "unhandled ext: $FILE"; sleep 1 ;;
    esac
done
