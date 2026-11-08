#!/usr/bin/env python3
"""Mock actual guest supervisor/processes and host chunk protocol. Never execute verifier/AVFoundation."""
from pathlib import Path
import base64
import copy
import hashlib
import io
import json
import os
import re
import stat
import struct
import subprocess
import sys
import tempfile
import types
import unittest
from unittest import mock
import zlib

import fcp_export as module

FIXTURE='/private/var/tmp/LightClickFCPFixture.ABC123'
HELPER='/private/var/tmp/LightClickFCP.ABC123/export-verify'
PIN='125b717c73e6d737eb5dfa8eb0dc34dcc521cfeffa7343c3b621d69ca785559d'
PAYLOAD=b'mocked immutable verifier bytes; never executable'

class Hashlib:
    @staticmethod
    def sha256(data=b''):
        return types.SimpleNamespace(hexdigest=lambda:PIN)if data==PAYLOAD else hashlib.sha256(data)

class MappedOS:
    """Actual temporary output files behind strictly fixed guest paths; no real /var/tmp writes."""
    def __init__(self,root):self.root=Path(root);self.path=types.SimpleNamespace(realpath=lambda p:p)
    def mapped(self,path):
        if path.startswith(FIXTURE):return str(self.root/'fixture')+path[len(FIXTURE):]
        if path.startswith(HELPER.rsplit('/',1)[0]):return str(self.root/'helper')+path[len(HELPER.rsplit('/',1)[0]):]
        return path
    def __getattr__(self,name):return getattr(os,name)
    def getuid(self):return 501
    def uname(self):return ('Darwin','','13.4.0')
    @property
    def environ(self):return dict(os.environ)
    def adjusted(self,info):
        names=('st_dev','st_ino','st_mode','st_nlink','st_size','st_mtime','st_ctime')
        return types.SimpleNamespace(**dict({k:getattr(info,k)for k in names},st_uid=501))
    def stat(self,path):return types.SimpleNamespace(st_uid=501)if path=='/dev/console'else self.adjusted(os.stat(self.mapped(path)))
    def lstat(self,path):return self.adjusted(os.lstat(self.mapped(path)))
    def fstat(self,fd):return self.adjusted(os.fstat(fd))
    def open(self,path,*args):return os.open(self.mapped(path),*args)

