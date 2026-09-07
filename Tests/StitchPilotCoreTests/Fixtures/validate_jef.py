#!/usr/bin/env python3
"""
Independent JEF validation oracle used only by StitchPilotCoreTests
(see TESTING.md). Parses a JEF file with pyembroidery (a separate
implementation, MIT license) and prints a small JSON summary for the Swift
test to compare against its own StitchPlan.

Not part of the shipped app. Never invoked outside `swift test`.

pyembroidery's internal Y convention is the negation of StitchPilot's
(see JEFFormat.swift's "Coordinate convention" note) -- this script negates
Y back before reporting, so the Swift side can compare directly without
knowing about pyembroidery's convention.
"""
import json
import sys

import pyembroidery


def main() -> None:
    if len(sys.argv) != 2:
        print("usage: validate_jef.py <path.jef>", file=sys.stderr)
        sys.exit(2)

    pattern = pyembroidery.read(sys.argv[1])

    stitch_count = 0
    color_changes = 0
    points = []
    min_x = min_y = float("inf")
    max_x = max_y = float("-inf")

    for x, y, command in pattern.stitches:
        # pyembroidery stores tenths of a millimeter, Y-up internally.
        mm_x = x / 10.0
        mm_y = -y / 10.0  # negate back to StitchPilot's Y-down convention
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
