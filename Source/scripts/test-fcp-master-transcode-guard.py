#!/usr/bin/env python3
"""Actual native footer predicates and one-shot action boundaries; no AX execution."""
import itertools
import json
from pathlib import Path
import re
import subprocess
root=Path(__file__).resolve().parents[1]
s=(root/'probes/fcp-ax-actions.m').read_text()
predicate=s[s.index('static BOOL transcodeMetadataComplete('):s.index('static BOOL transcodeMetadata(')]
expr=re.search(r'return ([^;]+);',predicate).group(1)
checks=[]
for complete,*counts in itertools.product((0,1),*(range(3)for _ in range(4))):
    actual=expr.replace('complete',str(complete))
    for name,value in zip(('geometry','rate','duration','movie'),counts):actual=actual.replace(name,str(value))
    checks.append('_Static_assert((%s)==%d,"actual footer completeness/uniqueness");'%(actual,int(complete and counts==[1]*4)))
select=s[s.index('static BOOL selectTranscodePopup('):s.index('static void inspectMasterTranscodeSavePanel(')]
assert select.count('AXUIElementPerformAction(')==2
assert select.count('actionResult(')==2
for loop in re.findall(r'do\{(.*?)\}while\(room\(\)\);',select,re.S):assert 'AXUIElementPerformAction' not in loop
assert 'uniqueChild(menu,@"AXMenuItem",newValue,pid)' in select
assert 'uniqueChild(currentMenu,@"AXMenuItem",newValue,pid)' in select
assert 'CFEqual(item,currentItem)' in select and 'pressAvailable(currentItem)' in select
assert 'equals(fresh,kAXValueAttribute,oldValue)' in select
assert 'snapshot(menu,0)' in select and 'if(!room() || truncated)goto done;' in select
assert 'evidence[@"desiredValueObserved"]=@(changed)' in select
assert 'settingsPopup(observed,pid,newValue)' in select
assert 'transcodeFocused(application,pane,pid)' in select
menu=s[s.index('static AXUIElementRef popupChildMenu('):s.index('static BOOL transcodeFocused(')]
for evidence in ('uniqueChild(popup,@"AXMenu",nil,pid)','kAXParentAttribute','CFEqual(parent,popup)','kAXWindowAttribute','CFEqual(window,pane)'):assert evidence in menu
body=s[s.index('static void inspectMasterTranscodeSavePanel('):s.index('static void inspectMasterSettings(')]
assert body.count('AXUIElementPerformAction(')==1
assert body.count('selectTranscodePopup(')==2
assert 'if(!selectTranscodePopup(application,pane,pid,directory,@"Source - Apple ProRes 422",@"H.264",@"codecSelection",report))goto done;' in body
assert 'if(!selectTranscodePopup(application,pane,pid,directory,@"QuickTime Player (default)",@"Do Nothing",@"openWithSelection",report))goto done;' in body
press=body.index('AXUIElementPerformAction(')
for witness in ('settingsPopup(fresh,pid,@"H.264")','settingsPopup(fresh,pid,@"Do Nothing")','transcodeMetadata(fresh,pid)','CFEqual(next,currentNext)','enabled(currentNext,YES)','pressAvailable(currentNext)','transcodeFocused(application,pane,pid)'):assert body.index(witness)<press
assert 'transcodeOwnedPanels(application,pid,NO,&saveVisible)' in body[press:]
assert 'clockNow()+5' in body and 'report[@"savePressed"]=@NO' in body and 'report[@"exportAttempted"]=@NO' in body
for loop in re.findall(r'do\{(.*?)\}while\(room\(\)\);',body,re.S):assert 'AXUIElementPerformAction' not in loop
for forbidden in ('CGEvent','AXUIElementSetAttributeValue','@"Save",pid','kAXRaiseAction','nodes=0','nodes = 0'):
    assert forbidden not in select+body
main=s[s.index('\nint main('):]
assert 'if(transcodeMode)inspectMasterTranscodeSavePanel' in main
assert 'transcodeMode?55:settingsMode?30' in main and 'transcodeMode?48:settingsMode?26' in main
fixture=root/'Build/performance/perf53-fcp101-master-settings/result.json'
if fixture.exists():
    pane=json.loads(fixture.read_text())['workflow']['master_share_inspection']['masterSettingsPane']
    values=[c.get('AXValue')for c in pane['children']if c.get('AXRole')=='AXStaticText']
    for value in ('1920 x 1080','30 fps','00:00:08:00','QuickTime movie'):assert values.count(value)==1
    groups=[c for c in pane['children']if c.get('AXRole')=='AXGroup'];assert len(groups)==1
    popups=[c for c in groups[0]['children']if c.get('AXRole')=='AXPopUpButton' and c.get('AXEnabled') is True]
    for value in ('Source - Apple ProRes 422','QuickTime Player (default)'):assert sum(c.get('AXValue')==value for c in popups)==1
subprocess.run(['xcrun','clang','-std=c11','-Wall','-Wextra','-Werror','-fsyntax-only','-x','c','-'],input='\n'.join(checks).encode(),timeout=20,check=True)
print('PASS 162 actual footer predicates, perf53 controls, two exact conditional menu selections, one Next/no Save boundary; no helper execution')

