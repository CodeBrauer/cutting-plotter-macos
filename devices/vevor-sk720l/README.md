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
| `tests/mirror-test-f.svg` | F reads correctly — **not mirrored** ✓ |

With `DEFAULT_ROTATE=90` the result comes out rotated 180° as seen from the
operator's seat, because the material is cut towards the back. That is a
rotation, not a mirror. Set `DEFAULT_ROTATE=270` in `profile.env` if you prefer
it readable from where you sit.

## Machine-side settings

Blade pressure (10–500 g), speed (10–800 mm/s) and blade offset are set on the
machine's control panel, not in software. Rounded or overcut corners mean the
blade offset needs adjusting, typically to 0.25 mm.
