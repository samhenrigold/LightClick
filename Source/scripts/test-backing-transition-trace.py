#!/usr/bin/env python3
"""Actual trace ring/file checks plus original renderer logic preservation; no GL/guest execution."""
import argparse
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import uuid
root=Path(__file__).resolve().parents[1]

def function(s,name):
 match=re.search(r'(?m)^static [^\n]*\b'+re.escape(name)+r'\([^;]*?\)\s*\{',s);assert match,name
 at=match.end();depth=1
 while depth:
  depth+=(s[at]=='{')-(s[at]=='}');at+=1
 return s[match.start():at]

def source_checks():
 for filename,names in {
  'passthrough-opengl-host.c':['DGResize','DGSelectDrawableMode','DGImportDrawableSurface','DGDrawablePixels'],
  'passthrough-opengl-surfaces-host.c':['DGSurfaceCommandImpl'],
 }.items():
  relative='Source/PassthroughOpenGL/'+filename
  before=subprocess.check_output(['git','show','2fc14d88c4a45908fbc52ed37a4d60537a514c83:'+relative],cwd=root,text=True)
  after=(root/'PassthroughOpenGL'/filename).read_text()
  for name in names:
   old=function(before,name);new=function(after,name)
   new='\n'.join(line for line in new.splitlines() if not any(word in line for word in ('DGTransition','trace_before','trace_after','trace_upload','selected_before')))
   assert re.sub(r'\s+','',old)==re.sub(r'\s+','',new),name+' changed beyond diagnostic statements'
 s=(root/'PassthroughOpenGL/passthrough-opengl-host.c').read_text()
 cleanup=function(s,'DGInterpreterDestroy')
 assert cleanup.index('VIMTransitionFinish(s->transition)')<cleanup.index('free(s)')
 assert s.index('#include "backing-transition-trace-host.c"')>s.index('struct DGHostDrawable {')
 assert 'if(m->op==DG_OP_blit_framebuffer_EXT)DGTransitionBlit(context,m);' in s
 helper=(root/'PassthroughOpenGL/backing-transition-trace-host.c').read_text()
 for forbidden in ('glGet','glRead','glFinish','glFlush','glBind','glFence','CGEvent'):
  assert forbidden not in helper

def emit(path):
 source_checks()
 header=json.dumps(str(root/'PassthroughOpenGL/backing-transition-trace.h'))
 body=r'''
#include <assert.h>
#include HEADER
_Static_assert(_Generic(vim_transition_session,uintptr_t:1,default:0),"TLS must be scalar identity, never a heap pointer");
_Static_assert(sizeof(vim_transition_rows)<=2u*1024u*1024u,"fixed ring memory bound");
static void *close_session(void *opaque){VIMTransitionFinish(opaque);return NULL;}
int main(int argc,char **argv){
 if(!VIMTransitionEnabled())return 0;
 struct VIMTransitionState *a=VIMTransitionStart(0x111),*b=VIMTransitionStart(0x222);assert(a&&b);
 vim_transition_session=a->session;
 for(unsigned i=0;i<9000;i++){
  struct VIMTransitionRow r={0};r.kind=i%VIM_TRANSITION_KINDS;r.context=0x333;r.drawable=7;r.front=11;r.back=12;r.double_buffer=1;
  for(unsigned j=0;j<10;j++)r.args[j]=UINT64_MAX;
  VIMTransitionAppend(r);
 }
 pthread_t closer;assert(!pthread_create(&closer,NULL,close_session,a));assert(!pthread_join(closer,NULL));
 assert(vim_transition_session==0x111); /* Stale scalar is harmless; next dispatch replaces it. */
 vim_transition_session=b->session;
 struct VIMTransitionRow r={.kind=VIM_TRANSITION_BLIT,.context=0x444};VIMTransitionAppend(r);
 if(argc>1 && !strcmp(argv[1],"live"))return 0; /* b deliberately stays live through normal exit. */
 if(argc>1 && !strcmp(argv[1],"freeze")){
  VIMTransitionShutdown();uint64_t frozen=vim_transition_total;
  VIMTransitionAppend(r);assert(vim_transition_total==frozen);
  uint64_t started=vim_transition_started;assert(!VIMTransitionStart(0x555));assert(vim_transition_started==started);
  VIMTransitionFinish(b);
  _exit(0); /* Late endpoint cleanup must not overwrite final shutdown snapshot. */
 }
 VIMTransitionFinish(b);
 _exit(0); /* Explicit cleanup must persist data without running C destructors. */
}
'''.replace('HEADER',header)
 path.write_text(body);print('Wrote',path)

