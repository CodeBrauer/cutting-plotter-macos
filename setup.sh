#!/usr/bin/env bash
# setup.sh -- create the CUPS raw queue for a USB cutting plotter on macOS.
#
#   ./setup.sh                  set up the only machine in devices/
#   ./setup.sh -d vevor-sk720l  set up a specific one
#   ./setup.sh -l               just list USB devices CUPS can see
#
# No driver, kext or system extension is installed. These plotters present
# themselves as USB printer-class devices, which macOS supports natively.
set -euo pipefail

DEVICE="${PLOTTER_DEVICE:-}"
LIST_ONLY=0
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

while getopts ":d:lh" opt; do
  case "$opt" in
    d) DEVICE="$OPTARG" ;;
    l) LIST_ONLY=1 ;;
    h) sed -n '2,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    \?) echo "Unknown option: -$OPTARG" >&2; exit 1 ;;
  esac
done

echo "== USB devices visible to CUPS =="
USB_LIST="$(/usr/sbin/lpinfo -v 2>/dev/null | grep '^direct usb://' || true)"
if [ -z "$USB_LIST" ]; then
  echo "  (none)"
  echo
  echo "The plotter is not visible. Check that it is powered on and connected," >&2
  echo "then confirm macOS sees the hardware at all:" >&2
  echo "  ioreg -rc IOUSBHostDevice -w0 | grep -i 'USB Product Name'" >&2
  exit 1
fi
echo "$USB_LIST" | sed 's/^/  /'
echo

[ "$LIST_ONLY" -eq 1 ] && exit 0

# Pick the machine profile.
if [ -z "$DEVICE" ]; then
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
[ -f "$PROFILE" ] || { echo "Error: no profile at $PROFILE" >&2; exit 1; }
# shellcheck source=/dev/null
source "$PROFILE"

echo "== Machine: $DEVICE_NAME =="

URI="$(echo "$USB_LIST" | grep -i "$USB_URI_MATCH" | head -1 | awk '{print $2}' || true)"
if [ -z "$URI" ]; then
  echo "Error: no USB device matching '$USB_URI_MATCH' found." >&2
  echo "If your machine appears in the list above under a different name," >&2
  echo "adjust USB_URI_MATCH in $PROFILE." >&2
  exit 1
fi
echo "  URI:   $URI"
echo "  Queue: $CUPS_QUEUE"
echo

if lpstat -p "$CUPS_QUEUE" >/dev/null 2>&1; then
  echo "Queue '$CUPS_QUEUE' already exists, updating its URI."
fi

# A raw queue passes HPGL through untouched. No PPD, no driver.
lpadmin -p "$CUPS_QUEUE" -E -v "$URI" \
  -D "$DEVICE_NAME (HPGL raw)" \
  -o printer-is-shared=false

echo "✓ Queue ready:"
lpstat -p "$CUPS_QUEUE"
echo
echo "Next: verify the axes before cutting anything."
echo "  ./plot tests/axis-y-crossfeed.hpgl   # carriage moves 100 mm across"
echo "  ./plot tests/axis-x-feed.hpgl        # rollers feed 100 mm"
echo "Both keep the blade up, so you can run them without material loaded."
