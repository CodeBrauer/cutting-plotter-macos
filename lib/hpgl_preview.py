#!/usr/bin/env python3
"""Render HPGL as an SVG showing what will end up on the vinyl.

The point is orientation, not beauty. The machine's frame (X feed, Y growing
towards the left) is mapped to how the material looks lying in front of you,
so mirrored output is obvious before any material is used.
"""
from __future__ import annotations

import argparse
import re
import sys

CMD = re.compile(r"(PU|PD)([0-9,\s.-]*)", re.IGNORECASE)


def parse(text: str):
    """Yield (pen_down, [(x, y), ...]) in machine units."""
    pos = (0.0, 0.0)
    for cmd, body in CMD.findall(text):
        nums = [float(n) for n in re.findall(r"-?\d+(?:\.\d+)?", body)]
        pts = list(zip(nums[::2], nums[1::2]))
        if not pts:
            continue
        down = cmd.upper() == "PD"
        yield down, [pos] + pts
        pos = pts[-1]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("infile")
    ap.add_argument("-o", "--out", required=True)
    ap.add_argument("--units-per-mm", type=float, default=40.0)
    ap.add_argument("--travel", action="store_true",
                    help="also draw pen-up travel moves")
    args = ap.parse_args()

    with open(args.infile) as fh:
        segments = list(parse(fh.read()))
    if not segments:
        print("No HPGL commands found.", file=sys.stderr)
        return 1

    upm = args.units_per_mm
    # Viewer's frame: looking down at the material. Y runs to the left, so it
    # maps to decreasing screen x; X is the feed, running away from you, so it
    # maps to decreasing screen y.
    def to_screen(p):
        return (-p[1] / upm, -p[0] / upm)

    pts = [to_screen(p) for _, seg in segments for p in seg]
    xs, ys = [p[0] for p in pts], [p[1] for p in pts]
    minx, maxx, miny, maxy = min(xs), max(xs), min(ys), max(ys)
    w, h = maxx - minx or 1, maxy - miny or 1
    pad = max(w, h) * 0.04 + 2

    body = []
    for down, seg in segments:
        if not down and not args.travel:
            continue
        d = " ".join(("M" if i == 0 else "L") +
                     f"{to_screen(p)[0] - minx + pad:.2f},{to_screen(p)[1] - miny + pad:.2f}"
                     for i, p in enumerate(seg))
        style = ('fill="none" stroke="#c00" stroke-width="0.3" '
                 'stroke-dasharray="2,2"') if not down else \
                'fill="none" stroke="#000" stroke-width="0.5"'
        body.append(f'  <path d="{d}" {style}/>')

    svg = (f'<svg xmlns="http://www.w3.org/2000/svg" '
           f'width="{w + 2 * pad:.1f}mm" height="{h + 2 * pad:.1f}mm" '
           f'viewBox="0 0 {w + 2 * pad:.1f} {h + 2 * pad:.1f}">\n'
           f'  <rect width="100%" height="100%" fill="#fff"/>\n'
           + "\n".join(body) + "\n</svg>\n")

    with open(args.out, "w") as fh:
        fh.write(svg)
    print(f"-> Preview: {args.out}  ({w:.0f} x {h:.0f} mm as it will sit on the roll)",
          file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
