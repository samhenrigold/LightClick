#!/usr/bin/env python3
"""Read-only, build-specific evidence for the Mavericks-on-Mojave appearance experiment.

Apple binary copies and generated disassembly stay in the local output folder.
String hits identify candidates, not proven preference switches or working UI paths.
"""
import argparse,hashlib,json,re,struct,subprocess
from pathlib import Path

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--mojave-root',required=True,type=Path)
parser.add_argument('--original-dock',required=True,type=Path)
parser.add_argument('--dock',required=True,type=Path)
parser.add_argument('--spotlight',required=True,type=Path)
parser.add_argument('--system-ui',type=Path)
parser.add_argument('--spotlight-framework',type=Path)
parser.add_argument('--parsec-ui',type=Path)
parser.add_argument('--output',required=True,type=Path)
args=parser.parse_args();args.output.mkdir(parents=True,exist_ok=True)

def command(*arguments):
    return subprocess.check_output(list(map(str,arguments)),text=True,stderr=subprocess.PIPE)

def evidence(path):
    thin_segments(path) # Reject protected instructions before interpreting code or strings.
    return {'path':str(path.resolve()),'sha256':hashlib.sha256(path.read_bytes()).hexdigest(),'size':path.stat().st_size}

def disassemble(path,symbol):
    result=command('xcrun','llvm-objdump','--macho','--arch=x86_64','-d','--dis-symname',symbol,path)
    if "Can't find -dis-symname:"in result:raise RuntimeError('Missing qualified symbol: '+symbol)
    if len(result)>100000:raise RuntimeError('Unexpected unbounded symbol disassembly')
    return result.splitlines()[2:]

def metadata(path):
    result=command('xcrun','llvm-objdump','--macho','--arch=x86_64','--objc-meta-data',path)
    classes={};name=None;method=None;in_methods=False;meta=False
    for line in result.splitlines():
        if re.match(r'^[0-9a-f]{16} ',line):name=None;meta=False
        if line=='Meta Class':meta=True;name=None
        match=re.match(r'^        name\s+0x[0-9a-f]+ (\S+)$',line)
        if match:name=match[1];classes.setdefault(name,{});in_methods=False
        if re.match(r'^        baseMethods\s+',line):in_methods=True
        elif re.match(r'^        (baseProtocols|ivars|weakIvarLayout|baseProperties)\s+',line):in_methods=False
        match=re.match(r'^            name\s+0x[0-9a-f]+ (.+)$',line)
        if match and in_methods:method=match[1]
        match=re.match(r'^            imp\s+(0x[0-9a-f]+)',line)
        if match and in_methods and name and method:classes[name][('+'if meta else'-')+method]=int(match[1],16)
    return classes

def strings(path):
    # Whole-file hits are deliberately candidates; Objective-C metadata and code
    # references below establish which ones actually participate in rendering.
    return sorted(set(m.group().decode('ascii')for m in re.finditer(rb'[ -~]{5,}',path.read_bytes())))

def thin_segments(path):
    data=path.read_bytes()
    if struct.unpack_from('<II',data)not in [(0xfeedfacf,0x1000007)]:raise RuntimeError('Expected thin x86_64 analysis copy')
    offset=32;segments=[]
    for _ in range(struct.unpack_from('<I',data,16)[0]):
        kind,size=struct.unpack_from('<II',data,offset)
        if size<8 or offset+size>len(data):raise RuntimeError('Invalid load command')
        if kind==0x19:
            name,vm,_,fileoff,filesize=struct.unpack_from('<16s4Q',data,offset+8)
            if name.rstrip(b'\0')==b'__TEXT'and struct.unpack_from('<I',data,offset+68)[0]&8:
                raise RuntimeError('Protected __TEXT: supply a read-only executable-text analysis copy')
            segments.append((vm,filesize,fileoff))
        offset+=size
    return data,segments

def original_reflections(path,classes):
    # llvm's Mach-O parser resolves selectors and class/constant-string references.
    # Save the full disassembly locally, then retain only these measured methods.
    cache=args.output/'original-dock-disassembly.txt'
    digest=hashlib.sha256(path.read_bytes()).hexdigest();seal=cache.with_suffix('.sha256')
    if not cache.exists()or not seal.exists()or seal.read_text().strip()!=digest:
        with cache.open('w')as output:subprocess.run(['xcrun','llvm-objdump','--macho','--arch=x86_64','-d',str(path)],stdout=output,check=True)
        seal.write_text(digest+'\n')
    wanted=classes.get('DOCKReflectionLayer',{});starts={wanted[k]:k for k in ['-init','-setImage:','-layoutSublayers']if k in wanted}
    selected={};active=None
    for line in cache.open():
        match=re.match(r'^([0-9a-f]+):',line)
        if match and int(match[1],16)in starts:active=starts[int(match[1],16)];selected[active]=[]
        if active:
            selected[active].append(line.rstrip())
            if '\tretq'in line:active=None
    data,segments=thin_segments(path);constants=[]
    for method,lines in selected.items():
        for line in lines:
            match=re.match(r'([0-9a-f]+):\s*((?:[0-9a-f]{2} )*[0-9a-f]{2})\s+.*?(movss|movsd|mulss|mulsd)\s+0x([0-9a-f]+)\(%rip\)',line)
            if not match:continue
            address=int(match[1],16);target=address+len(match[2].split())+int(match[4],16)
            for vm,size,fileoff in segments:
                if vm<=target<vm+size:
                    value=struct.unpack_from('<f'if match[3].endswith('ss')else'<d',data,fileoff+target-vm)[0]
                    constants.append({'method':method,'instruction':hex(address),'constant':hex(target),'value':value})
    return {'methods':selected,'floatingPointConstants':constants}

