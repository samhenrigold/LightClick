#!/usr/bin/env python3
"""Tiny offscreen repeat-mode contracts, independent PNG pixels, no guest/UI. Pass compiled host image-decode."""
import hashlib
import json
import math
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import zlib


def chunk(kind, data):
    return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind+data) & 0xffffffff)


def main():
    probe = Path(sys.argv[1]).resolve()
    pixels = bytes([255,0,0,255, 0,255,0,255, 0,0,255,255, 255,255,255,255])
    encoded = (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 2, 2, 8, 6, 0, 0, 0))
               + chunk(b'sRGB', b'\0') + chunk(b'IDAT', zlib.compress(b'\0'+pixels[:8]+b'\0'+pixels[8:])) + chunk(b'IEND', b''))
    with tempfile.TemporaryDirectory(prefix='lightclick-repeat-test-') as temporary:
        work = Path(temporary)
        image = work/'independent.png'
        image.write_bytes(encoded)
        def run(options, status=0):
            result = subprocess.run([str(probe), '--full-resolution', str(image), *options], capture_output=True, text=True, timeout=15)
            assert result.returncode == status, (options, result.returncode, result.stderr)
            return json.loads(result.stdout) if status == 0 else None
        normal = run(['--raw', str(work/'normal.rgba')])
        assert 'repeat_draw' not in normal
        for mode in ('srgb', 'source'):
            raw = work/(mode+'.rgba')
            report = run(['--repeat-draw-seconds', '1', '--timeout', '10', '--output-color-space', mode, '--raw', str(raw)])
            assert raw.read_bytes() == pixels == (work/'normal.rgba').read_bytes()
            assert report['input_sha256'] == hashlib.sha256(encoded).hexdigest()
            assert report['pixel_sha256'] == hashlib.sha256(pixels).hexdigest()
            repeat = report['repeat_draw']
            rows = repeat['per_iteration']
            assert 1 <= repeat['iterations'] == len(rows) <= 256
            assert repeat['requested_seconds'] == 1 and repeat['iteration_limit'] == 256
            assert repeat['termination'] in ('duration', 'iteration_limit')
            for row in rows:
                assert set(row) == {'source_create_ms', 'image_create_ms', 'forced_draw_ms'}
                assert all(isinstance(value, (float, int)) and math.isfinite(value) and value >= 0 for value in row.values())
            assert math.isclose(sum(row['forced_draw_ms'] for row in rows), report['timings_ms']['forced_draw'], abs_tol=1e-6)
            assert report['timings_ms']['forced_draw'] <= repeat['elapsed_seconds']*1000+.001
            assert report['timings_ms']['total_before_report'] >= repeat['elapsed_seconds']*1000
        for value in ('0', '31', '-1', '1.5', 'bad'):
            run(['--repeat-draw-seconds', value], 64)
        run(['--repeat-draw-seconds'], 64)
        run(['--repeat-draw-seconds', '1', '--repeat-draw-seconds', '1'], 64)
        run(['--repeat-draw-seconds', '30', '--timeout', '30'], 64)
    print('PASS default report preserved; bounded fresh-image repeat, exact independent pixels/hashes/timing shape; argument rejection')


if __name__ == '__main__':
    main()
