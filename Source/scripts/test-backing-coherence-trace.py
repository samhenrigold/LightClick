#!/usr/bin/env python3
"""Headless actual refresh behavior comparison and bounded metadata logger checks."""
import argparse
import json
import os
from pathlib import Path
import subprocess
root=Path(__file__).resolve().parents[1]
relative='Source/PassthroughOpenGL/passthrough-opengl-flipped-alias-host.c'
current=(root/'PassthroughOpenGL/passthrough-opengl-flipped-alias-host.c').read_text()
baseline=subprocess.check_output(['git','show','78b0e60d:'+relative],cwd=root,text=True)
def function(s):
 start=s.index('static void DGRefreshFlippedAliases(');at=s.index('{',start)+1;depth=1
 while depth:
  depth+=(s[at]=='{')-(s[at]=='}');at+=1
 return s[start:at]
def emit(path):
 old,new=function(baseline),function(current)
 prefix=r'''
#include <assert.h>
#include HEADER
typedef unsigned GLuint;typedef int GLint;
#define GL_INVALID_OPERATION 0x502
struct DGAlias{unsigned source_storage,texture;uint64_t copied_serial;struct DGAlias *next;};
struct Group{struct DGAlias *aliases;};
struct Drawable{uint64_t write_serial;};
struct DGHostContext{int inside_begin;struct Drawable *drawable;unsigned color_storage,back_storage;struct Group *alias_group;GLint texture_units;GLuint *sampled_textures;int error;};
static int fail,copies;static unsigned IOSurfaceGetID(unsigned s){return s;}
static int DGCopyFlippedAlias(struct DGHostContext *c,struct DGAlias *a){copies++;if(!fail)a->copied_serial=c->drawable->write_serial;return !fail;}
static void DGCoherenceTrace(struct DGHostContext *c,struct DGAlias *a,unsigned kind,int okay,uint64_t before){(void)c;(void)a;(void)kind;(void)okay;(void)before;}
'''.replace('HEADER',json.dumps(str(root/'PassthroughOpenGL/backing-coherence-trace.h')))
 tests=r'''
int main(int argc,char **argv){assert(argc==2);
 if(!strcmp(argv[1],"bounds")){
  assert(VIMCoherenceEnabled());struct VIMCoherenceRow r={.kind=VIM_COHERENCE_UNCHANGED,.okay=1};
  for(int i=0;i<400;i++)VIMCoherenceEmit(&r);
  r=(struct VIMCoherenceRow){.kind=VIM_COHERENCE_ALIAS_WRITE,.okay=1,.storage=9,.current_front=1,.matching_sources=1};
  for(int i=0;i<400;i++)VIMCoherenceEmit(&r);
  return 0;
 }
 for(unsigned storage=0;storage<4;storage++)for(unsigned front=0;front<4;front++)for(unsigned back=0;back<4;back++)for(unsigned match=0;match<2;match++)for(unsigned kind=0;kind<5;kind++){
  struct VIMCoherenceRow r={.kind=kind,.okay=1,.storage=storage,.current_front=front,.current_back=back,.matching_sources=match};
  int expected=kind==VIM_COHERENCE_ALIAS_WRITE&&storage&&storage!=front&&storage!=back;
  assert(VIMCoherenceForeignCandidate(&r)==expected);assert(VIMCoherenceAnomaly(&r)==(expected&&match));
  r.okay=0;assert(VIMCoherenceAnomaly(&r));
 }
 for(int begin=0;begin<2;begin++)for(int sampled=0;sampled<2;sampled++)for(fail=0;fail<2;fail++)for(unsigned prior=0;prior<2;prior++)for(unsigned serial=0;serial<3;serial++){
  struct Drawable d={1};GLuint textures[2]={12,0};
  struct DGAlias aliases[3]={{1,11,serial,NULL},{2,12,serial,NULL},{3,13,serial,NULL}};
  aliases[0].next=&aliases[1];aliases[1].next=&aliases[2];struct Group group={aliases};
  struct DGHostContext c={begin,&d,1,2,&group,2,textures,prior};copies=0;
  baseline_refresh(&c,sampled);int oldcopies=copies,olderror=c.error;uint64_t saved[3];for(int i=0;i<3;i++){saved[i]=aliases[i].copied_serial;aliases[i].copied_serial=serial;}
  c.error=prior;copies=0;DGRefreshFlippedAliases(&c,sampled);assert(copies==oldcopies&&c.error==olderror);for(int i=0;i<3;i++)assert(saved[i]==aliases[i].copied_serial);
 }
 if(VIMCoherenceEnabled()){
  struct VIMCoherenceRow r={.kind=VIM_COHERENCE_REFRESH_COPY,.okay=1};VIMCoherenceEmit(&r);
 }
 return 0;
}
'''
 path.write_text(prefix+old.replace('DGRefreshFlippedAliases(','baseline_refresh(',1)+new+tests)
 print('Wrote',path)
def check(binary):
 for value in (None,'0','true','01'):
  env=dict(os.environ);env.pop('VIM_BACKING_COHERENCE_TRACE',None)
  if value is not None:env['VIM_BACKING_COHERENCE_TRACE']=value
  p=subprocess.run([str(binary),'mechanism'],env=env,capture_output=True,text=True,check=True,timeout=10);assert not p.stderr
 env=dict(os.environ,VIM_BACKING_COHERENCE_TRACE='1')
 p=subprocess.run([str(binary),'mechanism'],env=env,capture_output=True,text=True,check=True,timeout=10)
 assert 'enabled=1' in p.stderr and 'summary=1 snapshot_not_atomic=1' in p.stderr
 assert p.stderr.count('write_coverage=imported_aliases_only generic_alias_writes=unknown')==2
 p=subprocess.run([str(binary),'bounds'],env=env,capture_output=True,text=True,check=True,timeout=10)
 lines=p.stderr.splitlines();assert len(lines)==260,len(lines)
 assert sum('event=' in x for x in lines)==256
 assert sum('routine_rows_truncated=1' in x for x in lines)==1
 assert sum('anomaly_rows_truncated=1' in x for x in lines)==1
 assert 'event=401' in p.stderr
 assert 'events=800 anomalies=400 unchanged=400 unselected=0 refresh_copy=0 bind_copy=0 alias_write=400 foreign_candidate_writes=400 matched_source_writes=400' in p.stderr
 print('PASS actual refresh copy/error/serial decisions unchanged, classifier, exact opt-in silence and260-line bound with late anomaly reserve')
if __name__=='__main__':
 p=argparse.ArgumentParser(description=__doc__);g=p.add_mutually_exclusive_group(required=True);g.add_argument('--emit-c',type=Path);g.add_argument('--check',type=Path);a=p.parse_args();emit(a.emit_c) if a.emit_c else check(a.check)
