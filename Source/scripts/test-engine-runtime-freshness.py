#!/usr/bin/env python3
"""Engine runtime receipt invalidation using scratch files; no build, git command, or guest."""
import importlib.util
import os
from pathlib import Path
import tempfile
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('freshness', Path(__file__).with_name('build_freshness.py'))
freshness = importlib.util.module_from_spec(spec)
spec.loader.exec_module(freshness)


def fixture_files(root):
    # Replace only git-based enumeration: ignored build trees are omitted when enumerating directories,
    # while explicitly named archive files remain visible, exactly the distinction under regression.
    if not root.is_dir():
        return [root]
    return sorted(path for path in root.rglob('*') if path.is_file() and '.build' not in path.parts)


def main():
    with tempfile.TemporaryDirectory(prefix='lightclick-engine-freshness-') as temporary:
        root = Path(temporary)
        source, engine = root/'Source', root/'External Engine'
        (source/'vendor/qemu').mkdir(parents=True)
        inputs = []
        for name in ('Sources/CEngine/emit_int.c', 'Sources/CEngine/include/engine_api.h',
                     'Sources/Engine/Engine.swift', 'Monitor/monitor.c', 'Package.swift', 'build.sh',
                     '.build/release/libEngine.a'):
            path = engine/name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('initial ' + name)
            inputs.append(path)
        with patch.object(freshness, 'files', side_effect=fixture_files), \
                patch.object(freshness, 'command_version', return_value='fixture'), \
                patch.dict(os.environ, {'LC_HVDBT_ENGINE': ''}):
            disabled = freshness.snapshot(source, 'runtime')
            dependencies = freshness.snapshot(source, 'dependencies')
            firmware = freshness.snapshot(source, 'firmware')
            os.environ['LC_HVDBT_ENGINE'] = str(engine)
            before = freshness.snapshot(source, 'runtime')
            assert before != disabled
            assert freshness.snapshot(source, 'dependencies') == dependencies
            assert freshness.snapshot(source, 'firmware') == firmware
            binary = root/'qemu-system-x86_64'
            binary.write_bytes(b'linked executable')
            receipt = {'Freshness': freshness.seal(before, before, root, [binary])}
            assert freshness.current(receipt, before, root, (binary.name,))
            for path in inputs:
                original = path.read_bytes()
                path.write_bytes(original + b' changed')
                current = freshness.snapshot(source, 'runtime')
                assert current != before, path
                assert not freshness.current(receipt, current, root), path
                path.write_bytes(original)
                assert freshness.snapshot(source, 'runtime') == before
            archive = inputs[-1]
            original = archive.read_bytes()
            archive.unlink()
            assert freshness.snapshot(source, 'runtime') != before
            archive.write_bytes(original)
            unrelated = engine/'.build/release/engine-run'
            unrelated.write_text('not linked into QEMU')
            assert freshness.snapshot(source, 'runtime') == before
            (engine/'Tests').mkdir()
            (engine/'Tests/notes.txt').write_text('fixture-only change')
            assert freshness.snapshot(source, 'runtime') == before
            os.environ['LC_HVDBT_ENGINE'] = ''
            assert freshness.snapshot(source, 'runtime') == disabled
            assert not freshness.current(receipt, disabled, root)
            # Even identical input files in a different selected root must record the environment change.
            import shutil
            other = root/'Other Engine'
            shutil.copytree(engine, other)
            os.environ['LC_HVDBT_ENGINE'] = str(other)
            assert freshness.snapshot(source, 'runtime') != before
            os.environ['LC_HVDBT_ENGINE'] = 'relative/Engine'
            try:
                freshness.snapshot(source, 'runtime')
            except ValueError as error:
                assert 'absolute' in str(error)
            else:
                raise AssertionError('ambiguous relative Engine path accepted')
    print('PASS Engine archive/source/header/monitor/recipe invalidation; enable/disable/path environment; unrelated products ignored; dependencies/firmware unchanged')


if __name__ == '__main__':
    main()
