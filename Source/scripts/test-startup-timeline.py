#!/usr/bin/env python3
"""Passive timeline tests: temporary files, fake process snapshots and clock; no VM or UI."""
import ast
import json
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch

from startup_timeline import StartupTimeline, preserve_startup_logs


class TimelineTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.machine = self.root/'machine'
        (self.machine/'State').mkdir(parents=True)
        self.channel = self.root/'diagnostics'
        self.output = self.root/'retained.startup.jsonl'
        self.clock = [100.0]
        self.timeline = StartupTimeline(self.output, clock=lambda: self.clock[0])
        self.addCleanup(self.timeline.close)
        self.qemu = self.root/'Light Click.app/qemu-system-x86_64.real'

    def rows(self):
        return [json.loads(row) for row in self.output.read_text().splitlines()]

    def observe(self, snapshot=''):
        self.timeline.observe(self.machine, self.channel, 10, self.qemu, snapshot=snapshot)

    def test_fresh_status_is_recorded_once_with_one_clock(self):
        status = self.machine/'State/GuestStatus.plist'
        status.write_bytes(b'partially written plist')
        self.observe()
        self.clock[0] = 103.5
        self.channel.mkdir()
        status.write_bytes(plistlib.dumps({'Report': {'DesktopRunning': True}}))
        self.observe()
        self.observe()
        rows = self.rows()
        self.assertEqual([row['phase'] for row in rows],
                         ['timeline_started', 'diagnostics_channel', 'desktop_running'])
        self.assertEqual([row['elapsed_seconds'] for row in rows], [0.0, 3.5, 3.5])

    def test_false_or_malformed_status_is_not_desktop(self):
        reports = [{'DesktopRunning': value} for value in (False, 0, 'true', '1', 2, -1, 1.0)]
        for report in [*reports, [], None]:
            (self.machine/'State/GuestStatus.plist').write_bytes(plistlib.dumps({'Report': report})
                                                               if report is not None else b'')
            self.observe()
        self.assertEqual(len(self.rows()), 1)

    def test_actual_integer_desktop_flag_and_raw_status_retention(self):
        report = {'Report': {'DesktopRunning': 1, 'GuestVersion': '10.14.6'}}
        status = self.machine/'State/GuestStatus.plist'
        status.write_bytes(plistlib.dumps(report, fmt=plistlib.FMT_BINARY))
        self.clock[0] = 125.0
        self.observe()
        self.assertEqual(self.rows()[-1]['phase'], 'desktop_running')
        self.assertEqual(self.rows()[-1]['elapsed_seconds'], 25.0)
        destination = self.root/'retained-status'
        destination.mkdir()
        copied = preserve_startup_logs(self.root, destination, 'fixture', self.root,
                                       'ABCDEF12', False, machine=self.machine)
        self.assertEqual(copied, [str(destination/'fixture.GuestStatus.plist')])
        self.assertEqual((destination/'fixture.GuestStatus.plist').read_bytes(), status.read_bytes())
        self.assertEqual(plistlib.loads(status.read_bytes()), report)

    def test_only_exact_qemu_path_and_owned_parent_are_observed(self):
        self.observe(f'20 11 {self.qemu} -machine q35\n21 10 {self.qemu}.other -machine q35')
        self.assertEqual(len(self.rows()), 1)
        self.observe(f'22 10 {self.qemu} -machine q35')
        self.observe(f'23 10 {self.qemu} -machine q35')
        self.assertEqual(self.rows()[-1]['pid'], 22)
        self.assertEqual(len(self.rows()), 2)

    def test_monitor_stops_and_close_is_idempotent(self):
        with patch.object(self.timeline, 'observe') as observe:
            self.timeline.start(self.machine, self.channel, 10, self.qemu)
            self.timeline.close()
            self.assertFalse(self.timeline.worker.is_alive())
            self.assertLessEqual(observe.call_count, 1)
        self.timeline.close()
        self.timeline.record('after_close')
        self.assertEqual(len(self.rows()), 1)

    def test_guest_bench_opt_in_removes_stale_status_before_launch(self):
        tree = ast.parse((Path(__file__).parent/'guest-bench').read_text())
        # Exercise the actual opt-in block without executing clone/launch code.
        block = next(node for node in tree.body if isinstance(node, ast.If)
                     and ast.unparse(node.test) == 'args.startup_timeline')
        stale = self.machine/'State/GuestStatus.plist'
        stale.write_bytes(plistlib.dumps({'Report': {'DesktopRunning': True}}))
        import types
        for enabled in (False, True):
            namespace = dict(args=types.SimpleNamespace(startup_timeline=enabled, tag='test'),
                             machine=self.machine, source=self.root,
                             env={'LC_SEAMLESS_CLICK_LOG': '1'},
                             StartupTimeline=lambda path: self.timeline,
                             atexit=types.SimpleNamespace(register=lambda function: None))
            exec(compile(ast.Module(body=[block], type_ignores=[]), '<guest-bench opt-in>', 'exec'), namespace)
            self.assertEqual(stale.exists(), not enabled)
        self.assertEqual(self.rows()[-1]['preparation_delay_policy_seconds'], 90)

    def test_log_retention_only_reads_the_fresh_identifier(self):
        work, destination, temporary = (self.root/name for name in ('work', 'retained', 'temporary'))
        for directory in (work, destination, temporary):
            directory.mkdir()
        (work/'app.log').write_text('app')
        (temporary/'lc-seamless-ABCDEF12.log').write_text('desktop')
        (temporary/'lc-seamless-ABCDEF12.log.com.apple.TextEdit').write_text('session')
        (temporary/'lc-seamless-OTHER123.log').write_text('unrelated')
        preserve_startup_logs(work, destination, 'test', temporary, 'ABCDEF12-3456', False)
        self.assertEqual([path.name for path in destination.iterdir()], ['test.app.log'])
        copied = preserve_startup_logs(work, destination, 'test', temporary, 'ABCDEF12-3456', True)
        self.assertEqual(len(copied), 3)
        self.assertEqual((destination/'test.prearm.log').read_text(), 'desktop')
        self.assertEqual((destination/'test.prearm.log.com.apple.TextEdit').read_text(), 'session')
        self.assertFalse(any('OTHER' in path.name for path in destination.iterdir()))

    def test_startup_logging_and_thread_failure_still_clean_owned_process(self):
        tree = ast.parse((Path(__file__).parent/'guest-bench').read_text())
        launch = next(i for i, node in enumerate(tree.body) if isinstance(node, ast.Assign)
                      and any(isinstance(target, ast.Name) and target.id == 'process' for target in node.targets))
        owner = tree.body[launch+1]
        self.assertIsInstance(owner, ast.Try)
        # Keep the actual startup statements and cleanup guard. Abort on a fake timeline operation, so no wait/driver runs.
        begin = next(i for i, node in enumerate(owner.body) if isinstance(node, ast.If)
                     and isinstance(node.test, ast.Name) and node.test.id == 'timeline')
        cleanup = next(node for node in owner.finalbody if isinstance(node, ast.Try))
        block = ast.Try(body=owner.body[:begin+1], handlers=[], orelse=[], finalbody=[cleanup])
        ast.fix_missing_locations(block)
        import types
        for failing_method in ('record', 'start'):
            calls = []
            def record(*args, **kwargs):
                calls.append(('record', args[0]))
                if failing_method == 'record':
                    raise RuntimeError('injected record failure')
            def start(*args):
                calls.append(('start',))
                raise RuntimeError('injected start failure')
            process = types.SimpleNamespace(pid=123)
            def stop_test_processes(owned, work):
                self.assertIs(owned, process)
                calls.append(('cleanup',))
            namespace = dict(timeline=types.SimpleNamespace(record=record, start=start), process=process,
                             machine=self.machine, channel=self.channel, real=self.qemu, work=self.root,
                             stop_test_processes=stop_test_processes,
                             signal=types.SimpleNamespace(SIGTERM=15, signal=lambda *args: None))
            with self.assertRaisesRegex(RuntimeError, 'injected'):
                exec(compile(ast.Module(body=[block], type_ignores=[]), '<actual startup ownership>', 'exec'), namespace)
            self.assertEqual(calls[-1], ('cleanup',))
            self.assertEqual(sum(row[0] == 'cleanup' for row in calls), 1)

    def test_driver_host_observation_precedes_watcher_only_when_opted_in(self):
        tree = ast.parse((Path(__file__).parents[1]/'probes/seamless-driver.py').read_text())
        desktop = next(node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == 'desktop')
        end = next(i for i, node in enumerate(desktop.body) if isinstance(node, ast.Expr)
                   and isinstance(node.value, ast.Call) and isinstance(node.value.func, ast.Name)
                   and node.value.func.id == 'watch_guest')
        # Execute the real prefix through watcher entry; it cannot stage or launch anything.
        desktop.body = desktop.body[:end+1]
        module = ast.Module(body=[desktop], type_ignores=[])
        for enabled, error in ((False, None), (True, None), (True, SystemExit('host timeout'))):
            events = []
            def request(command, timeout):
                events.append(('request', command, timeout))
                if error:
                    raise error
                return {'Prepared': True}
            def watch():
                events.append(('watcher',))
            namespace = dict(results=self.root, tag='test', request=request, watch_guest=watch)
            if enabled:
                namespace['record_phase'] = lambda phase, **details: events.append((phase, details))
            exec(compile(module, '<actual desktop prefix>', 'exec'), namespace)
            if error:
                with self.assertRaises(SystemExit):
                    namespace['desktop'](materials_only=True)
                self.assertEqual(events[-1][0], 'prepared_request_finished')
                self.assertIn('error', events[-1][1])
                self.assertFalse(any(row[0] == 'watcher' for row in events))
            else:
                namespace['desktop'](materials_only=True)
                self.assertEqual(events[-1], ('watcher',))
                if enabled:
                    self.assertEqual(events[-2][0], 'prepared_observed')
                    self.assertEqual(events[2], ('request', {'Action': 'seamless-state'}, 5))
                else:
                    self.assertEqual(events, [('watcher',)])


if __name__ == '__main__':
    unittest.main()
