#!/usr/bin/env python3
"""Tiny offscreen comparator tests. Usage: test-image-color-compare.py /path/to/compiled/probe"""
import ctypes
import json
import math
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def main():
    probe = Path(sys.argv[1]).resolve()
    cg = ctypes.CDLL('/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics')
    cf = ctypes.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
    cg.CGColorSpaceCreateWithName.argtypes = [ctypes.c_void_p]
    cg.CGColorSpaceCreateWithName.restype = ctypes.c_void_p
    cg.CGColorSpaceCopyICCData.argtypes = [ctypes.c_void_p]
    cg.CGColorSpaceCopyICCData.restype = ctypes.c_void_p
    cf.CFDataGetLength.argtypes = [ctypes.c_void_p]
    cf.CFDataGetLength.restype = ctypes.c_long
    cf.CFDataGetBytePtr.argtypes = [ctypes.c_void_p]
    cf.CFDataGetBytePtr.restype = ctypes.c_void_p
    cf.CFRelease.argtypes = [ctypes.c_void_p]
    with tempfile.TemporaryDirectory(prefix='lightclick-color-') as temporary:
        work = Path(temporary)
        profiles = []
        for name in ('kCGColorSpaceSRGB', 'kCGColorSpaceLinearSRGB'):
            space = cg.CGColorSpaceCreateWithName(ctypes.c_void_p.in_dll(cg, name).value)
            assert space
            data = cg.CGColorSpaceCopyICCData(space)
            assert data
            target = work/(name + '.icc')
            target.write_bytes(ctypes.string_at(cf.CFDataGetBytePtr(data), cf.CFDataGetLength(data)))
            cf.CFRelease(data)
            cf.CFRelease(space)
            profiles.append(target)
        guest, host = work/'guest.rgba', work/'host.rgba'
        # Opaque independent samples: an encoded .5 sRGB value is ~.216 linear, while linear .5 stays ~.502.
        guest.write_bytes(bytes([128, 64, 32, 255, 0, 255, 0, 255]))
        host.write_bytes(guest.read_bytes())

        def run(width='2', height='1', raw_a=guest, raw_b=host, icc_a=None, icc_b=None, okay=True):
            result = subprocess.run([str(probe), str(width), str(height), str(raw_a), str(raw_b),
                                     str(icc_a or profiles[0]), str(icc_b or profiles[0])],
                                    capture_output=True, text=True, timeout=10)
            if okay:
                assert result.returncode == 0, result.stderr
                return json.loads(result.stdout)
            assert result.returncode != 0, result.stdout
            assert not result.stdout, 'failure emitted a numeric report'

        identical = run()
        assert identical['icc_bytes_equal'] is True
        for stats in identical['comparisons'].values():
            assert stats['max_absolute_rgba'] == [0, 0, 0, 0]
            assert stats['rgb_component_error_bins'] == [6, 0, 0, 0, 0, 0]
        report = run(icc_b=profiles[1])
        assert report['icc_bytes_equal'] is False
        stats = report['comparisons']['own_profiles']
        for channel, sample in enumerate((128, 64, 32)):
            encoded = sample / 255
            linear = encoded / 12.92 if encoded <= .04045 else ((encoded + .055) / 1.055) ** 2.4
            expected = abs(encoded - linear)
            assert math.isclose(stats['max_absolute_rgba'][channel], expected, abs_tol=.002), stats
            assert math.isclose(stats['mean_absolute_rgba'][channel], expected / 2, abs_tol=.002), stats
            assert math.isclose(stats['rms_rgba'][channel], expected / math.sqrt(2), abs_tol=.002), stats
            assert stats['max_xy_rgba'][channel] == [0, 0]
        assert stats['max_absolute_rgba'][3] == 0
        for name in ('same_guest_profile_counterfactual', 'same_host_profile_counterfactual'):
            assert report['comparisons'][name]['max_absolute_rgba'] == [0, 0, 0, 0]
        for name in ('guest_raw_profile_swap_counterfactual', 'host_raw_profile_swap_counterfactual'):
            assert report['comparisons'][name] == stats
        assert sum(stats['rgb_component_error_bins']) == 6
        assert stats['rgb_component_error_bins'][-1] == 3
        print('PASS identical pixels/profiles; independent sRGB transfer math; controls, bins and coordinates')

        host.write_bytes(bytes([128, 64, 32, 255, 255, 255, 0, 255]))
        moved = run()['comparisons']['own_profiles']
        assert moved['max_xy_rgba'][0] == [1, 0]
        assert math.isclose(moved['max_absolute_rgba'][0], 1, abs_tol=1e-6)
        guest.write_bytes(bytes([0, 0, 0, 255]) * 4)
        host.write_bytes(bytes([0, 0, 0, 255]) * 3 + bytes([255, 0, 0, 255]))
        assert run('2', '2')['comparisons']['own_profiles']['max_xy_rgba'][0] == [1, 1]
        guest.write_bytes(bytes([128, 64, 32, 255, 0, 255, 0, 255]))
        host.write_bytes(guest.read_bytes())
        for width, height in [('0', '1'), ('-1', '1'), ('1x', '1'), ('999999999999999999999', '1'),
                              ('10000', '10000'), ('8192', '8192')]:
            run(width, height, okay=False)
        run('3', '1', okay=False)
        run(raw_a=work, okay=False)
        link = work/'link'
        link.symlink_to(guest)
        run(raw_a=link, okay=False)
        fifo = work/'fifo'
        os.mkfifo(fifo)
        run(raw_a=fifo, okay=False)
        invalid = work/'bad.icc'
        invalid.write_bytes(b'not an ICC profile')
        run(icc_a=invalid, okay=False)
        oversized = work/'large.icc'
        with oversized.open('wb') as file:
            file.truncate(4 * 1024 * 1024 + 1)
        run(icc_a=oversized, okay=False)
        print('PASS non-origin max coordinate; invalid dimensions, allocation caps, raw sizes, directories, symlinks and ICC inputs')


if __name__ == '__main__':
    main()
