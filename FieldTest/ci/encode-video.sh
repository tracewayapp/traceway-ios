#!/bin/bash
# encode-video.sh <run dir>
#
# screen.raw.mp4 (the Simulator's pixels, 1320 × 2868, large) → screen.mp4:
# H.264 at twice the logical size (880 × 1912), with the shared encoding
# (tools/README.md: -crf 23 -maxrate 2M -bufsize 4M, yuv420p, faststart) and
# the frame times kept as recorded (variable frame rate), so a frame's time in
# the file stays the recorder's start + pts. The raw file is kept only when it
# is small. ffprobe's view of both files goes into screen-probe.json.
set -uo pipefail
RUN_DIR=$1
RAW="$RUN_DIR/screen.raw.mp4"
[ -s "$RAW" ] || { echo "no screen recording in $RUN_DIR" >&2; exit 0; }

if command -v ffmpeg > /dev/null; then
  ffmpeg -nostdin -loglevel error -y -i "$RAW" -vf "scale=-2:1912" -c:v libx264 -preset veryfast \
    -crf 23 -maxrate 2M -bufsize 4M -pix_fmt yuv420p -movflags +faststart -fps_mode passthrough -an \
    "$RUN_DIR/screen.mp4" || cp "$RAW" "$RUN_DIR/screen.mp4"
  {
    echo '{"raw":'
    ffprobe -v error -show_entries format=start_time,duration,size:stream=width,height,nb_frames,r_frame_rate,avg_frame_rate,start_pts,time_base \
      -of json "$RAW"
    echo ',"encoded":'
    ffprobe -v error -show_entries format=start_time,duration,size:stream=width,height,nb_frames,start_pts,time_base \
      -of json "$RUN_DIR/screen.mp4"
    echo '}'
  } > "$RUN_DIR/screen-probe.json" 2>/dev/null || true
else
  avconvert --source "$RAW" --output "$RUN_DIR/screen.mp4" --preset Preset1920x1080 --replace > /dev/null 2>&1 \
    || cp "$RAW" "$RUN_DIR/screen.mp4"
fi

RAW_BYTES=$(stat -f %z "$RAW")
if [ "$RAW_BYTES" -gt $((60 * 1024 * 1024)) ]; then
  rm -f "$RAW"
fi
