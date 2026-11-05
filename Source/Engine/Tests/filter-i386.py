#!/usr/bin/env python3
"""Drops 16-bit shld and shrd lines whose masked count is above 16: undefined in the SDM."""
import re
import sys

for line in sys.stdin:
    m = re.match(r"sh[lr]dw\s.* C=([0-9a-f]+)", line)
    if m and int(m.group(1), 16) & 31 > 16:
        continue
    sys.stdout.write(line)
