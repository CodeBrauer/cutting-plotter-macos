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
SVG_USER_UNIT_DPI = 96.0      # what an SVG without physical units implies

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


def transform(text: str, deg: int, mirror: bool,
              scale: float = 1.0) -> tuple[str, dict]:
    # First pass: collect every point so we know the rotation and the offset.
    points: list[tuple[float, float]] = []
    for _, body in CMD.findall(text):
        points.extend(parse_points(body))
    if not points:
        raise SystemExit("No PU/PD coordinates found -- is this really HPGL?")

    # The SVG frame (x right, y down) and the machine frame (x feed, y growing
    # towards the left) have OPPOSITE handedness. Rotating alone therefore
    # always yields a mirror image, however correct the rotation itself is.
    # One axis must be flipped to compensate; -m cancels that flip, which is
    # exactly what heat transfer vinyl needs.
    flip = 1 if mirror else -1

    moved = [rotate(x, y, deg) for x, y in points]
    moved = [(x, flip * y) for x, y in moved]
    if scale != 1.0:
        moved = [(x * scale, y * scale) for x, y in moved]

    min_x = min(p[0] for p in moved)
    min_y = min(p[1] for p in moved)

    def fix(x: float, y: float) -> tuple[int, int]:
        nx, ny = rotate(x, y, deg)
        ny = flip * ny
        if scale != 1.0:
            nx, ny = nx * scale, ny * scale
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
    ap.add_argument("-w", "--fit-width", type=float, metavar="MM",
                    help="scale proportionally so the design measures this many "
                         "mm across the roll")
    ap.add_argument("-D", "--source-dpi", type=float, metavar="DPI",
                    help="DPI the design was authored at. Use this when the SVG "
                         "carries no physical size (width=\"100%%\"), so its "
                         "units would otherwise be read as "
                         f"{SVG_USER_UNIT_DPI:g} dpi and come out too large")
    args = ap.parse_args()

    if args.fit_width and args.source_dpi:
        print("x Use either --fit-width or --source-dpi, not both: they both "
              "set the scale.", file=sys.stderr)
        return 2

    with open(args.infile) as fh:
        text = fh.read()

    upm = args.units_per_mm
    out, st = transform(text, args.rotate, args.mirror)

    # An SVG without physical units is read as 96 dpi. If it was authored at a
    # different resolution, everything comes out scaled by that ratio.
    if args.source_dpi:
        factor = SVG_USER_UNIT_DPI / args.source_dpi
        out, st = transform(text, args.rotate, args.mirror, factor)
        print(f"-> Interpreted as {args.source_dpi:g} dpi "
              f"(x{factor:.4g} versus the {SVG_USER_UNIT_DPI:g} dpi default)",
              file=sys.stderr)

    # Scaling to a target width needs the unscaled size first.
    if args.fit_width:
        if st["y_max"] <= 0:
            print("x Cannot scale: the design has no width.", file=sys.stderr)
            return 2
        factor = (args.fit_width * upm) / st["y_max"]
        out, st = transform(text, args.rotate, args.mirror, factor)
        print(f"-> Scaled to {factor * 100:.1f}% of the exported size",
              file=sys.stderr)

    width_mm = st["y_max"] / upm    # across the roll = Y
    length_mm = st["x_max"] / upm   # along the roll  = X
    print(f"-> Crossfeed (Y): {width_mm:.1f} mm   Feed (X): {length_mm:.1f} mm",
          file=sys.stderr)

    if st["x_min"] < 0 or st["y_min"] < 0:
        print("x Negative coordinates after alignment -- this is a bug, "
              "please report it.", file=sys.stderr)
        return 2

    if st["y_max"] > args.max_crossfeed:
        max_mm = args.max_crossfeed / upm
        print(f"x ABORTED: {width_mm:.1f} mm across the roll exceeds the cutting "
              f"width of {max_mm:.0f} mm.", file=sys.stderr)
        # Only suggest rotating when rotating can actually help, i.e. when the
        # other dimension would fit. Suggesting it regardless sends people
        # round in circles.
        if length_mm <= max_mm:
            other = (args.rotate + 90) % 360
            print(f"  Turning it would fit: the other dimension is "
                  f"{length_mm:.1f} mm. Try -r {other}.", file=sys.stderr)
        else:
            fits = max_mm / width_mm * 100
            print(f"  Rotating would put {length_mm:.1f} mm across the roll "
                  f"instead, which is too wide as well.\n"
                  f"  Scale it down to at most {fits:.0f}% "
                  f"(-w {max_mm:.0f}), or resize it in your design tool.\n"
                  f"  Note the feed direction is not limited -- only the "
                  f"{max_mm:.0f} mm of carriage travel is.",
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
