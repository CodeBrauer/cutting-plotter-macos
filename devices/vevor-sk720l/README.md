# VEVOR SK-720L

28" / 720 mm roll-fed vinyl cutting plotter, 630 mm cutting width. Sold with
SignMaster (Windows only). The SK-870L shares the same manual and firmware.

- [Product page (EN/EU)](https://eur.vevor.com/vinyl-cutter-c_11151/vevor-vinyl-cutter-machine-cutting-plotter-28in-bluetooth-signmaster-kit-bundle-p_010958201479)
- [Produktseite (DE)](https://www.vevor.de/schneideplotter-c_11151/vevor-schneideplotter-plottermaschine-630mm-folienschneider-signmaster-software-p_010958201479)
- [Manufacturer's manual](manual/vevor-sk720l-sk870l-manual-en.pdf) (SK-720L + SK-870L,
  English section, 20 pages)

## USB identity

```
idVendor 0x1A86 (wch.cn) · idProduct 0x5750 · e.g. serial WCH454545TS2
IOUSBHostInterface@0 · bInterfaceClass 7 · SubClass 1 · Protocol 2
```

Class 7 is the **USB printer class**, not a serial port. There is no
`/dev/cu.wchusbserial*` and no CH340 driver will create one. VEVOR's spec sheet
lists the control mode as "USB & COM", which is where the confusion originates.

The CH341 driver bundled with the vendor software covers `VID_1A86` with PIDs
`7523`, `5523`, `7522` and `E523` — **not `5750`**, which is what this machine
reports. Even the manufacturer's own serial driver does not apply to it as
shipped.

## Coordinate system (measured, not assumed)

| | |
|---|---|
| Origin | carriage fully to the right; set on the machine |
| **X** | material feed |
| **Y** | carriage across the roll, 0 = right, growing **to the left**, max 25200 = 630 mm |
| Scale | 1016 dpi = **40 units/mm**, 1 unit = 0.025 mm |

## Quirk: `PR;` is ignored

The machine does not honour `PR;` (relative coordinates). It reads the following
values as absolute positions instead, which produces negative coordinates and
drives the carriage into the end stop (`On-line right error >>>`).

All output must be absolute (`PA`). `plot` passes `--absolute` to vpype for this
reason. Confirmed by experiment: identical geometry crashes with `PR` and runs
cleanly with `PA`.

## Verification log

Measured on the machine, 2026-09-18:

| Check | Result |
|---|---|
| `tests/axis-y-crossfeed.hpgl` | carriage moved ~100 mm across ✓ |
| `tests/axis-x-feed.hpgl` | rollers fed ~100 mm ✓ |
| Long edge of calibration rectangle | 100 mm ✓ |
| Short edge (feed direction) | 50 mm ✓ |
| Inner square position | 85–95 mm from origin, matching the HPGL ✓ |
| `tests/mirror-test-f.svg` | F reads correctly, not mirrored ✓ |

### Handedness

The two coordinate frames have **opposite handedness**:

| Frame | horizontal | vertical | determinant |
|---|---|---|---|
| SVG on screen | x to the right | y **downwards** | −1 |
| Vinyl seen from above | Y to the **left** | X feed | +1 |

A rotation alone therefore yields a mirror image, however correct the rotation
itself is. One axis is flipped to compensate — `flip` in `hpgl_align.py`. `-m`
cancels that flip, which is what heat transfer vinyl needs.

A mirrored F and a rotated F look alike at a glance, so check orientation with
`./plot -p` rather than on the machine.

With `DEFAULT_ROTATE=90` the result sits rotated 180° as seen from the
operator's seat, because material is cut towards the back. Set
`DEFAULT_ROTATE=270` in `profile.env` to have it read upright from where you
sit — verified with the preview.

## Machine-side settings

Blade pressure (10–500 g) and blade offset are set on the machine's control
panel. There is no HPGL command for either, so software cannot change them.
Rounded or overcut corners mean the blade offset needs adjusting, typically to
0.25 mm.

Speed (10–800 mm/s) can be set from software with `VS`, which `plot -v N` emits.
The unit `VS` expects is not documented for this machine — set a value and
compare against the panel before relying on it.

Each job starts with `PU0,0;PD1,1;PU0,0;`, a hairline cut at the origin that
turns the drag knife into the direction of travel before real cutting starts.
`plot -P` skips it.
