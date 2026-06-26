#!/bin/sh
# MiNERVA-FM all-in-one station entrypoint.
set -e
: "${BRIDGE_TOKEN:=changeme}"; export BRIDGE_TOKEN

# HLS output directory
mkdir -p /tmp/hls

# Generate a fresh random AES-128 key on every container start.
# Segments written in a previous run are unreadable after restart.
openssl rand 16 > /tmp/hls.key
# Key info file for ffmpeg: line 1 = URI served to clients, line 2 = local key path
printf '/hls-key\n/tmp/hls.key\n' > /tmp/hls.keyinfo

# PCM FIFO between station decoder and ffmpeg encoder
rm -f /tmp/radio.pcm
mkfifo /tmp/radio.pcm

echo "[entrypoint] MiNERVA-FM station — indexing /music, broadcasting on http://localhost:8080/"
exec supervisord -c /etc/supervisor/conf.d/minerva.conf -n
