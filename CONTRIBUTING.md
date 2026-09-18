# Contributing

Adding another machine is the most useful contribution. The tooling is generic —
only the machine profile is specific.

## Adding a machine

**1. Confirm it is a USB printer-class device**

```bash
ioreg -rc IOUSBHostDevice -w0 | grep -i "USB Product Name"
ioreg -w0 -l -r -n "<name from above>" | grep bInterfaceClass
```

`bInterfaceClass = 7` means you are in business. Also check CUPS sees it:

```bash
./setup.sh -l
```

If it enumerates as a genuine serial device instead, this repository is not the
right tool — you want something that talks to `/dev/cu.*`.

**2. Copy an existing profile**

```bash
cp -r devices/vevor-sk720l devices/<vendor>-<model>
rm -rf devices/<vendor>-<model>/manual   # unless you have one to include
```

Edit `profile.env`:

| Variable | Meaning |
|---|---|
| `DEVICE_NAME` | Human-readable name shown in messages |
| `CUPS_QUEUE` | Queue name `setup.sh` creates |
| `USB_URI_MATCH` | Substring to find it in `lpinfo -v` |
| `VPYPE_DEVICE` | Section name inside `device.toml` |
| `UNITS_PER_MM` | Plotter units per millimetre (often 40 = 1016 dpi) |
| `MAX_CROSSFEED_UNITS` | Cutting width × `UNITS_PER_MM` |
| `DEFAULT_ROTATE` | 0/90/180/270 to match the machine's axes |

Rename the device section in `device.toml` to match `VPYPE_DEVICE`, and set
`plotter_unit_length` to `1 / UNITS_PER_MM` millimetres.

**3. Verify on the actual machine**

Please do not submit a profile you have not run. In this order:

```bash
./setup.sh -d <vendor>-<model>
./plot -d <vendor>-<model> tests/axis-y-crossfeed.hpgl   # carriage across?
./plot -d <vendor>-<model> tests/axis-x-feed.hpgl        # rollers feeding?
./plot -d <vendor>-<model> tests/calibration-100x50mm.svg
./plot -d <vendor>-<model> tests/mirror-test-f.svg
```

The first two keep the blade up and need no material. If the wrong mechanism
moves, swap the meaning of the axes via `DEFAULT_ROTATE`.

Measure the calibration rectangle on **both** axes, and check the F is not
mirrored. A rectangle alone cannot prove that — every corner of it is reachable
by rotation.

**4. Document what you measured**

Add a `README.md` to your device directory following
[`devices/vevor-sk720l/README.md`](devices/vevor-sk720l/README.md): USB identity,
coordinate system, any firmware quirks, and a verification log with real
measurements. Quirks are the valuable part — the `PR;` issue on the SK-720L
would have cost days to rediscover.

Add a row to the table in the main README.

## Known quirks worth checking

- **`PR;` ignored** — relative coordinates read as absolute, carriage hits the
  end stop. Symptom: an end-stop error partway through a job that starts fine.
- **Axes swapped** — feed and carriage reversed compared to the profile.
- **Origin on the other side** — some machines home left rather than right.
- **Different resolution** — not every machine is 1016 dpi.

## Code style

Shell scripts must work with **bash 3.2**, the version macOS ships. No `mapfile`,
no associative arrays, no `${var^^}`. Check with `bash -n` before submitting.

Python targets the system `python3` with no third-party imports.

Comments explain *why*, not *what* — especially where a workaround exists because
of a firmware quirk.
