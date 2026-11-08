#!/usr/bin/env python3
"""Exercise the actual read-only wait with a fake clock; never run the AX helper."""
from pathlib import Path
import subprocess
import tempfile

source = (Path(__file__).resolve().parents[1] / 'probes/fcp-ax-actions.m').read_text()
start = source.index('static SaveControls waitForSave(')
end = source.index('static void createPrivate(', start)
wait = source[start:end]
fixture = r'''
#include <assert.h>
#include <math.h>
#include <stddef.h>
typedef int pid_t;typedef unsigned useconds_t;typedef int NSString;typedef void *AXUIElementRef;
typedef struct {void *window;} SaveControls;
#define YES 1
static double now,deadline,appears,identityUntil,fixtureUntil;
static unsigned reads,sleeps;
static double clockNow(void){return now;}
static int room(void){return now<deadline;}
static int identity(pid_t p){assert(p==42);return now<identityUntil;}
static int privateFixture(NSString *p,int absent){assert(!p && absent==1);return now<fixtureUntil;}
static SaveControls findSave(AXUIElementRef app,pid_t p){assert(!app && p==42);reads++;return (SaveControls){now>=appears?(void *)1:NULL};}
static void usleep(useconds_t usec){assert(usec>0 && usec<=200000);sleeps++;now+=(double)usec/1e6;}
''' + wait + r'''
static void reset(double at,double limit){now=0;deadline=limit;appears=at;identityUntil=fixtureUntil=100;reads=sleeps=0;}
int main(void){
 reset(0,48);assert(waitForSave(NULL,42,NULL).window && reads==1 && sleeps==0);
 reset(3,48);assert(waitForSave(NULL,42,NULL).window && now>=3 && now<3.3);
 reset(100,48);assert(!waitForSave(NULL,42,NULL).window && now>=9.99999 && now<=10.00001 && reads<=52);
 reset(100,1.25);assert(!waitForSave(NULL,42,NULL).window && now>=1.24999 && now<=1.25001 && reads<=8);
 reset(3,48);identityUntil=.5;assert(!waitForSave(NULL,42,NULL).window && now<.81 && reads==3);
 reset(3,48);fixtureUntil=.5;assert(!waitForSave(NULL,42,NULL).window && now<.81 && reads==3);
 reset(0,0);assert(!waitForSave(NULL,42,NULL).window && reads==0 && sleeps==0);
 return 0;
}
'''
# Polling has no action API. New, Go and Save still have a single submission site.
assert 'AXUIElementPerformAction' not in wait and 'CGEvent' not in wait
main = source[source.index('int main('):]
assert main.count('AXUIElementPerformAction(button,kAXPressAction)') == 1
create = source[end:source.index('typedef struct { AXUIElementRef window,group,image;', end)]
assert create.count('AXUIElementPerformAction(go.button,kAXPressAction)') == 1
assert create.count('AXUIElementPerformAction(save.button,kAXPressAction)') == 1
assert 'SaveControls save=waitForSave(application,pid,directory)' in create
assert create.count('double until=fmin(deadline,clockNow()+10)') == 2
assert 'usleep(500000);releaseGo' not in create
assert create.index('goSheetDismissed') < create.index('AXUIElementPerformAction(save.button,kAXPressAction)')
with tempfile.TemporaryDirectory(prefix='lightclick-fcp-save-wait-') as temporary:
    path = Path(temporary)
    c = path / 'wait.c'; binary = path / 'wait'
    c.write_text(fixture)
    subprocess.run(['nice','-n','10','xcrun','clang','-std=c11','-Wall','-Wextra','-Werror',str(c),'-o',str(binary)],check=True,timeout=20)
    subprocess.run([str(binary)],check=True,timeout=5)
print('PASS delayed/immediate Save, bounded timeout, original deadline, identity/fixture loss, and one-shot New/Go/Save source boundaries; no AX helper execution')
