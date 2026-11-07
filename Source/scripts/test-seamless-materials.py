#!/usr/bin/env python3
"""No VM or signals: qualify retained material rows after releasing the guest agent."""
import ast
import contextlib
import io
from pathlib import Path
import re
import signal
import tempfile
from types import SimpleNamespace
import unittest


source = Path(__file__).resolve().parents[1]/'probes/seamless-driver.py'
definitions = ast.parse(source.read_text(), filename=str(source))
names = {'material_report', 'qualify_material_fixture'}
functions = [node for node in definitions.body if isinstance(node, ast.FunctionDef) and node.name in names]
assert {node.name for node in functions} == names
qualification = compile(ast.Module(body=functions, type_ignores=[]), str(source), 'exec')


class Clock:
    def __init__(self):
        self.now = 0

    def monotonic(self):
        return self.now

    def sleep(self, seconds):
        self.now += seconds


def raw_rows(mode=0, window=777, material=True):
    header = f'gpu mode {mode} scale 2 generate 1 composites 1 whole 1 seconds 0.001\n'
    row = f'backdrop id {window} order 0 material 5 active 1 blend 0 rect 20,30 100x150 saturation 1\n'
    return header + (row if material else '')


def proxy_report(window=777, mask='mask'):
    return f'{window}\trows 1\tkinds 1\tinside true\tviews 5:whole:in:{mask}\n'


class MaterialsQualificationTests(unittest.TestCase):
    def qualify(self, report=None, snapshots=None):
        report = proxy_report() if report is None else report
        snapshots = [raw_rows()] if snapshots is None else snapshots
        with tempfile.TemporaryDirectory(prefix='lightclick-materials-test-') as directory:
            results = Path(directory)
            command = results/'fixture-clicks.txt.command'
            material_file = Path(str(command) + '.materials')
            clock, events, checks = Clock(), [], {}
            stopped = False
            reads = 0

            def host_signal(pid, number):
                self.assertFalse(stopped, 'proxy material state must be captured while Seamless is active')
                self.assertEqual((pid, number), (44321, signal.SIGUSR2))
                self.assertEqual(command.read_text(), 'materials-report')
                events.append('report')
                material_file.write_text(report)

            def request(value, timeout):
                nonlocal stopped, reads
                self.assertGreater(timeout, 0)
                if value.get('Action') == 'seamless-toggle':
                    self.assertIn('report', events)
                    self.assertFalse(stopped)
                    self.assertEqual(command.read_text(), '', 'clear the signal command before leaving Seamless')
                    stopped = True
                    events.append('toggle')
                    return {}
                self.assertTrue(stopped, 'guest diagnostics deadlock while the leap command owns the agent')
                self.assertEqual(value, {'Executable': '/fixture/guest', 'Arguments': ['gpu', '--rows']})
                events.append('guest rows')
                snapshot = snapshots[min(reads, len(snapshots)-1)]
                reads += 1
                return {'ExitCode': 0, 'Stdout': snapshot}

            namespace = {'Path': Path, 're': re, 'signal': signal, 'os': SimpleNamespace(kill=host_signal),
                         'time': clock, 'results': results, 'tag': 'fixture', 'request': request}
            exec(qualification, namespace)
            # Host WindowServer withheld the title in the observed failure. The owner/PID must suffice.
            windows = lambda: ['id=123 pid=44321 owner="SeamlessMaterials (Clone of Mojave)" title=""']
            with contextlib.redirect_stdout(io.StringIO()):
                passed = namespace['qualify_material_fixture'](
                    '/fixture/guest', 777, windows, lambda label, good: checks.__setitem__(label, bool(good)))
            self.assertEqual(command.read_text(), '')
            self.assertTrue(stopped)
            self.assertGreater(reads, 0)
            self.assertLessEqual(clock.now, 91, 'the fake-clock deadline must bound missing reports or snapshots')
            return passed, checks, events, reads

    def test_empty_host_title_and_exclusive_agent_still_qualify(self):
        passed, checks, events, reads = self.qualify()
        self.assertTrue(passed)
        self.assertTrue(all(checks.values()))
        self.assertEqual(events, ['report', 'toggle', 'guest rows'])
        self.assertEqual(reads, 1)

    def test_empty_guest_rows_cannot_pass_vacuously(self):
        passed, checks, _, _ = self.qualify(snapshots=[raw_rows(material=False)])
        self.assertFalse(passed)
        self.assertFalse(checks['the explicit fixture exported nonempty guest material rows'])

    def test_another_guest_window_cannot_satisfy_the_fixture(self):
        passed, checks, _, _ = self.qualify(report=proxy_report(window=778))
        self.assertFalse(passed)
        self.assertFalse(checks['its guest window ID and material count reach the proxy'])

    def test_a_material_view_without_a_mask_cannot_pass(self):
        passed, checks, _, _ = self.qualify(report=proxy_report(mask='nomask'))
        self.assertFalse(passed)
        self.assertFalse(checks['each fixture material has its masked view inside the proxy'])

    def test_wait_for_mode_zero_after_the_agent_returns(self):
        passed, checks, _, reads = self.qualify(snapshots=[raw_rows(mode=1, window=778), raw_rows()])
        self.assertTrue(passed)
        self.assertTrue(all(checks.values()))
        self.assertEqual(reads, 2)

    def test_successful_queries_in_mode_one_are_not_a_stop_barrier(self):
        passed, checks, _, reads = self.qualify(snapshots=[raw_rows(mode=1)])
        self.assertFalse(passed)
        self.assertGreater(reads, 1)
        self.assertFalse(checks['Seamless released the agent and stopped per-window composition'])


if __name__ == '__main__':
    unittest.main(verbosity=2)
