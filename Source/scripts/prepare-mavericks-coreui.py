#!/usr/bin/env python3
"""Isolate the original rendering engine for clone-only compatibility experiments.

Apple binaries and art remain in Build. All defined Objective-C classes receive
equal-length private names, so loading this engine cannot replace Mojave classes.
"""
import argparse,hashlib,json,os,plistlib,re,shutil,subprocess,tarfile
from pathlib import Path

base=Path(__file__).resolve().parents[1]/'Build/mavericks-appearance'
parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('mavericks_root',type=Path);args=parser.parse_args()
root=args.mavericks_root.resolve();version=plistlib.loads((root/'System/Library/CoreServices/SystemVersion.plist').read_bytes())
if not version.get('ProductVersion','').startswith('10.9.') or not os.statvfs(root).f_flag&os.ST_RDONLY:raise SystemExit('A read-only mounted Mavericks root is required')
source=root/'System/Library/PrivateFrameworks/CoreUI.framework/Versions/A'
out=base/'isolated-coreui/LoreUI.framework/Versions/A'
out.mkdir(parents=True,exist_ok=True)
subprocess.run(['xcrun','lipo',str(source/'CoreUI'),'-thin','x86_64','-output',str(out/'LoreUI')],check=True)
data=(out/'LoreUI').read_bytes()
symbols=subprocess.check_output(['xcrun','nm','-U',str(out/'LoreUI')],text=True)
classes=sorted(set(re.findall(r'_OBJC_CLASS_\$_(\S+)',symbols)),key=len,reverse=True)
renames={name:('L'+name[1:]) for name in classes}
for old,new in renames.items():
    # Both runtime strings and linker names must use the private name.
    data=data.replace(b'\0'+old.encode()+b'\0',b'\0'+new.encode()+b'\0')
    for prefix,suffix in [(b'_OBJC_CLASS_$_',b'\0'),(b'_OBJC_METACLASS_$_',b'\0'),(b'_OBJC_IVAR_$_',b'.')]:
        data=data.replace(prefix+old.encode()+suffix,prefix+new.encode()+suffix)
    data=data.replace(b'@"'+old.encode()+b'"',b'@"'+new.encode()+b'"')
data=data.replace(b'com.apple.coreui',b'com.lcmav.coreui')
(out/'LoreUI').write_bytes(data)
shutil.copytree(source/'Resources',out/'Resources',dirs_exist_ok=True)
info=plistlib.loads((out/'Resources/Info.plist').read_bytes())
info.update(CFBundleIdentifier='com.lcmav.coreui',CFBundleExecutable='LoreUI',CFBundleName='LoreUI')
(out/'Resources/Info.plist').write_bytes(plistlib.dumps(info))
framework=out.parent.parent
(framework/'Versions/Current').unlink(missing_ok=True)
(framework/'Versions/Current').symlink_to('A')
for name,target in [('LoreUI','Versions/Current/LoreUI'),('Resources','Versions/Current/Resources')]:
    (framework/name).unlink(missing_ok=True);(framework/name).symlink_to(target)
subprocess.run(['xcrun','install_name_tool','-id','/Library/Application Support/MavericksAppearance/LoreUI.framework/Versions/A/LoreUI',str(out/'LoreUI')],check=True)
subprocess.run(['codesign','--force','--sign','-',str(out/'LoreUI')],check=True)
manifest={'version':version,'originalSHA256':hashlib.sha256((source/'CoreUI').read_bytes()).hexdigest(),'isolatedSHA256':hashlib.sha256((out/'LoreUI').read_bytes()).hexdigest(),'classes':renames,'artwork':{name:hashlib.sha256((source/'Resources'/name).read_bytes()).hexdigest()for name in ['ArtFile.bin','ArtFile200.bin','SArtFile.bin']}}
(out/'Resources/Bridge.json').write_text(json.dumps({'widgets':sorted(set(re.findall(r'_(kCUIWidget\w+)',symbols)))}))
(base/'isolated-coreui/manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
dock=root/'System/Library/CoreServices/Dock.app/Contents/MacOS/Dock'
if dock.is_file():
    imports=subprocess.check_output(['xcrun','nm','-arch','x86_64','-uj',str(dock)],text=True).splitlines()
    imports=sorted(set(name[1:]for name in imports if name.startswith('_')))
    linkage=subprocess.check_output(['xcrun','otool','-arch','x86_64','-L',str(dock)],text=True).splitlines()[1:]
    libraries=[line.strip().split(' (')[0]for line in linkage if line.strip().startswith('/')]
    (base/'legacy-imports.h').write_text('static NSString *const symbolsJSON=@'+json.dumps(json.dumps(imports))+';\nstatic NSString *const librariesJSON=@'+json.dumps(json.dumps(libraries))+';\n')
with tarfile.open(base/'assets/isolated-coreui.tar.gz','w:gz') as archive:
    archive.add(framework,arcname='LoreUI.framework')
print(json.dumps({'classes':len(classes),'bytes':(base/'assets/isolated-coreui.tar.gz').stat().st_size}))
