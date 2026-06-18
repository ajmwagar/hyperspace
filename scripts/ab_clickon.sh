#!/bin/bash
# A/B "click-on" demo: first half of CLEAN spliced into second half of FX,
# so the pedal audibly engages at the midpoint. Lower-third center labels,
# time-gated per segment, clean cut. Renders through the hyperspace scope.
#
# Usage: scripts/ab_clickon.sh CLEAN.wav "Clean Label" FX.wav "FX Label" OUT.mp4 [split_seconds] [resolution: 16:9|4:5|1:1|9:16|WxH]
set -euo pipefail

CLEAN="${1:?clean wav}"; CLABEL="${2:?clean label}"
FX="${3:?fx wav}";       FLABEL="${4:?fx label}"
OUT="${5:?out mp4}"
# Repo root = parent of this script's dir, so the script is portable.
HS="$(cd "$(dirname "$0")/.." && pwd)"

# Split point: half of the FX clip (the two takes are the same phrase, so a
# same-timestamp splice = a continuous performance that "clicks on" at T).
FXD=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$FX")
T="${6:-$(awk "BEGIN{printf \"%.3f\", $FXD/2}")}"
RES="${7:-16:9}"

STITCH=$(mktemp /tmp/ab_stitch.XXXX.wav)
BASE=$(mktemp /tmp/ab_base.XXXX.mp4)

# 1) Splice: CLEAN[0:T] + FX[T:end], normalized to s16/48k/stereo, hard cut.
ffmpeg -y -v error -i "$CLEAN" -i "$FX" -filter_complex \
  "[0:a]atrim=0:$T,aformat=sample_fmts=s16:sample_rates=48000:channel_layouts=stereo[a];\
   [1:a]atrim=$T,asetpts=PTS-STARTPTS,aformat=sample_fmts=s16:sample_rates=48000:channel_layouts=stereo[b];\
   [a][b]concat=n=2:v=0:a=1[o]" -map "[o]" "$STITCH"

# 2) Render the spliced audio through the hyperspace oscilloscope scene.
( cd "$HS" && cargo run --release --features render --example render -- "$STITCH" "$BASE" scenes/composed.toml 30 "$RES" >/dev/null 2>&1 )

# 3) Per-segment text overlay (lower-third center, color-coded, time-gated).
FONT=$(for c in /System/Library/Fonts/Supplemental/Arial.ttf /System/Library/Fonts/Helvetica.ttc /System/Library/Fonts/SFNS.ttf; do [ -f "$c" ] && echo "$c" && break; done)
TOT=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$BASE")
H=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "$BASE")
FS=$(awk "BEGIN{print int($H/15)}")    # label size scales with frame height
YOFF=$(awk "BEGIN{print int($H/11)}")  # lower-third offset from bottom
BW=$(awk "BEGIN{print int($FS/3)}")    # box border padding
ffmpeg -y -v error -i "$BASE" -vf \
  "drawtext=fontfile=$FONT:text='$CLABEL':fontsize=$FS:fontcolor=white:box=1:boxcolor=black@0.5:boxborderw=$BW:x=(w-text_w)/2:y=h-text_h-$YOFF:enable='between(t,0,$T)',\
   drawtext=fontfile=$FONT:text='$FLABEL':fontsize=$FS:fontcolor=0xFF7A1A:box=1:boxcolor=black@0.5:boxborderw=$BW:x=(w-text_w)/2:y=h-text_h-$YOFF:enable='between(t,$T,$TOT)'" \
  -c:a copy "$OUT"

rm -f "$STITCH" "$BASE"
echo "OK: $OUT  (split at ${T}s)"
