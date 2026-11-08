#!/usr/bin/env python3
"""Headless tests: execute only extracted release predicate, never AX/event helper."""
from pathlib import Path
import subprocess
import tempfile

source=(Path(__file__).resolve().parents[1]/'probes/fcp-ax-actions.m').read_text()
start=source.index('static BOOL darwin13Release(')
end=source.index('static BOOL guestDarwin13(',start)
predicate=source[start:end]
fixture='''#include <assert.h>
#include <string.h>
typedef int BOOL;
#define YES 1
#define NO 0
'''+predicate+'''
int main(void){
 const char *accepted[]={"13.0.0","13.4.0","13.9.99"};
 const char *refused[]={"","13","13.","13.x.0","13.4.0x","12.6.0","14.0.0","27.2.0","113.4.0","13.4.0\\n"};
 assert(!darwin13Release(NULL));
 for(unsigned i=0;i<sizeof(accepted)/sizeof(*accepted);i++)assert(darwin13Release(accepted[i]));
 for(unsigned i=0;i<sizeof(refused)/sizeof(*refused);i++)assert(!darwin13Release(refused[i]));
 return 0;
}
'''
# Audit actual source boundaries: only the explicit mode can reach the global post.
assert source.count('CGEventPost(kCGHIDEventTap,events[')==2
sequence=source[source.index('static int projectHIDSequence('):source.index('static void projectHIDClick(')]
hid=source[source.index('static void projectHIDClick('):source.index('static void openGenerated(')]
assert hid.index('guestDarwin13()')<hid.index('projectHIDSequence(events,')
assert hid.index('imageOnDisplay(image)')<hid.index('projectHIDSequence(events,')
assert sequence.index('!frontmostOwned(pid,NULL)')<sequence.index('CGEventPost(kCGHIDEventTap,events[down])')
assert sequence.index('CGEventSetTimestamp(events[down],stamps[down])')<sequence.index('CGEventPost(kCGHIDEventTap,events[down])')
assert 'image.origin.x+image.size.width/8' in hid and 'image.origin.y+image.size.height/2' in hid
assert 'fmin(.02,interval/8)' in hid and 'clockNow()-began>=interval' in sequence
assert 'for(int click=0;click<2;click++)' in sequence
between=sequence[sequence.index('CGEventPost(kCGHIDEventTap,events[down])'):sequence.index('CGEventPost(kCGHIDEventTap,events[up])')]
assert 'break' not in between and 'return' not in between and '[' not in between.replace('events[down]','').replace('stamps[up]','').replace('events[up]','')
assert 'if(hid){projectHIDClick(pid,directory,image,report);}' in source
assert 'hidMode=!strcmp(argv[3],"open-generated-project-hid")' in source
assert 'PROJECT_HID_REQUIRES_GUEST_DARWIN13' in source
for forbidden in ('CGWarpMouseCursorPosition','activateWithOptions','kCGEventMouseMoved','CGEventCreateKeyboardEvent'):
 assert forbidden not in hid
sequence_fixture=r'''#include <assert.h>
#include <stdint.h>
#include <stddef.h>
typedef int CGEventRef;typedef int pid_t;typedef unsigned useconds_t;
#define kCGHIDEventTap 0
static int posted,failAfter,kind,clocks;static uint64_t tick;
static double clockNow(void){if(!clocks++)return 0;return kind==2 && posted>=failAfter?100:0;}
static int frontmostOwned(pid_t p,void *out){(void)p;(void)out;return kind!=0 || posted<failAfter;}
static int room(void){return kind!=1 || posted<failAfter;}
static uint64_t eventTimestamp(void){return ++tick;}
static void CGEventSetTimestamp(CGEventRef e,uint64_t t){assert(e==posted);assert(t==tick);}
static void CGEventPost(int tap,CGEventRef e){assert(tap==0 && e==posted);posted++;}
static void usleep(useconds_t delay){assert(delay==20000);}
'''+sequence+r'''
int main(void){
 CGEventRef events[4]={0,1,2,3};uint64_t stamps[4]={0};
 for(kind=0;kind<3;kind++)for(failAfter=0;failAfter<=4;failAfter++){
  posted=clocks=0;tick=0;int n=projectHIDSequence(events,42,.5,20000,stamps);
  int expected=kind==2?(failAfter<=2?2:4):(failAfter==0?0:failAfter<=2?2:4);
  assert(n==expected && n==posted && !(n%2));
  for(int i=0;i<n;i++)assert(stamps[i]==(uint64_t)i+1);
 }
 kind=3;posted=clocks=0;tick=0;assert(projectHIDSequence(events,42,.5,20000,stamps)==4);
 return 0;
}
'''
with tempfile.TemporaryDirectory(prefix='lightclick-fcp-hid-guard-') as temporary:
 path=Path(temporary);c=path/'guard.c';binary=path/'guard';c.write_text(fixture)
 subprocess.run(['xcrun','clang','-std=c11','-Wall','-Wextra','-Werror',str(c),'-o',str(binary)],check=True,timeout=20)
 subprocess.run([str(binary)],check=True,timeout=5)
 c.write_text(sequence_fixture)
 subprocess.run(['xcrun','clang','-std=c11','-Wall','-Wextra','-Werror',str(c),'-o',str(binary)],check=True,timeout=20)
 subprocess.run([str(binary)],check=True,timeout=5)
print('PASS actual Darwin13 predicate, balanced sequence under every focus/deadline/interval failure stage, and HID source guards; no AX/event helper execution')
