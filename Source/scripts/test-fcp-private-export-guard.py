#!/usr/bin/env python3
"""Actual private-export predicates and Save-control ownership with RAM AX stubs only."""
import itertools
import json
from pathlib import Path
import re
import subprocess
import tempfile
root=Path(__file__).resolve().parents[1]
s=(root/'probes/fcp-ax-actions.m').read_text()
def section(start,end):return s[s.index(start):s.index(end,s.index(start))]
predicates=section('typedef struct {NSUInteger names,saves,cancels,wheres,saveLabels,whereLabels,disclosures;BOOL complete;} ExportSaveEvidence;','static BOOL exportOutputAbsent(')
controls=section('static SaveControls exportSheetControls(','static BOOL exportSettingsMatch(')
controls=re.sub(r'@"([^"\n]*)"',lambda m:'"'+m.group(1)+'"',controls.replace('NSString *expectedName','const char *expectedName'))
prefix=r'''
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <limits.h>
typedef int BOOL,pid_t;
typedef unsigned NSUInteger;
typedef long CFIndex;
#define YES 1
#define NO 0
#define CFSTR(s) s
#define kAXChildrenAttribute "children"
#define kAXRoleAttribute "role"
#define kAXTitleAttribute "title"
#define kAXValueAttribute "value"
struct Object{int refs,kind,count,owner,enabled,writable,pressable,number;const char *role,*title,*value,*identifier,*description;struct Object *children[7];};
typedef struct Object *CFTypeRef;
typedef struct Object *AXUIElementRef;
typedef struct {AXUIElementRef window,name,button,where;} SaveControls;
static struct Object sheet,array,children[7];static int budget,calls;
static BOOL room(void){return ++calls<=budget;}
static void *CFRetain(CFTypeRef o){assert(o && o->refs>0);++o->refs;return o;}
static void CFRelease(CFTypeRef o){assert(o && o->refs>0);if(--o->refs==0 && o->kind==2)for(int i=0;i<o->count;++i)CFRelease(o->children[i]);}
static int CFGetTypeID(CFTypeRef o){assert(o && o->refs>0);return o->kind;}
static int CFArrayGetTypeID(void){return 2;}static int AXUIElementGetTypeID(void){return 1;}
static CFIndex CFArrayGetCount(CFTypeRef o){assert(o->refs>0);return o->count;}
static CFTypeRef CFArrayGetValueAtIndex(CFTypeRef o,CFIndex i){assert(o->refs>0 && i<o->count);return o->children[i];}
static CFTypeRef attribute(AXUIElementRef o,const char *key){assert(o==&sheet && !strcmp(key,kAXChildrenAttribute));return &array;}
static BOOL ownedElement(AXUIElementRef o,pid_t pid){assert(o->refs>0);return o->owner==pid;}
static BOOL equals(AXUIElementRef o,const char *key,const char *expected){assert(o->refs>0);const char *value=!strcmp(key,"role")?o->role:!strcmp(key,"title")?o->title:!strcmp(key,"value")?o->value:!strcmp(key,"AXIdentifier")?o->identifier:o->description;return value && !strcmp(value,expected);}
static BOOL enabled(AXUIElementRef o,BOOL expected){assert(o->refs>0);return o->enabled==expected;}
static BOOL writable(AXUIElementRef o,const char *key){(void)key;assert(o->refs>0);return o->writable;}
static BOOL pressAvailable(AXUIElementRef o){assert(o->refs>0);return o->pressable;}
static BOOL masterRadioValue(AXUIElementRef o,int expected){assert(o->refs>0);return o->number==expected;}
static void releaseSave(SaveControls *save){if(save->window)CFRelease(save->window);if(save->name)CFRelease(save->name);if(save->button)CFRelease(save->button);if(save->where)CFRelease(save->where);memset(save,0,sizeof(*save));}
'''
main=r'''
static void reset(void){
 sheet=(struct Object){.refs=1,.kind=1,.owner=7,.role="AXSheet",.description="save"};array=(struct Object){.refs=1,.kind=2,.count=7};budget=INT_MAX;calls=0;
 for(int i=0;i<7;++i){children[i]=(struct Object){.refs=1,.kind=1,.owner=7,.enabled=1,.pressable=1};array.children[i]=children+i;}
 children[0].role="AXButton";children[0].title="Save";children[0].identifier="_NS:55";
 children[1].role="AXButton";children[1].title="Cancel";children[1].identifier="_NS:53";
 children[2].role="AXCheckBox";children[2].description="disclosure";children[2].number=0;
 children[3].role="AXTextField";children[3].identifier="_NS:135";children[3].value="LC-generated-8s";children[3].writable=1;
 children[4].role="AXStaticText";children[4].value="Save As:";
 children[5].role="AXStaticText";children[5].value="Where:";
 children[6].role="AXPopUpButton";children[6].value="LightClickFCPFixture.ABC123";
}
int main(void){
 ExportSaveEvidence e={1,1,1,1,1,1,1,1};assert(exportSaveEvidenceComplete(e));e.complete=0;assert(!exportSaveEvidenceComplete(e));
 for(int slot=0;slot<7;++slot)for(unsigned value=0;value<=2;value+=2){e=(ExportSaveEvidence){1,1,1,1,1,1,1,1};NSUInteger *fields[]={&e.names,&e.saves,&e.cancels,&e.wheres,&e.saveLabels,&e.whereLabels,&e.disclosures};*fields[slot]=value;assert(!exportSaveEvidenceComplete(e));}
 for(int mask=0;mask<128;++mask){int b[7];for(int i=0;i<7;++i)b[i]=(mask>>i)&1;assert(exportSaveAllowed(b[0],b[1],b[2],b[3],b[4],b[5],b[6])==(mask==63));}
 assert(exportCandidateValid(S_IFREG|0600,501,501,1,1));assert(exportCandidateValid(S_IFREG|0600,501,501,1,512ULL*1024*1024));
 assert(!exportCandidateValid(S_IFREG|0600,501,501,1,0));assert(!exportCandidateValid(S_IFREG|0600,501,501,1,512ULL*1024*1024+1));assert(!exportCandidateValid(S_IFLNK|0600,501,501,1,20));assert(!exportCandidateValid(S_IFREG|0600,502,501,1,20));assert(!exportCandidateValid(S_IFREG|0600,501,501,2,20));assert(!exportCandidateValid(S_IFREG|0600,0,0,1,20));
 char dir[]="/private/tmp/lightclick-export-guards.XXXXXX";assert(mkdtemp(dir));char path[512];assert(snprintf(path,sizeof(path),"%s/export.mov",dir)>0);
 assert(exportPathAbsent(path));int fd=open(path,O_CREAT|O_EXCL|O_WRONLY,0600);assert(fd>=0);assert(write(fd,"x",1)==1);close(fd);assert(!exportPathAbsent(path));assert(!unlink(path));assert(!mkdir(path,0700));assert(!exportPathAbsent(path));assert(!rmdir(path));assert(!symlink("missing",path));assert(!exportPathAbsent(path));assert(!unlink(path));assert(!rmdir(dir));
 reset();SaveControls result=exportSheetControls(&sheet,7,"LC-generated-8s");assert(result.window==&sheet && result.name==children+3 && result.button==children && result.where==children+6);assert(array.refs==0 && sheet.refs==2 && children[0].refs==1 && children[3].refs==1 && children[6].refs==1);releaseSave(&result);assert(sheet.refs==1);for(int i=0;i<7;++i)assert(children[i].refs==0);
 for(int failure=0;failure<7;++failure){reset();if(failure==0){children[1].title="Save";children[1].identifier="_NS:55";}if(failure==1)children[3].value="other";if(failure==2)children[4].owner=8;if(failure==3)children[0].enabled=0;if(failure==4)children[3].writable=0;if(failure==5)budget=0;if(failure==6)budget=7;result=exportSheetControls(&sheet,7,"LC-generated-8s");assert(!result.window && array.refs==0 && sheet.refs==1);for(int i=0;i<7;++i)assert(children[i].refs==0);}
 puts("PASS actual Save guards/refcounts, missing/duplicate/PID/deadline cases, exclusive absence and candidate bounds");return 0;
}
'''
body=section('static void exportH264PrivateFixture(','typedef struct { NSUInteger scanned,project,duration,geometry,rate,movie;BOOL incomplete; } MasterPaneEvidence;')
assert body.count('AXUIElementPerformAction(')==2 # one Go and one Save
assert body.count('AXUIElementSetAttributeValue(')==2 # one absolute path and one name
assert body.count('CGEventPostToPSN(')==2 and 'CGEventPost(' not in body
save=body.index('error=AXUIElementPerformAction(fresh.button,kAXPressAction)')
assert body.index('report[@"exportAttempted"]=@YES;report[@"savePressed"]=@YES')<save
for token in ('exportSaveAllowed(','exportOutputAbsent(directory)','CFEqual(fresh.window,initialSheet)','exportSettingsMatch(freshParent,pid)','exportGoGone(application,freshParent,&fresh,submittedGo)','focusedExportSheet(application,freshParent,&fresh,pid)'):assert body.index(token)<save
assert 'privateFixture(directory,YES)' not in body
assert '@"PRIVATE_EXPORT_CANDIDATE_REQUIRES_MEDIA_VERIFICATION"' in body and 'stamp-stableSince>=2' in body and 'clockNow()+90' in body
assert 'panels(application)' not in body and 'snapshot(save.window,0)' in body and 'snapshot(go.panel,0)' in body
assert 'releaseGo(&go);go=current;' in body
for loop in re.findall(r'do\{(.*?)\}while\(room\(\)\);',body,re.S):
 assert 'AXUIElementPerformAction' not in loop and 'AXUIElementSetAttributeValue' not in loop
