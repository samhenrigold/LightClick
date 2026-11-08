#!/usr/bin/env python3
"""Pure count accounting and source boundary checks; never execute AX/action helper."""
from pathlib import Path
import re
import subprocess
s=(Path(__file__).resolve().parents[1]/'probes/fcp-ax-actions.m').read_text()
menu=s[s.index('static AXUIElementRef masterShareItem('):s.index('typedef struct { NSUInteger scanned,runtime')]
assert 'uniqueChild((AXUIElementRef)bar,@"AXMenuBarItem",@"File",pid)' in menu
assert 'uniqueChild(menu,@"AXMenuItem",@"Share",pid)' in menu
assert 'uniqueChild(submenu,@"AXMenuItem",@"Master File (default)…",pid)' in menu
assert '!enabled(item,YES) || !pressAvailable(item)' in menu
child=s[s.index('static AXUIElementRef uniqueChild('):s.index('static AXUIElementRef masterShareItem(')]
assert 'matches==1' in child and 'CFArrayGetCount(children)<=64' in child
body=s[s.index('static void inspectMasterShare('):s.index('\nint main(')]
assert body.count('AXUIElementPerformAction(')==1
post=body.index('AXUIElementPerformAction(')
for guard in ('guestDarwin13()','ownLibrary(directory)','frontmostOwned(pid,NULL)','verifiedTimeline(target.window,pid,report)','plainFocusedWindow(application,target.window,pid)','CFEqual(item,fresh)'):
 assert body.index(guard)<post
assert 'masterShareItem(application,pid)' in body[:post]
assert body[:post].count('masterShareItem(application,pid)')==2
for forbidden in ('CGEventPost','CGEventCreate','AXValueAttribute,','kAXRaiseAction','@"Next"','@"Save"'):
 assert forbidden not in body
assert 'report[@"exportAttempted"]=@NO' in body
assert 'report[@"nextOrSavePressed"]=@NO' in body
verify=s[s.index('static BOOL verifiedTimeline('):s.index('static void inspectMasterShare(')]
expression=re.search(r'return ([^;]+);',verify).group(1)
# Compile the actual return predicate exhaustively over absent/unique/duplicate witnesses.
checks=[]
for incomplete in (0,1):
 for runtime in range(3):
  for project in range(3):
   for clip in range(3):
    expr=expression.replace('evidence.incomplete',str(incomplete)).replace('evidence.runtime',str(runtime)).replace('evidence.project',str(project)).replace('evidence.clip',str(clip))
    expected=int(not incomplete and runtime==project==clip==1)
    checks.append('_Static_assert((%s)==%d,"count uniqueness/completeness");'%(expr,expected))
subprocess.run(['xcrun','clang','-std=c11','-Wall','-Wextra','-Werror','-fsyntax-only','-x','c','-'],input='\n'.join(checks).encode(),timeout=20,check=True)
print('PASS 54 native completeness/uniqueness cases, unique actual menu path, prepress guards, one action/no export boundary; no helper execution')