class Checks(unittest.TestCase):
    def supervise(self,case='success'):
        with tempfile.TemporaryDirectory(prefix='lightclick-export-supervisor-')as tmp:
            root=Path(tmp);(root/'fixture').mkdir(mode=0o700);(root/'helper').mkdir(mode=0o700);(root/'helper/home').mkdir(mode=0o700)
            (root/'helper/export-verify').write_bytes(PAYLOAD);(root/'helper/export-verify').chmod(0o755);(root/'fixture/export.mov').write_bytes(b'owned candidate')
            fakeos=MappedOS(root);clock=[0.];launched=[];stopped=[];signals=[];wall=[1000000.]
            app=types.SimpleNamespace(pid=321,poll=lambda:-11 if case=='app-already-exited' else 0 if case=='app-exits'and launched else None)
            actor=dict(result='PRIVATE_EXPORT_CANDIDATE_REQUIRES_MEDIA_VERIFICATION',mode='export-h264-private-fixture',variant='10.1',pid=321,outputPath=FIXTURE+'/export.mov',exportSaveActionStatus=-25204)
            for key in('identityMatched','identityStillMatched','axTrusted','privateFixtureValid','exportAttempted','savePressed','privateExportControlsVerified','pathNavigationVerified','candidateFileVerified'):actor[key]=True
            spec=dict(variant='10.1',workflow_export_action_mode='export-h264-private-fixture',workflow_export_action=actor,workflow_export_verifier=HELPER,workflow_export_verifier_sha256=PIN)
            good=dict(result='MEDIA_STRUCTURE_VALID_FIDELITY_REQUIRES_REVIEW',report_complete=True,media_structure_qualified=True,files_stable_after_verification=True,fidelity_qualified=False,inline_pngs=[],padding='x'*180000)
            if case=='incomplete':good['report_complete']=False
            if case=='string-flag':actor['savePressed']='true'
            if case=='wrong-mode':spec['workflow_export_action_mode']='other'
            if case=='wrong-pid':actor['pid']=999
            if case=='wrong-path':actor['outputPath']='/Users/owner/document.mov'
            if case=='wrong-sha':spec['workflow_export_verifier_sha256']='0'*64
            if case=='collision':(root/'fixture/export-verification.json').write_bytes(b'preserve preexisting')
            raw=json.dumps(good).encode()+b'\n'
            if case=='malformed':raw=b'{bad JSON\n'
            if case=='dyld-no-stdout':raw=b''
            if case=='stdout-overflow':raw=b'x'*524290
            class Child:
                def __init__(self,argv,**kwargs):
                    self.code=None;self.pid=888;self.argv=argv;self.polls=0
                    self_outer.assertEqual(argv,[HELPER,FIXTURE]);self_outer.assertTrue(callable(kwargs['preexec_fn']));self_outer.assertIsInstance(kwargs['stdout'],int);self_outer.assertIsInstance(kwargs['stderr'],int)
                    os.write(kwargs['stdout'],raw);os.write(kwargs['stderr'],b'e'*8193 if case=='stderr-overflow'else b'dyld: missing symbol\n' if case=='dyld-no-stdout'else b'')
                    launched.append(self)
                def poll(self):
                    self.polls+=1
                    if self.code is None and case not in('timeout','app-exits','wall-rollback','term-ignored','wrong-group','unreaped','mach-fallback'):self.code=7 if case=='nonzero'else -5 if case=='dyld-no-stdout'else 0
                    return self.code
            def stop(child):raise AssertionError('existing wall-clock stop must not be used')
            fakeos.getpgid=lambda pid:777 if case=='wrong-group'else pid
            def killpg(pid,sig):
                self.assertEqual(pid,888);self.assertNotEqual(pid,app.pid);signals.append((pid,sig));stopped.append(launched[0])
                if case!='unreaped'and not(case=='term-ignored'and sig==15):launched[0].code=-sig
            fakeos.killpg=killpg
            def sleep(seconds):
                clock[0]+=seconds
                wall[0]-=1000000 if case=='wall-rollback'else -seconds
            self_outer=self
            ns=dict(json=json,os=fakeos,stat=stat,hashlib=Hashlib,subprocess=types.SimpleNamespace(Popen=Child),time=types.SimpleNamespace(monotonic=lambda:clock[0],time=lambda:wall[0],sleep=sleep),owned=[app],limits=lambda:None,stop=stop,current_executable=lambda pid:'/usr/bin/other' if case=='app-exec-changed' and launched else '/Applications/Final Cut Pro.app/Contents/MacOS/Final Cut Pro')
            exec(compile(module.guest_export_source(),'<actual guest supervisor>','exec'),ns)
            if case=='mach-fallback':
                del ns['time'].monotonic
                initialized=[]
                def absolute():return int(clock[0]*1000000000)
                def timebase(pointer):initialized.append(True);pointer._obj.numer=1;pointer._obj.denom=1;return 0
                library=types.SimpleNamespace(mach_absolute_time=absolute,mach_timebase_info=timebase)
                with mock.patch('ctypes.CDLL',return_value=library)as load:
                    result=ns['run_private_export_verifier'](spec,app,FIXTURE)
                    self.assertEqual(load.call_args.args,('/usr/lib/libSystem.B.dylib',));self.assertEqual(load.call_count,1)
                self.assertEqual(len(initialized),1)
            else:result=ns['run_private_export_verifier'](spec,app,FIXTURE)
            files={p.name:p.read_bytes()for p in(root/'fixture').iterdir()if p.is_file()}
            if case in('string-flag','wrong-mode','wrong-pid','wrong-path','wrong-sha','collision','app-already-exited'):self.assertFalse(launched)
            else:self.assertEqual(len(launched),1)
            if case=='success':
                self.assertTrue(result['structure_qualified']);self.assertEqual(result['save_action_status'],-25204);self.assertGreater(result['stdout_receipt']['bytes'],131072);self.assertNotIn('inline_pngs',json.dumps(result));self.assertEqual(files['export-verification.json'],raw)
            else:self.assertFalse(result['structure_qualified'])
            self.assertEqual(result['app_alive_before'],case!='app-already-exited')
            self.assertEqual(result['app_alive_after'],case not in('app-already-exited','app-exits','app-exec-changed'))
            if case=='dyld-no-stdout':
                self.assertEqual(result['exit_code'],-5);self.assertEqual(result['stdout_receipt']['bytes'],0)
                self.assertIn('dyld: missing symbol',result['stderr_preview']);self.assertEqual(files['export-verification.json'],b'')
            if case=='collision':self.assertEqual(files['export-verification.json'],b'preserve preexisting')
            if case=='app-already-exited':
                self.assertEqual(result['app_exit_code_before'],-11);self.assertEqual(result['app_exit_code_after'],-11)
            if case in('timeout','app-exits','wall-rollback','mach-fallback'):self.assertEqual(len(stopped),1);self.assertIs(stopped[0],launched[0]);self.assertEqual(signals,[(888,15)])
            if case in('timeout','wall-rollback','mach-fallback'):
                self.assertTrue(result['timed_out']);self.assertGreaterEqual(result['elapsed_seconds'],66);self.assertLess(clock[0],67)
            if case=='wall-rollback':self.assertLess(wall[0],0)
            if case=='term-ignored':self.assertEqual(signals,[(888,15),(888,9)]);self.assertLess(clock[0],69)
            if case=='unreaped':self.assertEqual(signals,[(888,15),(888,9)]);self.assertIn('cleanup_error',result);self.assertLess(clock[0],70.2)
            if case=='wrong-group':self.assertEqual(signals,[]);self.assertIn('process group changed',result['error'])
            if case=='stderr-overflow':self.assertTrue(result['stderr_policy_overflow']);self.assertEqual(files['export-verification.stderr'],b'e'*8193);self.assertTrue(result['stderr_preview_truncated'])
            if case=='stdout-overflow':self.assertTrue(result['stdout_policy_overflow']);self.assertEqual(len(files['export-verification.json']),524290)
            if case=='malformed':self.assertEqual(files['export-verification.json'],raw);self.assertIn('sha256',result['stdout_receipt'])
            return result

    def test_supervisor_actual_file_process_boundaries(self):
        for case in('success','incomplete','string-flag','wrong-mode','wrong-pid','wrong-path','wrong-sha','collision','nonzero','dyld-no-stdout','timeout','app-exits','app-already-exited','app-exec-changed','stderr-overflow','stdout-overflow','malformed','wall-rollback','term-ignored','wrong-group','unreaped','mach-fallback'):
            with self.subTest(case=case):self.supervise(case)

    @staticmethod
    def png(width=320,height=180):
        def chunk(kind,data):return struct.pack('>I',len(data))+kind+data+struct.pack('>I',zlib.crc32(kind+data)&0xffffffff)
        return b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',width,height,8,6,0,0,0))+chunk(b'IDAT',zlib.compress((b'\0'+b'\0'*width*4)*height))+chunk(b'IEND',b'')

    def fetch(self,case='success'):
        png=self.png(640 if case=='wrong-png'else 320);encoded=base64.b64encode(png).decode()
        report={'result':'MEDIA_STRUCTURE_VALID_FIDELITY_REQUIRES_REVIEW','report_complete':True,'media_structure_qualified':True,'files_stable_after_verification':True,'fidelity_qualified':False,'output_file':dict(device=77,inode=99,uid=501,bytes=10),'output_sha256':hashlib.sha256(b'moviebytes').hexdigest(),'inline_pngs':[dict(frame=n,source_png_base64=encoded,output_png_base64=encoded)for n in(0,30,120,239)]}
        if case=='structure-failed':report['report_complete']=False
        if case=='duplicate-png':report['inline_pngs'][3]['frame']=120
        if case=='missing-png':report['inline_pngs'].pop()
        raw=json.dumps(report).encode()
        if case=='max-size':
            report['inline_pngs']=[];report['padding']='';size=len(json.dumps(report).encode());report['padding']='x'*(524288-size);raw=json.dumps(report).encode()+b'\n';self.assertEqual(len(raw),524289)
        if case=='malformed-json':raw=b'{bad JSON'
        receipt=dict(path=FIXTURE+'/export-verification.json',device=1,inode=22,uid=501,mode=0o600,nlink=1,bytes=len(raw),mtime=123.25,ctime=123.25,sha256=hashlib.sha256(raw).hexdigest())
        if case=='oversize':receipt['bytes']=524290
        if case=='nonce-path':receipt['path']=FIXTURE.replace('ABC123','DEF456')+'/export-verification.json'
        calls=[]
        def request(command,seconds):
            calls.append(command);e=json.loads(command['Arguments'][2])
            if command['Arguments'][1]==module.CLOSED_MEDIA_GUEST:
                self.assertLessEqual(seconds,45);self.assertEqual(e['fixture_directory'],FIXTURE)
                if case=='closed-timeout':raise SystemExit('ambiguous closed movie query')
                value=dict(result='CLOSED_MEDIA_BYTES_MATCH',path=FIXTURE+'/export.mov',identity=dict(report['output_file']),sha256=report['output_sha256'],bytes=10)
                if case=='closed-mutated':value['sha256']='0'*64
                return dict(ExitCode=0,Stdout=json.dumps(value))
            self.assertLessEqual(seconds,12);offset,length=e['offset'],e['length'];piece=raw[offset:offset+length]
            if case=='ambiguous':raise SystemExit('host timeout')
            identity={k:receipt[k]for k in('device','inode','uid','mode','nlink','bytes','mtime','ctime')}
            if case=='wrong-inode':identity['inode']+=1
            item=dict(identity=identity,offset=offset,bytes=len(piece),whole_sha256=receipt['sha256'],sha256='0'*64 if case=='corrupt-chunk'else hashlib.sha256(piece).hexdigest(),base64=base64.b64encode(piece).decode())
            return dict(ExitCode=False if case=='bool-exit'else 0,Stdout=json.dumps(item))
        with tempfile.TemporaryDirectory(prefix='lightclick-export-fetch-')as tmp:
            out=Path(tmp)/'new'
            if case=='no-overwrite':out.mkdir();(out/'keep').write_text('keep')
            bad=case not in('success','max-size','closed-mutated','structure-failed','missing-png')
            try:result=module.fetch_private_export_report(request,receipt,FIXTURE,501,out)
            except (ValueError,FileExistsError,SystemExit):self.assertTrue(bad)
            else:
                self.assertFalse(bad);self.assertEqual((out/'export-verification.json').read_bytes(),raw);self.assertEqual(len(result['thumbnail_artifacts']),0 if case=='max-size'else 6 if case=='missing-png'else 8)
                self.assertEqual(result['thumbnails_complete'],case not in('max-size','missing-png'))
                self.assertEqual(result['closed_media_revalidated'],case in('success','max-size','missing-png'))
            self.assertLessEqual(len(calls),4)
            if case in('nonce-path','oversize','no-overwrite'):self.assertFalse(calls)
            if case=='ambiguous':self.assertEqual(len(calls),1)
            if case=='closed-timeout':self.assertEqual(calls[-1]['Arguments'][1],module.CLOSED_MEDIA_GUEST);self.assertTrue((out/'export-verification.json').exists())
            if case=='closed-mutated':self.assertEqual(result['result'],'REPORT_FETCHED_CLOSED_MEDIA_UNQUALIFIED');self.assertTrue((out/'export-verification.json').exists())
            if case=='structure-failed':self.assertFalse(any(c['Arguments'][1]==module.CLOSED_MEDIA_GUEST for c in calls))
            if case=='malformed-json':self.assertFalse((out/'export-verification.json').exists());self.assertEqual((out/'export-verification.json.partial').read_bytes(),raw)
            if case in('wrong-png','duplicate-png','missing-png'):self.assertEqual((out/'export-verification.json').read_bytes(),raw)
            if case=='no-overwrite':self.assertEqual((out/'keep').read_text(),'keep')

    def test_fetch_corruption_paths_size_and_exclusive_publish(self):
        for case in('success','max-size','nonce-path','oversize','no-overwrite','ambiguous','corrupt-chunk','wrong-inode','bool-exit','malformed-json','wrong-png','duplicate-png','missing-png','closed-mutated','closed-timeout','structure-failed'):
            with self.subTest(case=case):self.fetch(case)

    def test_actual_closed_movie_query_hash_and_identity(self):
        import ast
        tree=ast.parse(module.CLOSED_MEDIA_GUEST);tree.body=[n for n in tree.body if not isinstance(n,(ast.Import,ast.ImportFrom))]
        with tempfile.TemporaryDirectory(prefix='lightclick-closed-media-')as tmp:
            root=Path(tmp);(root/'fixture').mkdir(mode=0o700);raw=b'known closed movie bytes';(root/'fixture/export.mov').write_bytes(raw);fakeos=MappedOS(root);info=fakeos.lstat(FIXTURE+'/export.mov')
            output_file=dict(device=info.st_dev,inode=info.st_ino,uid=501,bytes=len(raw))
            for case in ('good','inode','hash','symlink','wrong-parent-uid'):
                e=dict(fixture_directory=FIXTURE,uid=501,output_file=dict(output_file),output_sha256=hashlib.sha256(raw).hexdigest())
                if case=='inode':e['output_file']['inode']+=1
                if case=='hash':e['output_sha256']='0'*64
                if case=='symlink':fakeos.path.realpath=lambda p:p+'/escaped'if p.endswith('.mov')else p
                else:fakeos.path.realpath=lambda p:p
                if case=='wrong-parent-uid':e['uid']=999
                stream=io.StringIO();ns=dict(hashlib=hashlib,json=json,os=fakeos,re=re,signal=types.SimpleNamespace(alarm=lambda seconds:None),stat=stat,sys=types.SimpleNamespace(argv=['guest',json.dumps(e)],stdout=stream))
                try:exec(compile(tree,'<actual closed movie postcheck>','exec'),ns)
                except ValueError:self.assertNotEqual(case,'good')
                else:self.assertEqual(case,'good');self.assertEqual(json.loads(stream.getvalue())['sha256'],e['output_sha256'])
        self.assertIn('signal.alarm(35)',module.CLOSED_MEDIA_GUEST)
        self.assertNotIn('subprocess',module.CLOSED_MEDIA_GUEST)

    def test_actual_guest_chunk_scope_and_identity(self):
        import ast
        tree=ast.parse(module.REPORT_CHUNK_GUEST);tree.body=[n for n in tree.body if not isinstance(n,(ast.Import,ast.ImportFrom))]
        with tempfile.TemporaryDirectory(prefix='lightclick-export-chunk-')as tmp:
            root=Path(tmp);(root/'fixture').mkdir(mode=0o700);raw=b'{"report_complete":true}\n';(root/'fixture/export-verification.json').write_bytes(raw);(root/'fixture/export-verification.json').chmod(0o600);fakeos=MappedOS(root);info=fakeos.lstat(FIXTURE+'/export-verification.json')
            receipt=dict(path=FIXTURE+'/export-verification.json',device=info.st_dev,inode=info.st_ino,uid=501,mode=0o600,nlink=1,bytes=len(raw),mtime=info.st_mtime,ctime=info.st_ctime,sha256=hashlib.sha256(raw).hexdigest())
            for case in('good','nonce','inode','whole-hash','range','symlink'):
                e=dict(fixture_directory=FIXTURE,uid=501,receipt=copy.deepcopy(receipt),offset=0,length=len(raw))
                if case=='nonce':e['receipt']['path']=FIXTURE.replace('ABC123','DEF456')+'/export-verification.json'
                if case=='inode':e['receipt']['inode']+=1
                if case=='whole-hash':e['receipt']['sha256']='0'*64
                if case=='range':e['length']=196609
                if case=='symlink':fakeos.path.realpath=lambda p:p+'/escaped'if p.endswith('.json')else p
                stream=io.StringIO();ns=dict(hashlib=hashlib,base64=base64,json=json,os=fakeos,re=re,signal=types.SimpleNamespace(alarm=lambda seconds:None),stat=stat,sys=types.SimpleNamespace(argv=['guest',json.dumps(e)],stdout=stream))
                try:exec(compile(tree,'<actual guest fixed-file chunk>','exec'),ns)
                except ValueError:self.assertNotEqual(case,'good')
                else:self.assertEqual(case,'good');self.assertEqual(base64.b64decode(json.loads(stream.getvalue())['base64']),raw)
        compile(module.guest_export_source(),'<guest syntax>','exec')
        self.assertNotIn('subprocess.PIPE',module.guest_export_source())
        self.assertIn('resource.setrlimit(resource.RLIMIT_FSIZE, (limit, limit))',module.guest_export_source())

if __name__=='__main__':unittest.main()
