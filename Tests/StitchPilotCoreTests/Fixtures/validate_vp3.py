#!/usr/bin/env python3
"""
Independent VP3 validation oracle used only by StitchPilotCoreTests
(see TESTING.md). Parses a VP3 file with pyembroidery (a separate
implementation, MIT license) and prints a small JSON summary for the Swift
test to compare against its own StitchPlan.

Not part of the shipped app. Never invoked outside `swift test`.

Unlike DST/EXP/JEF, pyembroidery's VP3 reader converts its own internal
0.1mm/Y-up units back to real millimeters itself (dividing by 100, since
the on-disk header/position scale is 0.001mm/unit -- see VP3Format.swift's
own doc comment) before the values ever reach `pattern.stitches` here --
but the *stitch-delta* bytes it decodes are still pyembroidery's native
0.1mm/Y-up units, same as every other format. This script negates Y and
divides by 10 for those, exactly like every other format's own oracle
script, since that part of the convention is unchanged.
"""
import json
import sys

import pyembroidery


def main() -> None:
    if len(sys.argv) != 2:
        print("usage: validate_vp3.py <path.vp3>", file=sys.stderr)
        sys.exit(2)

    pattern = pyembroidery.read(sys.argv[1])

    stitch_count = 0
    color_changes = 0
    points = []
    min_x = min_y = float("inf")
    max_x = max_y = float("-inf")

    for x, y, command in pattern.stitches:
        mm_x = x / 10.0
        mm_y = -y / 10.0
        if command == pyembroidery.STITCH:
            stitch_count += 1
            points.append([mm_x, mm_y])
            min_x, max_x = min(min_x, mm_x), max(max_x, mm_x)
            min_y, max_y = min(min_y, mm_y), max(max_y, mm_y)
        elif command == pyembroidery.COLOR_CHANGE:
            color_changes += 1

    result = {
        "stitchCount": stitch_count,
        "colorChanges": color_changes,
        "boundingBox": {
            "minX": min_x if points else 0,
            "minY": min_y if points else 0,
            "maxX": max_x if points else 0,
            "maxY": max_y if points else 0,
        },
        "points": points,
    }
    print(json.dumps(result))


if __name__ == "__main__":
    main()