# Executable RAM-only ownership regression. Actual settingsPopup body is translated
# only from NSString/literal spelling to C strings; control flow stays unchanged.
import argparse
import resource
parser=argparse.ArgumentParser();parser.add_argument('--emit-c',type=Path);parser.add_argument('--check',type=Path);args=parser.parse_args()
popup=s[s.index('static AXUIElementRef settingsPopup('):s.index('static BOOL paneStillOwned(')]
retain='        if(matches==1 && result && room())CFRetain(result);else result=NULL;\n'
assert popup.index(retain)<popup.index('if(children)CFRelease(children)')
legacy=popup.replace(retain,'').replace('    if(group)CFRelease(group);return result;',retain+'    if(group)CFRelease(group);return result;')
def native(body,name):
    body=body.replace('settingsPopup(',name+'(').replace('NSString *value','const char *value')
    return re.sub(r'@"([^"\n]*)"',lambda m:'"'+m.group(1)+'"',body)
if args.emit_c:
    prefix=r'''
#include <assert.h>
#include <limits.h>
#include <stdio.h>
#include <string.h>
typedef int BOOL,pid_t;
typedef unsigned NSUInteger;
typedef long CFIndex;
#define YES 1
#define nil NULL
#define kAXChildrenAttribute 1
#define kAXRoleAttribute 2
#define kAXValueAttribute 3
struct Object {int kind,refs,count,owner,enabled;const char *role,*value;struct Object *children[2];};
typedef struct Object *CFTypeRef;
typedef struct Object *AXUIElementRef;
static struct Object group,array,children[2];
static int room_limit,room_calls;
static BOOL room(void){return ++room_calls<=room_limit;}
static void *CFRetain(CFTypeRef object){assert(object && object->refs>0 && "borrowed AX child expired before retain");++object->refs;return object;}
static void CFRelease(CFTypeRef object){assert(object && object->refs>0);if(--object->refs==0 && object->kind==2)for(int i=0;i<object->count;++i)CFRelease(object->children[i]);}
static int CFGetTypeID(CFTypeRef object){assert(object && object->refs>0);return object->kind;}
static int CFArrayGetTypeID(void){return 2;}
static int AXUIElementGetTypeID(void){return 1;}
static CFIndex CFArrayGetCount(CFTypeRef object){assert(object->refs>0);return object->count;}
static CFTypeRef CFArrayGetValueAtIndex(CFTypeRef object,CFIndex index){assert(object->refs>0 && index<object->count);return object->children[index];}
static AXUIElementRef uniqueChild(AXUIElementRef pane,const char *role,const char *title,pid_t pid){(void)pane;(void)role;(void)title;(void)pid;return CFRetain(&group);}
static CFTypeRef attribute(AXUIElementRef object,int key){assert(object==&group && key==kAXChildrenAttribute);return &array;}
static BOOL ownedElement(AXUIElementRef object,pid_t pid){assert(object->refs>0);return object->owner==pid;}
static BOOL equals(AXUIElementRef object,int key,const char *text){assert(object->refs>0);return !strcmp(key==kAXRoleAttribute?object->role:object->value,text);}
static BOOL enabled(AXUIElementRef object,BOOL value){assert(object->refs>0);return object->enabled==value;}
'''
    suffix=r'''
static void reset(int count,int budget){
 group=(struct Object){.kind=1,.refs=1};array=(struct Object){.kind=2,.refs=1,.count=count};
 for(int i=0;i<2;++i){children[i]=(struct Object){.kind=1,.refs=1,.owner=7,.enabled=1,.role="AXPopUpButton",.value="Source - Apple ProRes 422"};array.children[i]=children+i;}
 room_limit=budget;room_calls=0;
}
int main(int argc,char **argv){
 (void)argv;
 if(argc>1){reset(1,INT_MAX);(void)settingsPopupLegacy(NULL,7,"Source - Apple ProRes 422");return 0;}
 reset(1,INT_MAX);AXUIElementRef found=settingsPopup(NULL,7,"Source - Apple ProRes 422");assert(found==children && found->refs==1 && array.refs==0 && group.refs==1);CFRelease(found);assert(children[0].refs==0);
 reset(1,INT_MAX);children[0].value="Other";assert(!settingsPopup(NULL,7,"Source - Apple ProRes 422") && children[0].refs==0 && array.refs==0);
 reset(2,INT_MAX);assert(!settingsPopup(NULL,7,"Source - Apple ProRes 422") && children[0].refs==0 && children[1].refs==0);
 reset(1,0);assert(!settingsPopup(NULL,7,"Source - Apple ProRes 422") && children[0].refs==0);
 reset(1,1);assert(!settingsPopup(NULL,7,"Source - Apple ProRes 422") && children[0].refs==0);
 reset(1,INT_MAX);children[0].owner=8;assert(!settingsPopup(NULL,7,"Source - Apple ProRes 422") && children[0].refs==0);
 reset(1,INT_MAX);children[0].enabled=0;assert(!settingsPopup(NULL,7,"Source - Apple ProRes 422") && children[0].refs==0);
 puts("PASS actual settingsPopup retained ownership: unique/none/duplicates/deadline/PID/enabled");return 0;
}
'''
    args.emit_c.write_text(prefix+native(popup,'settingsPopup')+native(legacy,'settingsPopupLegacy')+suffix)
if args.check:
    def no_core():resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    fixed=subprocess.run([str(args.check)],capture_output=True,text=True,timeout=10,preexec_fn=no_core)
    assert fixed.returncode==0 and not fixed.stderr,(fixed.returncode,fixed.stderr[:1024])
    old=subprocess.run([str(args.check),'legacy'],capture_output=True,text=True,timeout=10,preexec_fn=no_core)
    assert old.returncode!=0 and 'borrowed AX child expired before retain' in old.stderr,(old.returncode,old.stderr[:1024])
    print(f'PASS ownership witness: reconstructed old ordering fails({old.returncode}); actual corrected body passes(0); cores disabled')
