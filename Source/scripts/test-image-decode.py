#!/usr/bin/env python3
"""Check a built image-decode probe without a guest, UI, or third-party image library.

    python3 scripts/test-image-decode.py /absolute/path/to/image-decode

The PNG fixture is independently encoded here. Its full expected RGBA bytes are
fixed, so row reversal, channel swaps and missing premultiplication cannot pass
by merely agreeing with the probe's own hash.
"""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import tempfile
import zlib


def chunk(kind, data):
    return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))


def fixture():
    # Top: opaque red, half-transparent green. Bottom: opaque blue, fully transparent white.
    scanlines = bytes([0, 255, 0, 0, 255, 0, 255, 0, 128,
                      0, 0, 0, 255, 255, 255, 255, 255, 0])
    return (b'\x89PNG\r\n\x1a\n'
            + chunk(b'IHDR', struct.pack('>IIBBBBB', 2, 2, 8, 6, 0, 0, 0))
            + chunk(b'sRGB', b'\0')
            + chunk(b'IDAT', zlib.compress(scanlines))
            + chunk(b'IEND', b''))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('probe', type=Path)
    args = parser.parse_args()
    probe = args.probe.resolve()
    if not probe.is_file():
        parser.error(f'no built probe at {probe}')
    with tempfile.TemporaryDirectory(prefix='lightclick-image-decode-check-') as temporary:
        work = Path(temporary)
        source = work/'known.png'
        source.write_bytes(fixture())
        expected = bytes([255, 0, 0, 255, 0, 128, 0, 128,
                          0, 0, 255, 255, 0, 0, 0, 0])

        def run(*options, expected_exit=0):
            result = subprocess.run([str(probe), '--full-resolution', str(source), *options],
                                    capture_output=True, text=True, timeout=10)
            if result.returncode != expected_exit:
                raise AssertionError(f'exit {result.returncode}, expected {expected_exit}: {result.stderr}')
            return result

        raw = work/'known.rgba'
        report = json.loads(run('--raw', str(raw)).stdout)
        got = raw.read_bytes()
        if got != expected:
            raise AssertionError(f'RGBA bytes differ: got {list(got)}, expected {list(expected)}')
        for key, wanted in {'width': 2, 'height': 2, 'row_bytes': 8, 'output_bytes': 16,
                            'row_order': 'top-to-bottom', 'pixel_format': 'RGBA8-premultiplied',
                            'output_color_space': 'kCGColorSpaceSRGB', 'item_index': 0,
                            'item_count': 1, 'orientation_applied': False,
                            'pixel_sha256': hashlib.sha256(expected).hexdigest(),
                            'input_sha256': hashlib.sha256(source.read_bytes()).hexdigest()}.items():
            if report.get(key) != wanted:
                raise AssertionError(f'{key}: {report.get(key)!r}, expected {wanted!r}')
        if any(value < 0 for value in report['timings_ms'].values()):
            raise AssertionError('negative phase duration')
        print('PASS full RGBA bytes: row order, channel order, premultiplication and hashes')

        source_raw = work/'source-space.rgba'
        source_report = json.loads(run('--output-color-space', 'source', '--raw', str(source_raw)).stdout)
        if source_raw.read_bytes() != expected:
            raise AssertionError('source-space sRGB fixture did not preserve independently specified pixels')
        if source_report['requested_output_color_space'] != 'source':
            raise AssertionError('source-space mode was not reported')
        for prefix in ('source', 'output'):
            if source_report[prefix + '_color_space'] != 'kCGColorSpaceSRGB':
                raise AssertionError('source-space fixture lost its explicit sRGB color space')
            if source_report[prefix + '_icc_bytes'] <= 0 or len(source_report[prefix + '_icc_sha256']) != 64:
                raise AssertionError('source-space ICC profile was not fingerprinted')
        if (source_report['source_icc_bytes'], source_report['source_icc_sha256']) != (
                source_report['output_icc_bytes'], source_report['output_icc_sha256']):
            raise AssertionError('source-space mode changed the source profile')
        if source_report['output_icc_sha256'] != report['output_icc_sha256']:
            raise AssertionError('default sRGB and explicit source-sRGB output profiles differ')
        run('--output-color-space', 'unknown', expected_exit=64)
        run('--output-color-space', expected_exit=64)
        run('--output-color-space', 'source', '--output-color-space', 'srgb', expected_exit=64)
        # Independently encoded grayscale input must be refused in source mode, rather than silently converted to RGB.
        gray = (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 1, 1, 8, 0, 0, 0, 0))
                + chunk(b'IDAT', zlib.compress(b'\x00\x80')) + chunk(b'IEND', b''))
        gray_source = work/'gray.png'
        gray_source.write_bytes(gray)
        result = subprocess.run([str(probe), '--full-resolution', str(gray_source), '--output-color-space', 'source'],
                                capture_output=True, text=True, timeout=10)
        if result.returncode != 7 or 'three-component RGB' not in result.stderr:
            raise AssertionError(f'non-RGB source was not explicitly refused: {result.stderr}')
        # A linear-light RGB PNG distinguishes preserving the source space from always drawing into sRGB.
        # Its encoded RGB samples are specified independently; no ImageIO-generated fixture or checksum is used.
        linear = (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 1, 1, 8, 2, 0, 0, 0))
                  + chunk(b'gAMA', struct.pack('>I', 100000))
                  + chunk(b'cHRM', struct.pack('>8I', 31270, 32900, 64000, 33000, 30000, 60000, 15000, 6000))
                  + chunk(b'IDAT', zlib.compress(bytes([0, 128, 64, 32]))) + chunk(b'IEND', b''))
        linear_source = work/'linear.png'
        linear_source.write_bytes(linear)
        linear_outputs = []
        for mode in ('source', 'srgb'):
            output = work/f'linear-{mode}.rgba'
            result = subprocess.run([str(probe), '--full-resolution', str(linear_source),
                                     '--output-color-space', mode, '--raw', str(output)],
                                    capture_output=True, text=True, timeout=10)
            if result.returncode:
                raise AssertionError(f'linear RGB {mode} failed: {result.stderr}')
            linear_outputs.append(output.read_bytes())
        if linear_outputs[0] != bytes([128, 64, 32, 255]) or linear_outputs[1] == linear_outputs[0]:
            raise AssertionError(f'source-space linear samples were converted or sRGB was not: {linear_outputs}')
        print('PASS source-space exact pixels, ICC fingerprints, invalid modes and non-RGB refusal')

        existing = work/'existing.rgba'
        existing.write_bytes(b'keep this existing artifact')
        run('--raw', str(existing), expected_exit=8)
        if existing.read_bytes() != b'keep this existing artifact':
            raise AssertionError('existing raw output was modified')
        print('PASS existing output is refused and preserved')

        refused = work/'too-large.rgba'
        run('--raw', str(refused), '--max-output-bytes', '15', expected_exit=6)
        if refused.exists():
            raise AssertionError('budget refusal created raw output')
        run('--max-output-bytes', '16')
        run('--max-output-bytes', '-1', expected_exit=64)
        run('--max-output-bytes', str(512 * 1024 * 1024 + 1), expected_exit=64)
        print('PASS output budget boundary and invalid sizes')

        run('--index', '1', expected_exit=4)
        run('--timeout', '0', expected_exit=64)
        run('--timeout', '121', expected_exit=64)
        print('PASS invalid item and timeout are refused')

        legacy = subprocess.run([str(probe), str(source)], capture_output=True, text=True, timeout=10)
        if legacy.returncode or 'PASS decoded checksum=' not in legacy.stderr:
            raise AssertionError(f'legacy invocation failed: {legacy.stderr}')
        print('PASS original invocation remains available')


if __name__ == '__main__':
    try:
        main()
    except (AssertionError, OSError, ValueError, subprocess.TimeoutExpired) as error:
        raise SystemExit(f'FAIL image-decode: {error}') from error
