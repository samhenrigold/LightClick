#!/usr/bin/env python3
"""boot-matrix's judging against text shaped like Tally.swift's, hvdbt.c's and VIMSession's, and its case syntax."""
import importlib.machinery
import importlib.util
from pathlib import Path
import sys
import tempfile

# The tool's name has no .py, so the import system needs telling.
loader = importlib.machinery.SourceFileLoader('boot_matrix', str(Path(__file__).with_name('boot-matrix')))
tool = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
sys.modules[loader.name] = tool
loader.exec_module(tool)

RUNNING = '''# hvdbt tally. One vCPU; TCG up to XNU's 64-bit entry, then the engine. All counts are measured on this run.
state: running or exited normally
seconds since hand-off: 30.1
outcome: running at 30.1 s, syscalls 1200, page faults 900, bad hash see dump

== process log: spawns, exits, wait4 results, user faults other than #PF and #NM, oldest first ==
proc    1.000 cr3 0x1000 execve /sbin/launchd []
proc    2.000 cr3 0x1000 write fd 2: FAULT vector 3 hard stop no progress, a guest's own words
state: HARD STOP: not really, this is guest text
proc    3.000 cr3 0x1000 wait4 returned 40 status 0x9 SIGNAL 9
  last user page faults, rip, address, error, cr3:

== stops and fallbacks, ranked by count. tcg_ms: time away from the engine after each, with TCG running ==
           4        1.0  FETCH_FAULT
'''
HARD_STOP = RUNNING.replace('state: running or exited normally', 'state: HARD STOP: monitor fault at 0x1234')
HARD_STOP = HARD_STOP.replace('outcome: running', 'outcome: hard stop')
POWERED_OFF = RUNNING.replace('outcome: running', 'outcome: guest powered off')
USER_FAULT = RUNNING+'proc    4.000 cr3 0x1000 FAULT vector 6 error 0x0 rip 0x7fff1000  0f 0b\n  0x0 0x1\n'
CLEAN_LOG = '''
[Light Click] Bundled runtime: /app/qemu-system-x86_64

hvdbt: the engine takes over at rip 0xffffff8000200000, cr3 0x1000
guest serial: no progress here, hvdbt: no progress as this line doesn't start with it
'''
STALL_LOG = CLEAN_LOG+'\nhvdbt: no progress for 5 s. Last off the engine because: a stop to take this report\n'
STUCK_LOG = CLEAN_LOG+'\nhvdbt: no progress, and the vCPU did not stop for a report in 3 s. in_engine 1\n'
LIFECYCLE = '\n[Light Click] Lifecycle: '
POWER_OFF_LOG = CLEAN_LOG+LIFECYCLE+'{"event":"SHUTDOWN","data":{"guest":true,"reason":"guest-shutdown"}}\n'
REBOOT_LOG = CLEAN_LOG+LIFECYCLE+'{"data":{"reason":"guest-reset","guest":true},"event":"SHUTDOWN"}\n'
TEARDOWN_LOG = CLEAN_LOG+LIFECYCLE+'{"event":"SHUTDOWN","data":{"guest":false,"reason":"host-signal"}}\n'

assert tool.judge(CLEAN_LOG, RUNNING, want_tally=True) == []
assert tool.judge(CLEAN_LOG, None) == []  # no engine asked for: nothing to read
assert tool.judge(TEARDOWN_LOG, RUNNING, want_tally=True) == []  # our own SIGTERM is no failure
assert tool.judge(CLEAN_LOG, HARD_STOP)[0] == 'hard stop: monitor fault at 0x1234'
assert tool.judge(CLEAN_LOG, POWERED_OFF) == ['guest power-off']
assert tool.judge(POWER_OFF_LOG, POWERED_OFF) == ['guest power-off']  # one reason, not two
assert tool.judge(POWER_OFF_LOG, None) == ['guest power-off']  # TCG has no tally, and still says so
fault = tool.judge(CLEAN_LOG, USER_FAULT)
assert len(fault) == 1 and fault[0].startswith('1 user FAULT rows') and 'vector 6' in fault[0], fault
assert tool.judge(STALL_LOG, RUNNING) == ['1 no progress reports']
assert tool.judge(STUCK_LOG, RUNNING) == ['1 no progress reports']
assert tool.judge(CLEAN_LOG, RUNNING, qemu_exited=True) == ['QEMU exited']
assert tool.judge(REBOOT_LOG, RUNNING, qemu_exited=True) == ['QEMU exited after a guest reboot']
assert tool.judge(CLEAN_LOG, None, app_exited=True) == ['the app exited']
assert tool.judge(CLEAN_LOG, None, want_tally=True) == ['no tally: the engine never took over']
assert tool.judge(CLEAN_LOG, '# half a tal', want_tally=True) == ['the tally has no outcome line']
assert tool.judge(CLEAN_LOG, '# half a tal') == []  # while running, a tally can be mid-write
assert tool.judge(CLEAN_LOG, RUNNING, desktop_missing='no desktop after 9s: x') == ['no desktop after 9s: x']
assert tool.judge(CLEAN_LOG, RUNNING, program_failure='program exit 3: boom') == ['program exit 3: boom']
assert tool.notes(RUNNING) == ['suspect=1']
assert 'process-log-full' in tool.notes('proc 1\n'*2000)
assert tool.notes(None) == []

case = tool.parse_case('smp2 cpus=2 runs=3 desktop=240 LC_HVDBT_NO_SHARE=1 LC_HVDBT=0', ['LC_HVDBT=1'])
assert (case.name, case.cpus, case.runs, case.desktop, case.seconds) == ('smp2', 2, 3, 240, 0)
assert case.env == {'LC_HVDBT': '0', 'LC_HVDBT_NO_SHARE': '1'}
assert tool.parse_case('plain').seconds == 30
with tempfile.NamedTemporaryFile() as program:
    case = tool.parse_case(f"stress program={program.name} expect='PASSED: 0 failures'")
    assert case.desktop == 300 and case.expect == 'PASSED: 0 failures'
for bad in ('', 'x cpus=two', 'x cpus=0', 'x runs=0', 'x nonsense', 'x lower=1', 'x expect=y', 'x program=/no/such',
            '../x'):
    try:
        tool.parse_case(bad)
    except ValueError:
        continue
    raise AssertionError(bad)

with tempfile.TemporaryDirectory(prefix='boot-matrix-') as temporary:
    tree = Path(temporary, 'tree')
    (tree/'inside').mkdir(parents=True)
    assert tool.remove_tree(tree) and not tree.exists()
print('PASS')
