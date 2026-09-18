#!/usr/bin/env bash
# plot -- send an SVG or HPGL file to a USB cutting plotter on macOS.
#
#   ./plot design.svg           convert, align and cut
#   ./plot -n design.svg        dry run: build and show it, send nothing
#   ./plot -r 270 design.svg    different rotation (0/90/180/270)
#   ./plot -m design.svg        mirrored, e.g. for heat transfer vinyl
#   ./plot -d vevor-sk720l …    pick a machine from devices/
#   ./plot ready.hpgl           send existing HPGL unchanged
#
set -euo pipefail

DRYRUN=0
MIRROR=""
ROTATE=""
DEVICE="${PLOTTER_DEVICE:-}"
QUEUE_OVERRIDE=""
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PATH="$HOME/.local/bin:$PATH"

usage() { sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while getopts ":nmr:d:q:h" opt; do
  case "$opt" in
    n) DRYRUN=1 ;;
    m) MIRROR="--mirror" ;;
    r) ROTATE="$OPTARG" ;;
    d) DEVICE="$OPTARG" ;;
    q) QUEUE_OVERRIDE="$OPTARG" ;;
    h) usage 0 ;;
    \?) echo "Unknown option: -$OPTARG" >&2; usage 1 ;;
  esac
done
shift $((OPTIND - 1))

[ $# -eq 1 ] || { echo "Error: expected exactly one input file." >&2; usage 1; }
IN="$1"
[ -f "$IN" ] || { echo "Error: '$IN' not found." >&2; exit 1; }

# Pick the machine. With a single machine installed there is nothing to choose.
if [ -z "$DEVICE" ]; then
  # macOS ships bash 3.2, so no mapfile/readarray here.
  FOUND=()
  while IFS= read -r d; do
    FOUND[${#FOUND[@]}]="$d"
  done < <(find "$DIR/devices" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort)
  if [ "${#FOUND[@]}" -eq 1 ]; then
    DEVICE="${FOUND[0]}"
  else
    echo "Error: several machines available, choose one with -d:" >&2
    printf '  %s\n' "${FOUND[@]}" >&2
    exit 1
  fi
fi

PROFILE="$DIR/devices/$DEVICE/profile.env"
CONFIG="$DIR/devices/$DEVICE/device.toml"
ALIGN="$DIR/lib/hpgl_align.py"
[ -f "$PROFILE" ] || { echo "Error: no profile at $PROFILE" >&2; exit 1; }
# shellcheck source=/dev/null
source "$PROFILE"
[ -n "$QUEUE_OVERRIDE" ] && CUPS_QUEUE="$QUEUE_OVERRIDE"
[ -z "$ROTATE" ] && ROTATE="$DEFAULT_ROTATE"

if [[ "$IN" == *.hpgl ]]; then
  # Existing HPGL is left untouched -- otherwise the axis tests would be useless.
  HPGL="$IN"
else
  command -v vpype >/dev/null || {
    echo "Error: vpype is missing. Install it with: uv tool install vpype" >&2; exit 1; }
  RAW="$(mktemp -t plotraw).hpgl"
  HPGL="$(mktemp -t plot).hpgl"
  trap 'rm -f "$RAW" "$HPGL"' EXIT

  echo "-> Converting $(basename "$IN") for $DEVICE_NAME …"
  # linemerge joins nearly touching paths, linesort shortens the travel moves.
  # --absolute is mandatory: this machine ignores PR;.
  vpype -c "$CONFIG" \
    read "$IN" \
    linemerge --tolerance 0.1mm \
    linesort \
    write --device "$VPYPE_DEVICE" --page-size raw --absolute --quiet "$RAW" >/dev/null

  # Rotate the axes, align to the origin, verify the cutting width.
  "$ALIGN" "$RAW" -r "$ROTATE" $MIRROR \
    --units-per-mm "$UNITS_PER_MM" \
    --max-crossfeed "$MAX_CROSSFEED_UNITS" \
    -o "$HPGL"
fi

BYTES=$(wc -c < "$HPGL" | tr -d ' ')
# grep exits 1 when there is no PD at all (a pure movement file). Without
# catching that, set -e would kill the script here without printing anything.
PENDOWN=$(grep -o 'PD' "$HPGL" | wc -l | tr -d ' ') || PENDOWN=0
if [ "$PENDOWN" -eq 0 ]; then
  echo "-> HPGL: ${BYTES} bytes, movement only (blade stays up)"
else
  echo "-> HPGL: ${BYTES} bytes, ${PENDOWN}x blade down"
fi

if [ "$DRYRUN" -eq 1 ]; then
  echo "-> Dry run, nothing sent. Contents:"
  echo
  fold -w 100 "$HPGL"
  echo
  exit 0
fi

lpstat -p "$CUPS_QUEUE" >/dev/null 2>&1 || {
  echo "Error: queue '$CUPS_QUEUE' not found. Run ./setup.sh first," >&2
  echo "       and check the plotter is powered on and connected." >&2
  exit 1; }

echo "-> Sending to $CUPS_QUEUE …"
lp -d "$CUPS_QUEUE" -o raw "$HPGL"
