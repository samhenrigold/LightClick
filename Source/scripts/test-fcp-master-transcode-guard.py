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
