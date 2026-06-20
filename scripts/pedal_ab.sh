#!/bin/bash
# Pedal A/B "click-on" video: run a DI/clean wav through a .pedal circuit (in the
# pedalkernel engine), then build a click-on A/B reel — clean for the first half,
# the pedal engaging mid-phrase for the second — rendered through the hyperspace
# oscilloscope. Clean and wet are the same source, so the splice is seamless.
#
# Usage:
#   scripts/pedal_ab.sh INPUT.wav CIRCUIT.pedal OUT.mp4 [Knob=value ...]
#
# Trailing Knob=value pairs are passed to the pedal (e.g. Drive=0.8 Tone=0.5).
# Options via env vars:
#   RES=4:5            output format (16:9|4:5|1:1|9:16|WxH)       [default 4:5]
#   SPLIT=<seconds>    click-on point                             [default: half]
#   CLEAN_LABEL=Clean  first-segment label                        [default: Clean]
#   WET_LABEL=...      second-segment label              [default: .pedal's name]
#   GUESS=1            "guess the pedal" mode: hide the name behind "?" (blind)
set -euo pipefail

[ $# -lt 3 ] && { echo "usage: $0 INPUT.wav CIRCUIT.pedal OUT.mp4 [Knob=value ...]" >&2; exit 2; }

abspath() { case "$1" in /*) printf '%s' "$1";; *) printf '%s/%s' "$PWD" "$1";; esac; }
INPUT=$(abspath "$1"); PEDAL=$(abspath "$2"); OUT=$(abspath "$3"); shift 3
CONTROLS=("$@")   # remaining Knob=value pairs (may be empty)

HS="$(cd "$(dirname "$0")/.." && pwd)"
PK="$(cd "$HS/../pedalkernel" && pwd)"

RES="${RES:-4:5}"
CLEAN_LABEL="${CLEAN_LABEL:-Clean}"
# GUESS=1 → "guess the pedal" mode: hide the name behind "?" (fully blind).
if [ -n "${GUESS:-}" ]; then
  WET_LABEL="?"
else
  WET_LABEL="${WET_LABEL:-$(grep -oE '^[[:space:]]*(pedal|equipment)[[:space:]]+"[^"]+"' "$PEDAL" | head -1 | sed -E 's/.*"([^"]+)".*/\1/')}"
  [ -z "$WET_LABEL" ] && WET_LABEL="Pedal"
fi

# Default click-on point = half the input duration.
INDUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$INPUT")
SPLIT="${SPLIT:-$(awk "BEGIN{printf \"%.3f\", $INDUR/2}")}"

WET=$(mktemp /tmp/pedal_wet.XXXX.wav)
trap 'rm -f "$WET"' EXIT

echo "→ processing $(basename "$INPUT") through $(basename "$PEDAL") [${CONTROLS[*]-no overrides}]"
( cd "$PK" && cargo run --release -p pedalkernel --example process -- \
    "$PEDAL" "$INPUT" "$WET" ${CONTROLS[@]+"${CONTROLS[@]}"} )

echo "→ A/B click-on: ${CLEAN_LABEL} → ${WET_LABEL} @ ${RES}, split ${SPLIT}s"
"$HS/scripts/ab_clickon.sh" "$INPUT" "$CLEAN_LABEL" "$WET" "$WET_LABEL" "$OUT" "$SPLIT" "$RES"

echo "OK: $OUT"
