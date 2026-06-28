#!/usr/bin/env bash
# montage.sh — build an audio-reactive shader montage with beat-aligned
# cross-dissolves, and export it with a named quality/aspect profile.
#
# Why this exists: a montage cut to music has three gotchas this script handles
# for you:
#   1. The offline analyser (examples/render) starts with zeroed FFT/energy
#      state, so the first ~0.5 s of any clip is garbage onsets/beats. We render
#      each clip with LEAD bars of warm-up and then keep only the bars after it,
#      so the visible part is locked to the kick.
#   2. Cross-dissolves overlap clips, which would drift the visuals off the beat.
#      We trim each clip to "its bars + D of dissolve lead" and advance the xfade
#      offset by exactly the clip's bar count, then shift the muxed audio back by
#      D — so every shader's reactive bar stays on the downbeat, dissolves and all.
#   3. Aspect ratio is baked at RENDER time (the shaders frame to the viewport),
#      so 9:16 / 4:5 / 1:1 each need their own render — not a crop. ASPECT below
#      drives the render resolution, not just the final container.
#
# Usage:
#   TRACK=/path/track.mp3 WS=181.98 BPM=124.53 \
#   ASPECT=9:16 PROFILE=high scripts/montage.sh
#
# Get WS (window start, on a downbeat) and BPM from your track however you like
# (a DAW, or the analysis helper in the project notes). BAR is derived from BPM.
#
# ── Export profiles ──────────────────────────────────────────────────────────
#   master : CRF 12, 320k AAC      — archival / re-edit master (large)
#   high   : CRF 16, 256k AAC      — crisp upload (IG/web accept high bitrate)
#   web    : CRF 27, 192k AAC      — small preview / chat-friendly (<~30MB @35s)
#   prores : ProRes 422 HQ, .mov   — for importing into an NLE
# ── Aspect presets (passed straight to examples/render) ──────────────────────
#   9:16 (1080x1920) · 4:5 (1080x1350) · 1:1 (1080x1080) · 16:9 (1920x1080)
set -euo pipefail
cd "$(dirname "$0")/.."   # repo root

TRACK="${TRACK:?set TRACK=/path/to/track.(mp3|wav)}"
WS="${WS:?set WS=<window-start-seconds, on a downbeat>}"
BPM="${BPM:?set BPM=<beats per minute>}"
ASPECT="${ASPECT:-9:16}"
PROFILE="${PROFILE:-high}"
FPS="${FPS:-30}"
D="${D:-0.5}"             # crossfade seconds
LEAD="${LEAD:-2}"         # warm-up bars per clip
WORK="${WORK:-/tmp/hs-montage}"
OUT="${OUT:-montage_${ASPECT/:/x}_${PROFILE}.mp4}"

# Playlist: "shader:bars". Edit freely. Heroes get more bars to breathe.
PLAYLIST=(${PLAYLIST:-
  sierpinski_dive:2 mandelbulb:2 apollonian:1 caustics:1 liquid_chrome:2
  acid_soup:1 fractal_zoom:1 neon_tunnel:1 ripples:1 mandelbox:1
  voronoi_cells:1 gradient_flow:1 plato_rave:1 sierpinski:2
})

BAR=$(python3 -c "print(f'{4*60/$BPM:.6f}')")
mkdir -p "$WORK/scenes" "$WORK/clips" "$WORK/trim"
echo "bar=${BAR}s  aspect=$ASPECT  profile=$PROFILE  clips=${#PLAYLIST[@]}"

