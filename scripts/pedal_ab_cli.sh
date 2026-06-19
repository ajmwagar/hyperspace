#!/bin/bash
# Interactive picker → A/B video.
# Choose a .pedal (one with a .pedalhw preset bank), a preset, and a DI track;
# renders an A/B click-on video via pedal_ab.sh using the preset's control values.
#
# Usage: scripts/pedal_ab_cli.sh
# Env:
#   DI_DIR=<dir>   where DI .wav tracks live                 [default: $PWD]
#   OUT=<file>     output path                  [default: <pedal>_<preset>_<di>.mp4]
#   DRY_RUN=1      print the pedal_ab.sh command instead of rendering
#   plus any pedal_ab.sh vars: GUESS, RES, SPLIT, CLEAN_LABEL, WET_LABEL
set -euo pipefail

HS="$(cd "$(dirname "$0")/.." && pwd)"
PRO="$(cd "$HS/../pedalkernel-pro" && pwd)"
DI_DIR="${DI_DIR:-$PWD}"

# --- 1) discover .pedal + .pedalhw pairs ---
HW_PATHS=(); HW_NAMES=()
while IFS= read -r hw; do
  b="${hw%.pedalhw}"
  [ -f "$b.pedal" ] || continue
  HW_PATHS+=("$hw"); HW_NAMES+=("$(basename "$b")")
done < <(find "$PRO" -name "*.pedalhw" ! -path "*/target/*" | sort)
[ ${#HW_PATHS[@]} -gt 0 ] || { echo "no .pedal+.pedalhw pairs under $PRO" >&2; exit 1; }

echo "Select a pedal:" >&2
select name in "${HW_NAMES[@]}"; do
  [ -n "${name:-}" ] && { HW="${HW_PATHS[$((REPLY-1))]}"; PEDAL="${HW%.pedalhw}.pedal"; break; }
done

# --- 2) presets from the .pedalhw ---
PRESET_NAMES=()
while IFS= read -r p; do PRESET_NAMES+=("$p"); done < <(python3 -c '
import tomllib, sys
d = tomllib.load(open(sys.argv[1], "rb"))
[print(p["name"]) for p in d.get("presets", [])]
' "$HW")
[ ${#PRESET_NAMES[@]} -gt 0 ] || { echo "no presets in $HW" >&2; exit 1; }

echo "Select a preset:" >&2
select preset in "${PRESET_NAMES[@]}"; do
  [ -n "${preset:-}" ] && break
done

# --- 3) DI track ---
DI_PATHS=(); DI_NAMES=()
while IFS= read -r w; do DI_PATHS+=("$w"); DI_NAMES+=("$(basename "$w")"); done \
  < <(find "$DI_DIR" -maxdepth 1 -iname "*.wav" | sort)
[ ${#DI_PATHS[@]} -gt 0 ] || { echo "no .wav DI tracks in $DI_DIR (set DI_DIR)" >&2; exit 1; }

echo "Select a DI track (from $DI_DIR):" >&2
select di in "${DI_NAMES[@]}"; do
  [ -n "${di:-}" ] && { DI="${DI_PATHS[$((REPLY-1))]}"; break; }
done

# --- 4) preset controls → "Knob=value ..." ---
CONTROLS=$(python3 -c '
import tomllib, sys
d = tomllib.load(open(sys.argv[1], "rb"))
p = next(x for x in d["presets"] if x["name"] == sys.argv[2])
print(" ".join(f"{k}={v}" for k, v in p.get("controls", {}).items()))
' "$HW" "$preset")

# --- 5) render ---
slug() { echo "$1" | tr ' /' '__' | tr -cd '[:alnum:]_.-'; }
OUT="${OUT:-$(slug "$name")_$(slug "$preset")_$(slug "${di%.wav}").mp4}"
echo "→ ${name} / ${preset} / ${di}  →  ${OUT}" >&2

if [ -n "${DRY_RUN:-}" ]; then
  echo "DRY_RUN: WET_LABEL='${WET_LABEL:-$preset}' pedal_ab.sh '$DI' '$PEDAL' '$OUT' $CONTROLS"
else
  WET_LABEL="${WET_LABEL:-$preset}" "$HS/scripts/pedal_ab.sh" "$DI" "$PEDAL" "$OUT" $CONTROLS
fi
