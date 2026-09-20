#!/usr/bin/env bash
# plot -- send an SVG or HPGL file to a USB cutting plotter on macOS.
#
#   ./plot design.svg           convert, align and cut
#   ./plot -n design.svg        dry run: build and show it, send nothing
#   ./plot -r 270 design.svg    different rotation (0/90/180/270)
#   ./plot -w 600 design.svg    scale to 600 mm across the roll
#   ./plot -D 300 design.svg    SVG has no physical size, authored at 300 dpi
#   ./plot -p design.svg        write preview.svg showing what lands on the vinyl
#   ./plot -s 0 design.svg      keep every point (default simplifies to 0.05mm)
#   ./plot -v 30 design.svg     set cutting speed via VS
#   ./plot -P design.svg        skip the blade-alignment cut at the origin
#   ./plot -m design.svg        mirrored, e.g. for heat transfer vinyl
#   ./plot -d vevor-sk720l …    pick a machine from devices/
#   ./plot ready.hpgl           send existing HPGL unchanged
#
set -euo pipefail

DRYRUN=0
MIRROR=""
ROTATE=""
FITWIDTH=""
SRCDPI=""
PREVIEW=0
VELOCITY=""
NOPRECUT=""
# Design tools often emit curves far finer than a blade can follow. Simplifying
# below the machine's accuracy cuts the file size by an order of magnitude with
# no visible difference -- and oversized jobs are what stalls the USB transfer
# and disables the queue.
SIMPLIFY="0.05mm"
DEVICE="${PLOTTER_DEVICE:-}"
QUEUE_OVERRIDE=""
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PATH="$HOME/.local/bin:$PATH"

usage() { sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while getopts ":nmpPr:w:D:s:v:d:q:h" opt; do
  case "$opt" in
    n) DRYRUN=1 ;;
    p) PREVIEW=1 ;;
    P) NOPRECUT="--no-precut" ;;
    v) VELOCITY="--velocity $OPTARG" ;;
    s) SIMPLIFY="$OPTARG" ;;
    m) MIRROR="--mirror" ;;
    r) ROTATE="$OPTARG" ;;
    w) FITWIDTH="--fit-width $OPTARG" ;;
    D) SRCDPI="--source-dpi $OPTARG" ;;
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
PREVIEWER="$DIR/lib/hpgl_preview.py"
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
  SIMPLIFY_STEP=""
  case "$SIMPLIFY" in
    0|0mm|none|"") ;;                                    # explicitly disabled
    *) SIMPLIFY_STEP="linesimplify --tolerance $SIMPLIFY" ;;
  esac

  # shellcheck disable=SC2086
  vpype -c "$CONFIG" \
    read "$IN" \
    linemerge --tolerance 0.1mm \
    $SIMPLIFY_STEP \
    linesort \
    write --device "$VPYPE_DEVICE" --page-size raw --absolute --quiet "$RAW" >/dev/null

  # Rotate the axes, align to the origin, verify the cutting width.
  "$ALIGN" "$RAW" -r "$ROTATE" $MIRROR $FITWIDTH $SRCDPI $VELOCITY $NOPRECUT \
    --units-per-mm "$UNITS_PER_MM" \
    --max-crossfeed "$MAX_CROSSFEED_UNITS" \
    -o "$HPGL"
fi

if [ "$PREVIEW" -eq 1 ]; then
  PREVIEW_OUT="./$(basename "${IN%.*}")-preview.svg"
  "$PREVIEWER" "$HPGL" -o "$PREVIEW_OUT" --units-per-mm "$UNITS_PER_MM"
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

# CUPS has two independent states: it can ACCEPT jobs while being DISABLED for
# processing them. `lp` reports success in that case and the job simply sits in
# the queue -- indistinguishable from the plotter ignoring you.
#
# Read the state as a number rather than parsing lpstat: CUPS ignores LC_ALL,
# so its wording follows the system language and cannot be matched reliably.
# printer-state is IPP: 3 = idle, 4 = processing, 5 = stopped/disabled.
QOPTS="$(lpoptions -p "$CUPS_QUEUE" 2>/dev/null || true)"

