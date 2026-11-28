#!/usr/bin/env bash
# What video encoding costs on this runner (written to out/encoder-check.txt
# before the first evidence run): whether VideoToolbox (hardware) encoding
# works in the VM, and how fast a 1320 x 2868 picture encodes in software.
# `simctl io recordVideo` encodes the Simulator's screen at that size.
set -u
echo "cpus: $(sysctl -n hw.ncpu) model: $(sysctl -n machdep.cpu.brand_string 2>/dev/null)"
if ! command -v ffmpeg > /dev/null; then echo "no ffmpeg"; exit 0; fi
ffmpeg -hide_banner -encoders 2>/dev/null | grep -i videotoolbox || echo "no videotoolbox encoders in ffmpeg"
for codec in h264_videotoolbox hevc_videotoolbox "libx264 -preset veryfast"; do
  start=$(perl -MTime::HiRes=time -e 'printf "%.3f", time()')
  # shellcheck disable=SC2086
  if ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i testsrc2=size=1320x2868:rate=30 -t 4 \
      -c:v $codec -f null - 2> /tmp/encoder-check.err; then
    end=$(perl -MTime::HiRes=time -e 'printf "%.3f", time()')
    echo "$codec: 120 frames of 1320x2868 in $(echo "$end - $start" | bc) s"
  else
    echo "$codec: failed: $(head -c 300 /tmp/encoder-check.err)"
  fi
done
