#!/usr/bin/env python3
"""Checks a guest tool would load on a guest, without booting it: its deployment target, that it has no chained fixups,
and that each import is exported by a library on the mounted guest disk.

    probes/check-guest-imports.py TOOL GUEST_ROOT
"""
import pathlib
import re
import subprocess
import sys


def run(*command):
    return subprocess.run(command, capture_output=True, text=True).stdout


def exports(library):
    # -j: re-exports print as `_x (indirect for _y)` otherwise.
    return set(run('xcrun', 'nm', '-gUj', '-arch', 'x86_64', str(library)).splitlines())


tool, root = sys.argv[1], sys.argv[2]
headers = run('xcrun', 'otool', '-l', tool)
minimum = re.search(r'LC_VERSION_MIN_MACOSX.*?version (\S+)', headers, re.S)
print(f'deployment_target {minimum.group(1) if minimum else "NOT 10.x"}')
print(f'chained_fixups {"yes (bad)" if "LC_DYLD_CHAINED_FIXUPS" in headers else "none"}')
seen = {}
stack = []
for line in run('xcrun', 'otool', '-L', tool).splitlines()[1:]:
    stack.append(line.split()[0])
missing_libraries = []
while stack:
    path = stack.pop()
    if path in seen:
        continue
    file = pathlib.Path(root + path)
    if not file.exists():
        missing_libraries.append(path)
        seen[path] = set()
        continue
    seen[path] = exports(file)
    # Umbrellas and libSystem, whose symbols live in what they re-export.
    stack += re.findall(r'cmd LC_REEXPORT_DYLIB.*?name (\S+)', run('xcrun', 'otool', '-arch', 'x86_64', '-l', str(file)), re.S)
exported = set().union(*seen.values())
imports = {line.split()[-1] for line in run('xcrun', 'nm', '-u', tool).splitlines() if line.strip()}
missing = sorted(imports - exported - {'dyld_stub_binder'})
print(f'libraries {len(seen)}, missing {missing_libraries or "none"}')
print(f'imports {len(imports)}, unresolved {missing or "none"}')
sys.exit(1 if missing or missing_libraries or not minimum else 0)
