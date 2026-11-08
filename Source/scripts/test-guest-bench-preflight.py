#!/usr/bin/env python3
"""Execute the actual guest-bench startup through a mocked lease; no VM/processes."""
import ast
import contextlib
import io
from pathlib import Path
import plistlib
import sys
import tempfile
import types
import unittest
from unittest.mock import Mock, patch


script = Path(__file__).with_name('guest-bench')
tree = ast.parse(script.read_text())
lease_index = next(i for i, node in enumerate(tree.body)
                   if isinstance(node, ast.Assign)
                   and any(isinstance(target, ast.Name) and target.id == 'clone_lease'
                           for target in node.targets))
# Include every actual startup statement through the first lease construction.
# Valid inputs stop there; invalid inputs must exit before it is even constructed.
startup = compile(ast.fix_missing_locations(ast.Module(body=tree.body[:lease_index+1], type_ignores=[])),
                  str(script), 'exec')


class ReachedLease(Exception):
    pass


class Checks(unittest.TestCase):
    def fixture(self, root):
        app = root/'Candidate.app'
        machine = root/'Fixture.vintelmac'
        machine.mkdir()
        (machine/'Machine.plist').write_bytes(plistlib.dumps({'Identifier': 'FIXTURE'}))
        work = root/'Source/Build/bench/preflight-test'
        work.mkdir(parents=True)
        (work/'untouched-clone').write_bytes(b'old clone evidence')
        diagnostics = work/'diagnostics/FIXTURE'
        diagnostics.mkdir(parents=True)
        (diagnostics/'Transfer.bin').write_bytes(b'old staged bytes')
        (diagnostics/'Request.json').write_bytes(b'old request')
        (diagnostics/'Result.json').write_bytes(b'old result')
        return app, machine, work

    def executable(self, app, executable=True):
        main = app/'Contents/MacOS/Light Click'
        main.parent.mkdir(parents=True)
        main.write_bytes(b'headless test placeholder; never executed')
        main.chmod(0o755 if executable else 0o644)

    @staticmethod
    def snapshot(root):
        # Only this test's own generated directory, never a real machine or library.
        return {str(path.relative_to(root)): (path.read_bytes(), path.stat().st_ino, path.stat().st_mtime_ns)
                for path in root.rglob('*') if path.is_file()}

    def invoke(self, root, app, machine, valid=False, extra=()):
        lease = Mock(side_effect=ReachedLease)
        modules = {
            'startup_timeline': types.SimpleNamespace(StartupTimeline=Mock(), preserve_startup_logs=Mock()),
            'diagnostics_evidence': types.SimpleNamespace(retain_timeout=Mock()),
            'sampling_entitlements': types.SimpleNamespace(prepare_sampling_entitlements=Mock()),
            'clone_lease': types.SimpleNamespace(CloneLease=lease, LeaseRefused=RuntimeError, process_identity=Mock()),
        }
        stderr = io.StringIO()
        namespace = {'__file__': str(root/'Source/scripts/guest-bench'), '__doc__': 'headless startup regression'}
        before = self.snapshot(root)
        with patch.dict(sys.modules, modules), patch.object(sys, 'argv',
                [str(script), str(app), str(machine), 'preflight-test', *extra]), \
                patch('shutil.rmtree') as remove, patch('subprocess.run') as subprocess_run, \
                patch('subprocess.Popen') as popen, patch.object(Path, 'mkdir') as mkdir, \
                contextlib.redirect_stderr(stderr):
            if valid:
                with self.assertRaises(ReachedLease):
                    exec(startup, namespace)
                lease.assert_called_once_with(check_running='--allow-running-vms' not in extra)
            else:
                with self.assertRaises(SystemExit) as stopped:
                    exec(startup, namespace)
                self.assertEqual(stopped.exception.code, 2)
                lease.assert_not_called()
            remove.assert_not_called()
            mkdir.assert_not_called()
            subprocess_run.assert_not_called()
            popen.assert_not_called()
        self.assertEqual(self.snapshot(root), before)
        return stderr.getvalue()

    def test_missing_app_preserves_existing_clone_and_staging_before_lease(self):
        with tempfile.TemporaryDirectory(prefix='lightclick-preflight-') as temporary:
            root = Path(temporary)
            app, machine, _ = self.fixture(root)
            message = self.invoke(root, app, machine)
            self.assertIn('App main executable is missing or not executable', message)
            self.assertIn(str(app/'Contents/MacOS/Light Click'), message)

    def test_missing_or_nonexecutable_main(self):
        for nonexecutable in (False, True):
            with self.subTest(nonexecutable=nonexecutable), tempfile.TemporaryDirectory(prefix='lightclick-preflight-') as temporary:
                root = Path(temporary)
                app, machine, _ = self.fixture(root)
                if nonexecutable:
                    self.executable(app, executable=False)
                else:
                    app.mkdir()
                self.assertIn('App main executable', self.invoke(root, app, machine))

    def test_missing_malformed_nondictionary_or_directory_machine_plist(self):
        for shape in ('missing', 'malformed', 'xml-invalid', 'array', 'directory'):
            with self.subTest(shape=shape), tempfile.TemporaryDirectory(prefix='lightclick-preflight-') as temporary:
                root = Path(temporary)
                app, machine, _ = self.fixture(root)
                self.executable(app)
                configuration = machine/'Machine.plist'
                configuration.unlink()
                if shape == 'malformed':
                    configuration.write_bytes(b'not a plist')
                elif shape == 'xml-invalid':
                    configuration.write_bytes(b'<?xml version="1.0"?><plist><dict>')
                elif shape == 'array':
                    configuration.write_bytes(plistlib.dumps([]))
                elif shape == 'directory':
                    configuration.mkdir()
                self.assertIn('Machine.plist', self.invoke(root, app, machine))

    def test_valid_xml_and_binary_inputs_reach_lease_without_mutation(self):
        for fmt in (plistlib.FMT_XML, plistlib.FMT_BINARY):
            with self.subTest(fmt=fmt), tempfile.TemporaryDirectory(prefix='lightclick-preflight-') as temporary:
                root = Path(temporary)
                app, machine, _ = self.fixture(root)
                self.executable(app)
                (machine/'Machine.plist').write_bytes(plistlib.dumps({'Identifier': 'FIXTURE'}, fmt=fmt))
                self.invoke(root, app, machine, valid=True)

    def test_fresh_identifier_and_unrelated_vm_preference_preserved(self):
        with tempfile.TemporaryDirectory(prefix='lightclick-preflight-') as temporary:
            root = Path(temporary)
            app, machine, _ = self.fixture(root)
            self.executable(app)
            # --fresh-identifier writes the Identifier later; preflight must not
            # reject an otherwise usable dictionary merely because it is absent.
            (machine/'Machine.plist').write_bytes(plistlib.dumps({}))
            self.invoke(root, app, machine, valid=True, extra=('--fresh-identifier', '--allow-running-vms'))


if __name__ == '__main__':
    unittest.main()