def fresh():return Path('/private/tmp/lightclick-transition-test-'+uuid.uuid4().hex+'.trace')
def run(binary,env,args=()):return subprocess.run([str(binary),*args],env=env,capture_output=True,text=True,check=True,timeout=15)
def check(binary):
 source_checks()
 for value in (None,'0','true','01'):
  env=dict(os.environ);env.pop('VIM_BACKING_TRANSITION_TRACE',None);env.pop('VIM_BACKING_TRANSITION_TRACE_PATH',None)
  if value is not None:env['VIM_BACKING_TRANSITION_TRACE']=value
  output=fresh();env['VIM_BACKING_TRANSITION_TRACE_PATH']=str(output)
  assert run(binary,env).stderr=='';assert not output.exists()
 for path in (None,'relative.trace','/Users/forbidden.trace','/private/tmp/other.trace','/private/tmp/lightclick-dir/nested.trace'):
  env=dict(os.environ,VIM_BACKING_TRANSITION_TRACE='1');env.pop('VIM_BACKING_TRANSITION_TRACE_PATH',None)
  if path is not None:env['VIM_BACKING_TRANSITION_TRACE_PATH']=path
  assert 'refused=output_path_required' in run(binary,env).stderr
 output=fresh();target=fresh();link=fresh()
 try:
  target.write_bytes(b'unchanged');link.symlink_to(target)
  env=dict(os.environ,VIM_BACKING_TRANSITION_TRACE='1',VIM_BACKING_TRANSITION_TRACE_PATH=str(link))
  assert 'refused=private_output_creation' in run(binary,env).stderr;assert target.read_bytes()==b'unchanged'
  env['VIM_BACKING_TRANSITION_TRACE_PATH']=str(target)
  assert 'refused=private_output_creation' in run(binary,env).stderr;assert target.read_bytes()==b'unchanged'
  env['VIM_BACKING_TRANSITION_TRACE_PATH']=str(output)
  result=run(binary,env);assert result.stderr.count('enabled=1')==1
  text=output.read_text();lines=text.splitlines();assert len(lines)==8194,len(lines)
  assert 'total=9001 retained=8192 overwritten=809 started_sessions=2 closed_sessions=2' in lines[0]
  assert 'reason=endpoint_cleanup quiescence_unverified=1' in lines[0]
  assert 'coverage=overwritten_not_complete' in lines[0]
  assert 'blit_default_binding_unverified=1 swap_api_unverified=1' in lines[0]
  assert lines[1].startswith('event=810 ') and lines[-2].startswith('event=9001 ')
  assert 'session=222' in lines[-2] and 'context=444' in lines[-2]
  assert lines[-1].endswith('snapshot_end=1 total=9001')
  assert stat.S_IMODE(output.stat().st_mode)==0o600
  assert output.stat().st_size<8192*1024+2048
  for mode in ('live','freeze'):
   final=fresh()
   try:
    env['VIM_BACKING_TRANSITION_TRACE_PATH']=str(final)
    run(binary,env,(mode,));last=final.read_text().splitlines()
    assert len(last)==8194
    assert 'reason=process_shutdown quiescence_unverified=1' in last[0]
    assert 'total=9001 retained=8192 overwritten=809 started_sessions=2 closed_sessions=1' in last[0]
    assert last[-2].startswith('event=9001 ') and 'context=444' in last[-2]
    assert last[-1].endswith('snapshot_end=1 total=9001')
    assert final.stat().st_size<8192*1024+2048
   finally:final.unlink(missing_ok=True)
 finally:
  for p in (output,link,target):p.unlink(missing_ok=True)
 print('PASS actual8192 ring tail/global accounting/private exclusive output/refusals/cross-thread close/scalarTLS/endpoint and live-endpoint shutdown persistence/frozen final tail; renderer logic unchanged; no graphics execution')
if __name__=='__main__':
 p=argparse.ArgumentParser(description=__doc__);g=p.add_mutually_exclusive_group(required=True);g.add_argument('--emit-c',type=Path);g.add_argument('--check',type=Path);a=p.parse_args();emit(a.emit_c) if a.emit_c else check(a.check)
