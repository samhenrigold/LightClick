#!/usr/bin/env python3
"""Extract actual native predicates; no AX helper or guest execution."""
import itertools
import json
from pathlib import Path
import re
import subprocess
root=Path(__file__).resolve().parents[1]
s=(root/'probes/fcp-ax-actions.m').read_text()
start=s.index('static BOOL masterPaneEvidenceComplete(')
expression=re.search(r'return ([^;]+);',s[start:]).group(1)
checks=[]
for incomplete,*counts in itertools.product((0,1),*(range(3)for _ in range(5))):
    expr=expression.replace('e.incomplete',str(incomplete))
    for name,n in zip(('project','duration','geometry','rate','movie'),counts):expr=expr.replace('e.'+name,str(n))
    checks.append('_Static_assert((%s)==%d,"actual pane evidence uniqueness");'%(expr,int(not incomplete and counts==[1]*5)))
body=s[s.index('static void inspectMasterSettings('):s.index('typedef struct { NSUInteger scanned,runtime')]
assert body.count('AXUIElementPerformAction(')==1
press=body.index('AXUIElementPerformAction(')
for guard in ('masterPane(application,pid,YES)','masterTabs(pane,pid,0)','masterTabs(fresh,pid,0)','CFEqual(tabs.settings,current.settings)','CFEqual(tabs.group,current.group)','finalPane=masterPane(application,pid,NO)','pressAvailable(current.settings)','guestDarwin13()','identity(pid)','ownLibrary(directory)','frontmostOwned(pid,NULL)'):
    assert body.index(guard)<press,guard
assert 'masterTabs(observed,pid,1)' in body[press:] and 'clockNow()+4' in body
assert 'snapshot(observed,0)' in body[press:] and 'settingsSelectionObserved' in body
for forbidden in ('CGEvent','AXUIElementSetAttributeValue','kAXRaiseAction','@"Next"','@"Save"'):
    assert forbidden not in body
pane=s[s.index('static AXUIElementRef masterPane('):s.index('typedef struct { AXUIElementRef group,info,settings;')]
assert 'named==1 && blank<=1 && editor<=1' in pane and 'CFEqual(focused,result)' in pane
assert 'blankShareCompanion(window,pid)' in pane and 'AXSheet' in pane and 'AXAlert' in pane
blank=s[s.index('static BOOL blankShareCompanion('):s.index('static AXUIElementRef masterPane(')]
assert 'CFArrayGetCount(children)==0' in blank and 'kAXTitleAttribute,@""' in blank
assert 'ownedElement(window,pid)' in blank
radio=s[s.index('static MasterTabs masterTabs('):s.index('static void inspectMasterSettings(')]
assert 'CFArrayGetCount(children)==2' in radio
assert 'masterRadioValue(result.info,!settingsSelected)' in radio and 'masterRadioValue(result.settings,settingsSelected)' in radio
assert 'uniqueChild(result.group,@"AXRadioButton",@"Info",pid)' in radio
assert 'uniqueChild(result.group,@"AXRadioButton",@"Settings",pid)' in radio
assert 'AXIdentifier' not in pane+radio+body
main=s[s.index('\nint main('):]
assert 'if(settingsMode)inspectMasterSettings' in main
assert 'settingsMode?30:shareMode?24' in main and 'settingsMode?26:shareMode?20' in main
# Actual perf50 fixture, if retained, must satisfy the source predicate counts.
fixture=root/'Build/performance/perf50-fcp101-master-share-compressed/result.json'
if fixture.exists():
    panels=json.loads(fixture.read_text())['workflow']['master_share_inspection']['sharePanels']
    named=[p for p in panels if p.get('AXTitle')=='Master File'];assert len(named)==1
    counts=dict.fromkeys(('project','duration','geometry','rate','movie'),0)
    def visit(n):
        if n.get('AXRole')=='AXTextField' and n.get('AXSubrole')!='AXTextAttachment' and n.get('AXValue')=='LC-generated-8s':counts['project']+=1
        if n.get('AXRole')=='AXStaticText':
            for key,value in [('duration','00:00:08:00'),('geometry','1920 x 1080'),('rate','30 fps'),('movie','QuickTime movie')]:
                if n.get('AXValue')==value:counts[key]+=1
        for child in n.get('children',[]):visit(child)
    visit(named[0]);assert all(n==1 for n in counts.values()),counts
subprocess.run(['xcrun','clang','-std=c11','-Wall','-Wextra','-Werror','-fsyntax-only','-x','c','-'],input='\n'.join(checks).encode(),timeout=20,check=True)
print('PASS 486 actual native pane predicates, fresh owned one-press Settings boundaries; no helper execution; perf50 fixture '+('checked' if fixture.exists() else 'unavailable'))
