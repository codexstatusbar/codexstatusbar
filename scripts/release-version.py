#!/usr/bin/env python3
"""Print "<version> <build>" for a release tag; the tag is the one place a version is written."""
import re
import sys

# Canonical X.Y.Z only: no prefix, no suffix, no leading zeros, each part below 1000.
TAG = re.compile(r"(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})")


def parse(tag):
    match = TAG.fullmatch(tag)
    if not match:
        raise ValueError("Expected a release tag like 1.2.3")
    major, minor, patch = (int(part) for part in match.groups())
    # CFBundleVersion must be an integer that only grows: 0.0.26 -> 26, 0.1.0 -> 1000, 1.0.0 -> 1000000.
    return tag, major * 1_000_000 + minor * 1_000 + patch


if __name__ == "__main__":
    try:
        version, build = parse(sys.argv[1] if len(sys.argv) == 2 else "")
    except ValueError as error:
        print(error, file=sys.stderr)
        sys.exit(2)
    print(version, build)
