#!/usr/bin/env python3
"""Actual guest pipe reader: short live records, byte cap and interrupted reads; no app/VM."""
import ast
import errno
import os
import threading
import time
import types
import unittest
from fcp_preflight import GUEST


class Checks(unittest.TestCase):
    def reader(self, cap=131072, interrupt=False):
        tree=ast.parse(GUEST)
        selected=[n for n in tree.body if isinstance(n,ast.FunctionDef) and n.name in ('reader','captured')]
        self.assertEqual(len(selected),2)
        reads=[0]
        def read(fd,size):
            reads[0]+=1
            if interrupt and reads[0]==1:raise OSError(errno.EINTR,'fixture interruption')
            return os.read(fd,size)
        scope=dict(os=types.SimpleNamespace(read=read),errno=errno,threading=threading,CAP=cap)
        exec(compile(ast.Module(body=selected,type_ignores=[]),'<actual guest reader>','exec'),scope)
        return scope

    def exchange(self, payload, cap=131072, interrupt=False):
        scope=self.reader(cap,interrupt);r,w=os.pipe();stream=os.fdopen(r,'rb');pair=scope['reader'](stream)
        try:
            os.write(w,payload)
            until=time.monotonic()+1
            while pair[0]['bytes']<len(payload) and time.monotonic()<until:time.sleep(.002)
            self.assertEqual(pair[0]['bytes'],len(payload),'short pipe record must be observable before EOF')
            self.assertTrue(pair[1].is_alive(),'writer remains open during observation')
        finally:
            os.close(w);pair[1].join(2)
        self.assertFalse(pair[1].is_alive())
        self.assertTrue(stream.closed)
        return scope['captured'](pair)

    def test_short_record_without_eof(self):
        result=self.exchange(b'event=armed\n')
        self.assertEqual(result['text'],'event=armed\n')
        self.assertTrue(result['reader_finished']);self.assertFalse(result['at_limit'])

    def test_cap_retains_prefix_and_counts_all_bytes(self):
        result=self.exchange(b'0123456789',cap=7)
        self.assertEqual(result['text'],'0123456');self.assertEqual(result['bytes'],10);self.assertTrue(result['at_limit'])

    def test_interrupted_read_preserves_record(self):
        self.assertEqual(self.exchange(b'complete\n',interrupt=True)['text'],'complete\n')


if __name__=='__main__':unittest.main()
