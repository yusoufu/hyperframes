#!/usr/bin/env bash
# frame_strip.sh — produce a side-by-side comparison strip from two videos.
#
# Used to debug failing render_diff.sh runs visually: pick a sample timestamp
# range, extract frames from both videos, lay them out as a grid for review.
#
# Usage:
#   frame_strip.sh <baseline.mp4> <translated.mp4> [output-dir] [samples]
#
# Defaults: output-dir=./strip-out, samples=8 (evenly spaced across duration).
# Output:
#   strip.png         — single PNG with `samples` rows, each row is
#                       (baseline frame | translated frame) at one timestamp
#   timestamps.txt    — the timestamps sampled

set -euo pipefail

if [[ $# -lt 2 || $# -gt 4 ]]; then
  echo "usage: $0 <baseline.mp4> <translated.mp4> [output-dir] [samples]" >&2
  exit 2
fi

BASELINE="$1"
TRANSLATED="$2"
OUTDIR="${3:-./strip-out}"
SAMPLES="${4:-8}"

if ! command -v ffmpeg >/dev/null 2>&1 || ! command -v ffprobe >/dev/null 2>&1; then
  echo "error: ffmpeg/ffprobe not on PATH" >&2
  exit 2
fi

mkdir -p "$OUTDIR"

DURATION=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$BASELINE")
if [[ -z "$DURATION" ]]; then
  echo "error: could not read duration from $BASELINE" >&2
  exit 2
fi

# Even-spaced timestamps that avoid both 0.0 (often blank intro) and end-of-video.
python3 - "$DURATION" "$SAMPLES" "$OUTDIR/timestamps.txt" <<'PY'
import sys
duration = float(sys.argv[1])
samples = int(sys.argv[2])
out = sys.argv[3]
# Sample at evenly spaced points starting at 5% into the duration to avoid
# the typical 0-frame transparency / fade-in noise.
start = duration * 0.05
end = duration * 0.95
step = (end - start) / max(samples - 1, 1)
ts = [round(start + i * step, 3) for i in range(samples)]
with open(out, "w") as f:
    f.write("\n".join(str(t) for t in ts) + "\n")
PY

# Extract one frame from each video at each timestamp.
i=0
ROW_INPUTS=""
while IFS= read -r ts; do
  i=$((i + 1))
  ffmpeg -y -hide_banner -loglevel error -ss "$ts" -i "$BASELINE"   -frames:v 1 "$OUTDIR/baseline-$i.png"
  ffmpeg -y -hide_banner -loglevel error -ss "$ts" -i "$TRANSLATED" -frames:v 1 "$OUTDIR/translated-$i.png"
  # hstack each row, then later vstack all rows.
  ffmpeg -y -hide_banner -loglevel error \
    -i "$OUTDIR/baseline-$i.png" -i "$OUTDIR/translated-$i.png" \
    -filter_complex "[0:v][1:v]hstack=inputs=2" \
    "$OUTDIR/row-$i.png"
  ROW_INPUTS="$ROW_INPUTS -i $OUTDIR/row-$i.png"
done < "$OUTDIR/timestamps.txt"

# vstack all rows.
FILTER=""
COUNT=$(wc -l < "$OUTDIR/timestamps.txt" | tr -d ' ')
for j in $(seq 1 "$COUNT"); do
  FILTER="$FILTER[$((j - 1)):v]"
done
FILTER="${FILTER}vstack=inputs=$COUNT"

# shellcheck disable=SC2086
ffmpeg -y -hide_banner -loglevel error \
  $ROW_INPUTS \
  -filter_complex "$FILTER" \
  "$OUTDIR/strip.png"

echo "wrote $OUTDIR/strip.png ($COUNT samples)"