appkit=args.mojave_root/'System/Library/Frameworks/AppKit.framework/Versions/C/AppKit'
sky=args.mojave_root/'System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight'
hitoolbox=args.mojave_root/'System/Library/Frameworks/Carbon.framework/Versions/A/Frameworks/HIToolbox.framework/Versions/A/HIToolbox'
keys=['NSButtonUseLegacyAlignmentRectInsets','NSTableHeaderViewUsesYosemiteHeight','NSPopupRequiresLegacyPopUpIndicatorSize','NSNeedsSnowLeopardTitlebarButtons','NSVisualEffectViewAlwaysUsesClearProxyForTitlebarWithinWindow','NSScrollViewAccessoryCheckUsesLegacyFrame','NSScrollViewForceLegacyScrollersInTileWithoutRecursing','NSLevelIndicatorRatingUseLegacyDrawMethod']
defaults={key:disassemble(appkit,'_'+key+'DefaultValueFunction')for key in keys}
original_classes=metadata(args.original_dock);dock_classes=metadata(args.dock);spot_classes=metadata(args.spotlight)
report={'scope':'Static analysis only; no preference writes, application launches or process modifications.','binaries':{name:evidence(path)for name,path in [('AppKit',appkit),('SkyLight',sky),('originalDock',args.original_dock),('Dock',args.dock),('Spotlight',args.spotlight)]},
 'AppKit':{'defaultValueFunctions':defaults,'preferenceLookup':disassemble(appkit,'__NSGetBoolAppConfig'),'classicTitlebarFlagGetter':disassemble(appkit,'_NSNeedsSnowLeopardTitlebarButtons')},
 'SkyLight':{'magicMirrorExports':[s for s in command('xcrun','nm','-arch','x86_64','-gj',sky).splitlines()if'MagicMirror'in s], 'magicMirrorProperties':disassemble(sky,'_SLSSetMagicMirrorProperties'),'menuBarStyleSetter':disassemble(sky,'_SLSSetMenuBarDrawingStyle')},
 'Dock':{'originalReflection':original_reflections(args.original_dock,original_classes),'originalClasses':[s for s in original_classes if re.search(r'(Floor|Reflect|GradientBlur)',s)],'modernClasses':{k:v for k,v in dock_classes.items()if re.search(r'(Floor|Reflect|Glass)',k)},'candidateStrings':[s for s in strings(args.dock)if re.search(r'(no-glass|glass|mirror|reflection|floor|legacy|yosemite)',s,re.I)]},
 'Spotlight':{'searchPanelMethods':spot_classes.get('SPSearchPanel',{}),'candidateStrings':[s for s in strings(args.spotlight)if re.search(r'(legacy|classic|yosemite|old.?style|menu.?bar|search.?panel|search.?window|default|pref)',s,re.I)]},
 'qualification':'String absence cannot prove that no hidden setting exists. Default functions establish fallback behavior, not the result of forcing a preference. Rendering changes require later offscreen and desktop validation.'}
report['binaries']['HIToolbox']=evidence(hitoolbox)
report['HIToolbox']={symbol:disassemble(hitoolbox,symbol)for symbol in ['__HIMenuUseBackdrops','_IsMenuBarTransparencyEnabled','__Z21_HIWindowUseBackdropsv','__HIThemeApplyNewLook','__HIMenuBarSetAppearanceOverride','__ZN14TThemeMetaFont15CreateCTFontRefEv']}
if args.system_ui:
    report['binaries']['SystemUIServer']=evidence(args.system_ui)
    report['SystemUIServer']={'candidateStrings':[s for s in strings(args.system_ui)if re.search(r'(menu.?bar|material|appearance|Lucida|font|legacy|aqua)',s,re.I)]}
if args.spotlight_framework:
    path=args.spotlight_framework;report['binaries']['SpotlightFramework']=evidence(path)
    preferences=disassemble(path,'-[SPDefaults reloadPrefs]')
    report['SpotlightFramework']={'defaultsClasses':{name:methods for name,methods in metadata(path).items()if name in ('SPDefaults','SPAppDefaults')},'defaultsInitialization':disassemble(path,'+[SPDefaults initialize]'),'preferencesReload':preferences,'referencedPreferenceStrings':sorted(set(re.findall(r'cfstring ref: @"([^"]+)"','\n'.join(preferences)))),'candidateStrings':[s for s in strings(path)if re.search(r'(legacy|classic|yosemite|old.?style|appearance|useParsecd)',s,re.I)]}
if args.parsec_ui:
    path=args.parsec_ui;report['binaries']['ParsecUI']=evidence(path)
    report['ParsecUI']={'presentationClasses':[name for name in metadata(path)if re.search(r'(Window|Panel|Search|ViewController)',name)],'candidateStrings':[s for s in strings(path)if re.search(r'(legacy|classic|yosemite|old.?style|menu.?bar|appearance)',s,re.I)]}
out=args.output/'design-static-evidence.json';out.write_text(json.dumps(report,indent=2)+'\n')
print(out)
