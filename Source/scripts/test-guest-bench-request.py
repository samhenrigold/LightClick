#!/usr/bin/env python3
"""Exercise the actual request function with a scratch channel and no process/VM."""
import ast
import io
import json
from pathlib import Path
import tempfile
import types
import unittest
from unittest.mock import Mock

source=Path(__file__).with_name('guest-bench')
tree=ast.parse(source.read_text())
request_def=next(n for n in tree.body if isinstance(n,ast.FunctionDef) and n.name=='request')
code=compile(ast.fix_missing_locations(ast.Module(body=[request_def],type_ignores=[])),str(source),'exec')

class Checks(unittest.TestCase):
    def command(self,size,unicode=False):
        value='é😀'*100 if unicode else ''
        base={'data':value}
        fill=size-len(json.dumps(base).encode('utf-8'))
        assert fill>=0
        base['data']+='x'*fill
        self.assertEqual(len(json.dumps(base).encode('utf-8')),size)
        return base

    @staticmethod
    def snapshot(channel):
        return {p.name:(p.read_bytes(),p.stat().st_ino,p.stat().st_mtime_ns) for p in channel.iterdir()}

    def fixture(self,channel,ensure_ascii=True):
        for name in ('Result.json','Request.tmp','Request.json'):(channel/name).write_bytes(('old '+name).encode())
        calls=[]
        def dumps(value):calls.append(value);return json.dumps(value,ensure_ascii=ensure_ascii)
        response={'ExitCode':0,'Stdout':'complete','Stderr':'retained stderr'}
        def poll():
            (channel/'Result.json').write_text(json.dumps(response))
            return None
        def forbidden(*args):raise AssertionError('unexpected wait/timeout processing')
        ns=dict(json=types.SimpleNamespace(dumps=dumps,loads=json.loads),channel=channel,
                time=types.SimpleNamespace(monotonic=lambda:0,sleep=forbidden),process=types.SimpleNamespace(poll=poll),
                work=channel,stderr_path=channel.parent/'stderr.txt',retain_timeout=forbidden)
        exec(code,ns)
        return ns['request'],calls,response

    def test_exact_boundary_accepted_and_serialized_once(self):
        for unicode in (False,True):
            with tempfile.TemporaryDirectory(prefix='lightclick-request-size-') as temporary:
                channel=Path(temporary)/'channel';channel.mkdir();request,calls,response=self.fixture(channel)
                command=self.command(65536,unicode)
                self.assertEqual(request(command,1),response)
                self.assertEqual(calls,[command])
                self.assertEqual((channel/'Request.json').read_bytes(),json.dumps(command).encode('utf-8'))
                self.assertFalse((channel/'Request.tmp').exists())
                self.assertEqual((channel.parent/'stderr.txt').read_text(),'retained stderr')

    def test_one_byte_over_rejected_without_any_channel_mutation(self):
        for unicode in (False,True):
            with tempfile.TemporaryDirectory(prefix='lightclick-request-size-') as temporary:
                channel=Path(temporary)/'channel';channel.mkdir();request,calls,_=self.fixture(channel)
                before=self.snapshot(channel);command=self.command(65537,unicode)
                with self.assertRaisesRegex(ValueError,'65537 UTF-8 bytes; limit is 65536'):
                    request(command,1100)
                self.assertEqual(calls,[command]);self.assertEqual(self.snapshot(channel),before)
                self.assertFalse((channel.parent/'stderr.txt').exists())
                if unicode:self.assertLess(len(command['data']),65536)

    def test_serialization_failure_leaves_channel_untouched(self):
        with tempfile.TemporaryDirectory(prefix='lightclick-request-size-') as temporary:
            channel=Path(temporary)/'channel';channel.mkdir();request,calls,_=self.fixture(channel)
            before=self.snapshot(channel)
            with self.assertRaises(TypeError):request({'unsupported':set()},1)
            self.assertEqual(len(calls),1);self.assertEqual(self.snapshot(channel),before)

    def test_utf8_bytes_not_python_character_count(self):
        # Exercise the byte-counting operation independently of json.dumps'
        # current ASCII-escaping default; a character-count implementation fails.
        for extra in ('','x'):
            with tempfile.TemporaryDirectory(prefix='lightclick-request-size-') as temporary:
                channel=Path(temporary)/'channel';channel.mkdir();request,calls,response=self.fixture(channel,ensure_ascii=False)
                command={'data':'é'*32762+extra};encoded=json.dumps(command,ensure_ascii=False).encode('utf-8')
                self.assertEqual(len(encoded),65536+len(extra));self.assertLess(len(encoded.decode()),65536)
                before=self.snapshot(channel)
                if extra:
                    with self.assertRaisesRegex(ValueError,'65537 UTF-8 bytes'):request(command,1100)
                    self.assertEqual(self.snapshot(channel),before)
                else:
                    self.assertEqual(request(command,1),response)
                    self.assertEqual((channel/'Request.json').read_bytes(),encoded)
                self.assertEqual(calls,[command])

    def test_wall_clock_changes_do_not_extend_request_timeout(self):
        for wall_time in (-1000000,1000000):
            with tempfile.TemporaryDirectory(prefix='lightclick-request-deadline-') as temporary:
                channel=Path(temporary)/'channel';channel.mkdir()
                clock=Mock()
                clock.monotonic.side_effect=[10,10,11,12,13]
                clock.time.side_effect=[1000]+[wall_time]*10
                process=Mock();process.poll.side_effect=[None,None,None,AssertionError('request exceeded elapsed deadline')]
                retained=Mock(return_value='timeout-evidence')
                ns=dict(json=json,channel=channel,time=clock,process=process,work=channel,
                        stderr_path=channel.parent/'stderr.txt',retain_timeout=retained,
                        source=channel,args=types.SimpleNamespace(tag='test'),sys=types.SimpleNamespace(stderr=io.StringIO()))
                exec(code,ns)
                with self.assertRaisesRegex(SystemExit,'Timed out waiting'):
                    ns['request']({'Executable':'/usr/bin/true'},3)
                self.assertEqual(process.poll.call_count,3)
                self.assertEqual(clock.sleep.call_count,3)
                clock.time.assert_not_called()
                retained.assert_called_once()

if __name__=='__main__':unittest.main()