focus=section('static BOOL focusedExportSheet(','static CFMutableArrayRef exportGoCandidates(')
assert 'CFEqual(focused,parent) || CFEqual(focused,save->window)' in focus
assert 'static void exportGoDescendants' in s and 'if(complete && owned && questions==1' in s
assert 'if(exportMode)exportH264PrivateFixture' in s and 'alarm(exportMode?220:' in s and 'exportMode?210:' in s
fixture=root/'Build/performance/perf56-fcp101-transcode-focus-r3/result.json'
if fixture.exists():
 panes=json.loads(fixture.read_text())['workflow']['master_share_inspection']['savePanelsAfterNext'];named=[n for n in panes if n.get('AXTitle')=='Master File'];assert len(named)==1
 sheets=[n for n in named[0]['children']if n.get('AXRole')=='AXSheet'];assert len(sheets)==1 and sheets[0]['AXDescription']=='save' and len(sheets[0]['children'])==7
 values=sheets[0]['children'];assert sum(n.get('AXRole')=='AXTextField' and n.get('AXIdentifier')=='_NS:135' and n.get('settableAttributes',{}).get('AXValue')==1 for n in values)==1
with tempfile.TemporaryDirectory(prefix='lightclick-private-export-test-')as temporary:
 p=Path(temporary);c=p/'fixture.c';binary=p/'fixture';c.write_text(prefix+predicates+controls+main)
 subprocess.run(['xcrun','clang','-std=c11','-Wall','-Wextra','-Werror',str(c),'-o',str(binary)],timeout=20,check=True)
 result=subprocess.run([str(binary)],capture_output=True,text=True,timeout=10,check=True);assert not result.stderr;print(result.stdout.strip())
print('PASS exact perf56 sheet shape, one-shot navigation/Save ordering, bounded candidate-only result; no AX helper execution')