# ── 1. render each clip against a (LEAD + bars)-bar slice of the track ────────
cum=0
for idx in "${!PLAYLIST[@]}"; do
  shader="${PLAYLIST[$idx]%%:*}"; bars="${PLAYLIST[$idx]##*:}"
  src=$(python3 -c "print(f'{$WS + $cum*$BAR - $LEAD*$BAR:.4f}')")
  len=$(python3 -c "print(f'{($LEAD + $bars)*$BAR:.4f}')")
  ffmpeg -y -loglevel error -ss "$src" -t "$len" -i "$TRACK" -ar 44100 -ac 2 "$WORK/clips/a$idx.wav"
  printf '[center]\nshader = "shaders/%s.wgsl"\n' "$shader" > "$WORK/scenes/$idx.toml"
  echo "  render [$idx] $shader (${bars} bar)"
  cargo run --release --features render --example render -- \
    "$WORK/clips/a$idx.wav" "$WORK/clips/c$idx.mp4" "$WORK/scenes/$idx.toml" "$FPS" "$ASPECT" >/dev/null 2>&1
  cum=$((cum + bars))
done
TOTAL=$cum

# ── 2. trim each clip to its reactive bars + D dissolve lead ──────────────────
START=$(python3 -c "print(f'{$LEAD*$BAR - $D:.4f}')")
for idx in "${!PLAYLIST[@]}"; do
  bars="${PLAYLIST[$idx]##*:}"
  len=$(python3 -c "print(f'{$bars*$BAR + $D:.4f}')")
  ffmpeg -y -loglevel error -ss "$START" -t "$len" -i "$WORK/clips/c$idx.mp4" \
    -an -c:v libx264 -preset medium -pix_fmt yuv420p -r "$FPS" -vsync cfr "$WORK/trim/t$idx.mp4"
done

# ── 3. crossfade chain: transition offset = cumulative bars × bar ─────────────
inputs=""; for idx in "${!PLAYLIST[@]}"; do inputs="$inputs -i $WORK/trim/t$idx.mp4"; done
filter=""; prev="[0:v]"; cum=0; last=$(( ${#PLAYLIST[@]} - 2 ))
for k in $(seq 0 "$last"); do
  cum=$((cum + ${PLAYLIST[$k]##*:}))
  off=$(python3 -c "print(f'{$cum*$BAR:.4f}')")
  out="[x$k]"; [ "$k" -eq "$last" ] && out="[v]"
  filter="${filter}${prev}[$((k+1)):v]xfade=transition=fade:duration=$D:offset=$off${out};"
  prev="[x$k]"
done
filter="${filter%;}"

# ── 4. audio: window shifted back by D so reactivity stays aligned ────────────
astart=$(python3 -c "print(f'{$WS - $D:.4f}')")
alen=$(python3 -c "print(f'{$TOTAL*$BAR + $D:.4f}')")
fout=$(python3 -c "print(f'{$TOTAL*$BAR + $D - 0.4:.3f}')")
ffmpeg -y -loglevel error -ss "$astart" -t "$alen" -i "$TRACK" \
  -af "afade=t=in:st=0:d=0.05,afade=t=out:st=$fout:d=0.4" -ar 44100 -ac 2 "$WORK/audio.wav"

# ── 5. encode with the chosen profile ────────────────────────────────────────
case "$PROFILE" in
  master) VENC=(-c:v libx264 -preset slow -crf 12); AB=320k;;
  high)   VENC=(-c:v libx264 -preset slow -crf 16); AB=256k;;
  web)    VENC=(-c:v libx264 -preset slow -crf 27); AB=192k;;
  prores) VENC=(-c:v prores_ks -profile:v 3); AB=320k; OUT="${OUT%.mp4}.mov";;
  *) echo "unknown PROFILE=$PROFILE (master|high|web|prores)" >&2; exit 2;;
esac
n=${#PLAYLIST[@]}
ffmpeg -y -loglevel error $inputs -i "$WORK/audio.wav" \
  -filter_complex "$filter" -map "[v]" -map "${n}:a" \
  "${VENC[@]}" -pix_fmt yuv420p -c:a aac -b:a "$AB" -shortest "$OUT"

dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$OUT")
mb=$(du -m "$OUT" | cut -f1)
echo "→ $OUT  (${dur}s, ${mb}MB, $ASPECT, $PROFILE)"