if [ -z "$QOPTS" ]; then
  echo "Error: queue '$CUPS_QUEUE' not found. Run ./setup.sh first," >&2
  echo "       and check the plotter is powered on and connected." >&2
  exit 1
fi

QSTATE_NUM="$(echo "$QOPTS" | tr ' ' '\n' | sed -n 's/^printer-state=//p')"
QREASON="$(echo "$QOPTS" | tr ' ' '\n' | sed -n 's/^printer-state-reasons=//p')"

if [ "$QSTATE_NUM" = "5" ]; then
    echo "Error: queue '$CUPS_QUEUE' is STOPPED -- nothing would be sent." >&2
    echo "       Reason: ${QREASON:-unknown}" >&2
    echo >&2
    echo "  CUPS disables a queue when a transfer fails. Any job sent since" >&2
    echo "  then is still waiting. Clear them and re-enable:" >&2
    echo >&2
    echo "    cancel -a $CUPS_QUEUE && cupsenable $CUPS_QUEUE" >&2
    echo >&2
    echo "  Clear the queue BEFORE re-enabling, or the backlog starts cutting" >&2
    echo "  the moment the queue comes back." >&2
    exit 1
fi

PENDING=$(lpstat -o "$CUPS_QUEUE" 2>/dev/null | wc -l | tr -d ' ')
if [ "$PENDING" -gt 0 ]; then
  echo "Warning: $PENDING job(s) already waiting in $CUPS_QUEUE." >&2
  echo "         Yours will run after those. 'cancel -a $CUPS_QUEUE' drops them." >&2
fi

echo "-> Sending to $CUPS_QUEUE …"
SUBMIT="$(lp -d "$CUPS_QUEUE" -o raw "$HPGL" 2>&1)"
echo "$SUBMIT"
# lp is localised and CUPS ignores LC_ALL, so the wording cannot be relied on.
# It also prints the id with an en dash while lpstat uses a hyphen. Take the
# number that follows the queue name and match on that alone.
JOB_NUM="$(echo "$SUBMIT" | sed -n "s/.*${CUPS_QUEUE}[^0-9]*\([0-9][0-9]*\).*/\1/p" | head -1)"

# Confirm the job actually leaves the queue. A failed transfer shows up within
# seconds as the queue being disabled; without this check the script would
# report success for a job that never reached the machine.
if [ -n "$JOB_NUM" ]; then
  WAITED=0
  while [ "$WAITED" -lt 20 ]; do
    if ! lpstat -o "$CUPS_QUEUE" 2>/dev/null \
         | grep -qE "^${CUPS_QUEUE}[^0-9]*${JOB_NUM}[[:space:]]"; then
      echo "-> Transferred to the plotter."
      exit 0
    fi
    NOWSTATE="$(lpoptions -p "$CUPS_QUEUE" 2>/dev/null | tr ' ' '\n' \
                | sed -n 's/^printer-state=//p')"
    if [ "$NOWSTATE" = "5" ]; then
        echo >&2
        echo "Error: the transfer FAILED and CUPS disabled the queue." >&2
        echo "       Nothing was cut. Recover with:" >&2
        echo >&2
        echo "    cancel -a $CUPS_QUEUE && cupsenable $CUPS_QUEUE" >&2
        echo >&2
        echo "  A very large job is the usual cause. Check the size reported" >&2
        echo "  above -- anything past a few hundred KB tends to stall. The" >&2
        echo "  default -s 0.05mm simplification keeps jobs small; if you" >&2
        echo "  disabled it with -s 0, that is the first thing to undo." >&2
        exit 1
    fi
    sleep 1
    WAITED=$((WAITED + 1))
  done
  echo "-> Still transferring after ${WAITED}s. Large job, this is normal."
  echo "   Watch it with: lpstat -o $CUPS_QUEUE"
fi
