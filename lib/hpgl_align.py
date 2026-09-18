#!/usr/bin/env python3
"""Rotate, align and range-check HPGL for a roll-fed cutting plotter.

vpype emits HPGL in SVG orientation: X to the right, Y downwards. Roll-fed
cutters think differently -- X is the material feed, Y is the carriage axis,
which starts at zero on one side and grows towards the other.

This script rotates the geometry accordingly, moves it to the origin (so the
cut starts wherever the head currently sits) and verifies that nothing exceeds
the machine's cutting width. A crash into the end stop should fail on the
computer, not in the material.
"""
from __future__ import annotations

import argparse
import re
import sys

DEFAULT_UNITS_PER_MM = 40.0   # 1016 dpi
DEFAULT_MAX_CROSSFEED = 25200  # 630 mm at 40 units/mm

# A PU/PD command with its (possibly empty) coordinate list.
CMD = re.compile(r"(PU|PD)([0-9,\s.-]*)", re.IGNORECASE)


def rotate(x: float, y: float, deg: int) -> tuple[float, float]:
    """Rotate in SVG sense (x right, y down). A true rotation, never a mirror."""
    if deg == 0:
        return x, y
    if deg == 90:
        return y, -x
    if deg == 180:
        return -x, -y
    if deg == 270:
        return -y, x
    raise ValueError(f"rotation must be 0/90/180/270, got {deg}")


def parse_points(body: str) -> list[tuple[float, float]]:
    nums = [float(n) for n in re.findall(r"-?\d+(?:\.\d+)?", body)]
    if len(nums) % 2:
        raise ValueError(f"odd number of coordinates in '{body[:40]}'")
    return list(zip(nums[::2], nums[1::2]))


def transform(text: str, deg: int, mirror: bool) -> tuple[str, dict]:
    # First pass: collect every point so we know the rotation and the offset.
    points: list[tuple[float, float]] = []
    for _, body in CMD.findall(text):
        points.extend(parse_points(body))
    if not points:
        raise SystemExit("No PU/PD coordinates found -- is this really HPGL?")

    moved = [rotate(x, y, deg) for x, y in points]
    if mirror:
        moved = [(x, -y) for x, y in moved]

    min_x = min(p[0] for p in moved)
    min_y = min(p[1] for p in moved)

    def fix(x: float, y: float) -> tuple[int, int]:
        nx, ny = rotate(x, y, deg)
        if mirror:
            ny = -ny
        return round(nx - min_x), round(ny - min_y)

    # Second pass: rewrite the commands in place.
    def repl(m: re.Match) -> str:
        cmd, body = m.group(1).upper(), m.group(2)
        pts = parse_points(body)
        if not pts:
            return cmd
        return cmd + ",".join(f"{a},{b}" for a, b in (fix(x, y) for x, y in pts))

    out = CMD.sub(repl, text)

    fixed = [fix(x, y) for x, y in points]
    stats = {
        "x_max": max(p[0] for p in fixed),
        "y_max": max(p[1] for p in fixed),
        "x_min": min(p[0] for p in fixed),
        "y_min": min(p[1] for p in fixed),
    }
    return out, stats


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("infile")
    ap.add_argument("-o", "--out", help="output file (default: stdout)")
    ap.add_argument("-r", "--rotate", type=int, default=90, choices=[0, 90, 180, 270],
                    help="rotation in SVG sense (default: 90)")
    ap.add_argument("-m", "--mirror", action="store_true",
                    help="mirror as well, e.g. for heat transfer vinyl")
    ap.add_argument("--units-per-mm", type=float, default=DEFAULT_UNITS_PER_MM,
                    help=f"plotter units per mm (default: {DEFAULT_UNITS_PER_MM:g})")
    ap.add_argument("--max-crossfeed", type=int, default=DEFAULT_MAX_CROSSFEED,
                    help="cutting width in plotter units "
                         f"(default: {DEFAULT_MAX_CROSSFEED})")
    args = ap.parse_args()

    with open(args.infile) as fh:
        text = fh.read()

    out, st = transform(text, args.rotate, args.mirror)

    upm = args.units_per_mm
    width_mm = st["y_max"] / upm    # across the roll = Y
    length_mm = st["x_max"] / upm   # along the roll  = X
    print(f"-> Crossfeed (Y): {width_mm:.1f} mm   Feed (X): {length_mm:.1f} mm",
          file=sys.stderr)

    if st["x_min"] < 0 or st["y_min"] < 0:
        print("x Negative coordinates after alignment -- this is a bug, "
              "please report it.", file=sys.stderr)
        return 2

    if st["y_max"] > args.max_crossfeed:
        print(f"x ABORTED: {width_mm:.1f} mm crossfeed exceeds the cutting width "
              f"of {args.max_crossfeed / upm:.0f} mm.\n"
              f"  Make the design narrower, or rotate it with -r 0 or -r 180.",
              file=sys.stderr)
        return 1

    if args.out:
        with open(args.out, "w") as fh:
            fh.write(out)
    else:
        sys.stdout.write(out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
