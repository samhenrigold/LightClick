#!/usr/bin/env python3
"""Read-only source contract for guest list dispatch; never compiles, boots or connects to WindowServer."""
from pathlib import Path
import re

source = (Path(__file__).parents[1]/'probes/seamless-guest.c').read_text()
branch = re.search(r'if \(!strcmp\(command, "list"\)\) \{(.*?)\n    \}', source, re.S)
assert branch, 'list needs a guarded dispatch block'
assert re.search(r'if \(geteuid\(\) == 0 && !in_session\)\s*return run_in_console_session\(argc, argv, 1\);', branch[1]), \
    'root outside Aqua must reenter the console-user session once'
assert branch[1].index('run_in_console_session') < branch[1].index('return list_windows();'), \
    'window enumeration must follow the reentry guard'
assert branch[1].count('return list_windows();') == 1, 'non-root or --in-session must enumerate directly'
console = (Path(__file__).parents[1]/'probes/seamless-console.h').read_text()
assert 'arguments[n++] = "--in-session";' in console, 'console wrapper must stop recursive root reentry'
print('PASS guest list dispatch: root console-user reentry, direct in-session/non-root enumeration, recursion marker')
