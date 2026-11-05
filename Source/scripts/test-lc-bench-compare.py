#!/usr/bin/env python3
"""lc-bench-compare on synthetic results: cost and rate directions, missing tests, malformed input."""
import subprocess
import sys
import tempfile
from pathlib import Path

tool = Path(__file__).with_name('lc-bench-compare')


def compare(*contents):
    with tempfile.TemporaryDirectory(prefix='lc-bench-compare-') as temporary:
        paths = []
        for index, content in enumerate(contents):
            paths.append(Path(temporary, f'r{index}'))
            paths[-1].write_text(content)
        return subprocess.run([sys.executable, tool, *paths], capture_output=True, text=True)


result = compare('# header\nalu 2 ns/iter\nmemcpy 100 MB/s\ngone 1 ns/op\n',
                 '# header\nalu 4 ns/iter\nmemcpy 300 MB/s\nnew 0 ns/op\n')
assert result.returncode == 0, result.stderr
rows = {line.split()[0]: line.split() for line in result.stdout.splitlines()}
assert rows['alu'][-1] == '0.500x', rows
assert rows['memcpy'][-1] == '3.000x', rows
assert rows['gone'][-2:] == ['-', '-'], rows
assert rows['new'][2] == '-' and rows['new'][-1] == '-', rows
assert compare('alu 2 ns/iter\n', 'alu 2 ms/iter\n').stdout.splitlines()[1].split()[-1] == '-'
assert compare('alu fast ns/iter\n', 'alu 2 ns/iter\n').returncode != 0
assert compare('alu 2 ns/iter\n').returncode != 0
print('PASS')
