# Cutting Plotter on macOS — without SignMaster

Drive a USB vinyl cutting plotter from macOS using only free, open-source tools.
**No SignMaster, no paid software, no driver, no kext, no system extension.**

Most of these machines ship with [SignMaster](https://www.signmaster.software/),
which is Windows-only. The hardware itself speaks plain **HPGL** over a standard
USB printer interface — something macOS has supported natively for decades. This
repository provides the missing piece: a converter from SVG to correctly oriented
HPGL, plus a one-command setup.

Verified end-to-end on a **VEVOR SK-720L** (630 mm / 24.8" cutting width,
720 mm / 28.3" paper feed), driven from Affinity Designer artwork.

> **The single most important finding:** these plotters are **not** serial devices,
> even though the USB chip says otherwise. Every guide telling you to install a
> CH340 driver and pick a baud rate is wrong for this hardware.
> [See why](#why-the-usual-advice-fails).

---

## Contents

- [Why the usual advice fails](#why-the-usual-advice-fails)
- [How it works](#how-it-works)
- [Requirements](#requirements)
- [Setup](#setup)
- [Verify before you cut](#verify-before-you-cut)
- [Daily use](#daily-use)
- [Exporting from Affinity Designer / Illustrator / Inkscape](#exporting-from-your-design-tool)
- [Supported machines](#supported-machines)
- [Adding your machine](#adding-your-machine)
- [Troubleshooting](#troubleshooting)

---

## Why the usual advice fails

Search for "VEVOR plotter macOS" and you will be told to install a CH340 serial
driver, find `/dev/cu.wchusbserial*` and set a baud rate. On this hardware that
can never work. Here is what the machine actually reports:

```
idVendor 0x1A86 (wch.cn) · idProduct 0x5750
IOUSBHostInterface@0 · bInterfaceClass 7 · SubClass 1 · Protocol 2
```

**Interface class 7 is the USB printer class.** The device calls itself
"USB2.0 To Serial Port" and uses a WCH chip, which is why everyone assumes it is
a serial port — but it never enumerates as one. A CH340 driver binds to
vendor-class interfaces (class 255), not to class 7. There will never be a
`/dev/cu.*` entry, and baud rate is meaningless.

Check your own machine:

```bash
ioreg -rc IOUSBHostDevice -w0 | grep -i "USB Product Name"
ioreg -w0 -l -r -n "<name from above>" | grep bInterfaceClass
```

The good news: the USB printer class needs **no driver at all** on macOS.

**Second finding:** the SK-720L **ignores `PR;`** (relative HPGL coordinates). It
then reads those values as absolute positions, ends up with negative coordinates
and drives the carriage into the end stop — the display shows
`On-line right error >>>`. All output here is therefore absolute (`PA`).

## How it works

```
SVG  ──vpype──>  HPGL  ──hpgl_align.py──>  aligned HPGL  ──CUPS raw queue──>  plotter
      optimise        rotate axes,                       no driver needed
      paths           align to origin,
                      check cutting width
```

[vpype](https://github.com/abey79/vpype) converts and optimises the paths
(`linemerge` joins nearly touching paths, `linesort` shortens travel moves).
[`lib/hpgl_align.py`](lib/hpgl_align.py) then maps SVG orientation onto the
machine's axes, aligns the job to the origin and **refuses jobs wider than the
cutting width before anything is sent**.

Axis handling deliberately lives in a readable Python script rather than buried
in device-config subtleties. It prints the real dimensions of every job in
millimetres before you commit material to it.

## Requirements

- macOS (tested on macOS 26, Apple Silicon; nothing here is version-specific)
- [uv](https://docs.astral.sh/uv/) or pipx, to install vpype
- A design tool that exports SVG (Affinity Designer, Illustrator, Inkscape, Figma)

Inkscape is **not** required. Its built-in HPGL export is unreliable when called
from the command line, and vpype does the job better.

## Setup

**1. Install vpype**

```bash
uv tool install vpype
```

<details>
<summary>No uv? Use pipx or pip instead</summary>

```bash
pipx install vpype
# or, into a virtualenv you manage yourself:
python3 -m pip install vpype
```
</details>

**2. Connect and power on the plotter**

**3. Create the print queue**

```bash
git clone https://github.com/CodeBrauer/cutting-plotter-macos.git
cd cutting-plotter-macos
./setup.sh
```

This finds the machine, creates a **raw** CUPS queue that passes HPGL through
untouched, and prints what it did. It is safe to re-run.

Your user must be in the `_lpadmin` group, which admin accounts are by default:

```bash
dseditgroup -o checkmember -m "$(id -un)" _lpadmin
```

If the plotter is not found, list what CUPS can see with `./setup.sh -l`.

## Verify before you cut

**Do this before trusting the machine with material.** Both files move the head
with the **blade up**, so you can run them with nothing loaded.

```bash
./plot tests/axis-y-crossfeed.hpgl   # carriage should travel 100 mm across and back
./plot tests/axis-x-feed.hpgl        # rollers should feed 100 mm and back
```

If the wrong mechanism moves, your machine's axes are swapped relative to this
profile — see [Adding your machine](#adding-your-machine).

Then check scale and mirroring on scrap vinyl:

```bash
./plot tests/calibration-100x50mm.svg   # measure: 100 x 50 mm, 10 mm inner square
./plot tests/mirror-test-f.svg          # an "F" -- must read correctly, not mirrored
```

The "F" matters. A rectangle with a corner mark **cannot** reveal mirroring,
because every corner is reachable by rotation alone. Mirrored text is only
obvious once you have wasted material on it.

## Daily use

```bash
./plot design.svg          # convert, align and cut
./plot -n design.svg       # dry run: show dimensions and HPGL, send nothing
./plot -m design.svg       # mirrored, for heat transfer / iron-on vinyl
./plot -r 270 design.svg   # rotate: 0, 90 (default), 180, 270
./plot ready.hpgl          # send existing HPGL untouched
```

Every job reports its real size first:

```
-> Crossfeed (Y): 100.0 mm   Feed (X): 50.0 mm
-> HPGL: 109 bytes, 2x blade down
```

Anything wider than the cutting width **aborts before sending**. A crash into the
end stop should fail on your computer, not in your material.

`-n` costs nothing and catches scaling mistakes before they become waste.

## Exporting from your design tool

- Export as **plain SVG**
- Keep the document width within the **cutting width** (630 mm on the SK-720L —
  that is narrower than the 720 mm material feed)
- **Convert text to curves/outlines.** Only paths are processed, fonts are not
- Only **outlines** are cut; fills are ignored. Anything you want cut must be a
  path. In Affinity Designer: *Right click → Convert to Curves*

Whatever is wide in your design ends up across the roll; the height runs in the
feed direction. Use `-r` if you want it the other way round.

## Supported machines

| Machine | Cutting width | Status | Profile |
|---|---|---|---|
| VEVOR SK-720L | 630 mm / 24.8" | Verified on hardware | [`devices/vevor-sk720l`](devices/vevor-sk720l) |
| VEVOR SK-870L | 870 mm | Shares the manual and firmware, untested | same profile |

The SK-720L is sold as *"VEVOR Vinyl Cutter Machine / Schneideplotter, 720mm,
SignMaster"*:
[product page (EN/EU)](https://eur.vevor.com/vinyl-cutter-c_11151/vevor-vinyl-cutter-machine-cutting-plotter-28in-bluetooth-signmaster-kit-bundle-p_010958201479)
· [Produktseite (DE)](https://www.vevor.de/schneideplotter-c_11151/vevor-schneideplotter-plottermaschine-630mm-folienschneider-signmaster-software-p_010958201479).
VEVOR lists its languages as *DM/PL, HP/GL*, which is what makes this approach work.

The manufacturer's manual is included at
[`devices/vevor-sk720l/manual/`](devices/vevor-sk720l/manual/) for convenience.

**Other HPGL cutters are likely to work.** Roland-compatible machines, and clones
sold under names like Redsail, Saga, Creation or PCUT, use the same command set.
If yours enumerates as a USB printer, you are most of the way there.

## Adding your machine

Pull requests welcome — see [CONTRIBUTING.md](CONTRIBUTING.md). In short: copy
[`devices/vevor-sk720l/`](devices/vevor-sk720l), adjust `profile.env` for your
cutting width and USB identifier, and run the verification tests above.

## Troubleshooting

**Nothing happens / queue stuck**

```bash
lpstat -p VEVOR_SK720L      # queue status
lpstat -o VEVOR_SK720L      # pending jobs
cancel -a VEVOR_SK720L      # discard all jobs
cupsenable VEVOR_SK720L     # re-enable after an error
```

**`On-line right error >>>` or similar end-stop error.** The job tried to leave
the cutting area. Reset the machine, set the origin again, **and clear the CUPS
queue** — otherwise the rest of the old job continues. If you sent hand-written
HPGL, check it uses `PA` (absolute), not `PR`.

**Plotter not listed by `./setup.sh -l`.** Confirm macOS sees the hardware at all:

```bash
ioreg -rc IOUSBHostDevice -w0 | grep -i "USB Product Name"
```

If it does not appear, it is a cable, hub or power issue — not a driver issue.
Try a direct port rather than a hub.

**Cut dimensions are wrong.** Re-run `tests/calibration-100x50mm.svg` and measure
both axes. If both are off by the same factor, adjust `UNITS_PER_MM` in the
machine's `profile.env`.

**Corners rounded or overcut.** Not a software problem — that is the blade offset,
set on the machine (typically 0.25 mm).

**Cut too deep or too shallow.** Blade pressure, speed and blade offset are all
set **on the machine**, not in software. Start low on new material and increase
until the vinyl is cut through but the backing paper is untouched.

## Licence

[MIT](LICENSE). The included manufacturer manual is VEVOR's own document,
redistributed for convenience. It carries the English section only and is
recompressed for size — 19 MB and 168 multilingual pages down to 1.5 MB and 20
pages, with searchable text intact.
