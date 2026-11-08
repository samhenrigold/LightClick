#!/usr/bin/env python3
"""Iterate against an appearance runner paused at --hold. Uses that app's diagnostics owner.
Usage: mavericks-appearance-live.py RESULTS_DIR inspect | capture LABEL [reference|MODE] [STATE]
"""
import base64,hashlib,json,shutil,struct,subprocess,sys,time
from pathlib import Path
source=Path(__file__).resolve().parents[1]
root=Path(sys.argv[1]).resolve();channel=root/'diagnostics'
if (root/'control-channel.json').exists():channel=Path(json.loads((root/'control-channel.json').read_text())['directory']).resolve()
if not channel.is_relative_to(root):raise RuntimeError('Control path leaves owned root')
if not root.is_relative_to(source/'Build/mavericks-appearance') or not (root/'Appearance Experiment.app').is_dir() or (root/'Finish').exists():raise SystemExit('Requires an owned appearance experiment paused at --hold')
def request(command,timeout=180):
    if (channel/'Running.json').exists() or (channel/'Request.json').exists():raise RuntimeError('app control owner busy; leave its request alone')
    (channel/'Result.json').unlink(missing_ok=True);(channel/'Request.tmp').write_text(json.dumps(command));(channel/'Request.tmp').rename(channel/'Request.json')
    end=time.monotonic()+timeout
    while time.monotonic()<end:
        if (channel/'Result.json').exists():
            r=json.loads((channel/'Result.json').read_text())
            if r.get('Error') or r.get('ExitCode',0)!=0:raise RuntimeError(str(r))
            return r
        time.sleep(.25)
    raise RuntimeError('No acknowledged result; do not repeat writes')
def run(exe,args,timeout=180):return request({'Executable':str(exe),'Arguments':list(map(str,args))},timeout).get('Stdout','')
def stage(file):
    if (channel/'Running.json').exists() or (channel/'Request.json').exists():raise RuntimeError('app control owner busy; leave its transfer alone')
    shutil.copyfile(file,channel/'Transfer.bin');r=request({'Action':'stage-probe'},900 if file.stat().st_size>8388608 else 180);path=r['Transfer']['Directory']+'/Transfer.bin';run('/bin/chmod',['0755',path]);return path
if sys.argv[2]=='monitor':
    result=request({'Action':'monitor','Command':sys.argv[3]},60)
    if result.get('Output','').lstrip().startswith('Error:'):raise RuntimeError(result['Output'])
    print(json.dumps(result))
elif sys.argv[2]=='release-prearm':
    state=request({'Action':'seamless-state'},60)
    if state.get('Prepared'):print(json.dumps(request({'Action':'seamless-toggle'},60)))
    else:print('No prepared session')
elif sys.argv[2]=='status':
    print(json.dumps(request({'Action':'seamless-state'},60)))
elif sys.argv[2]=='qualify-systemwide':
    print(run('/usr/bin/python',['-c','import json,os,subprocess; assert os.getuid()==0 and os.uname()[2].startswith("18."),"Mojave clone root required"; assert os.stat("/dev/console").st_uid>=501,"GUI console required"; status=subprocess.check_output(["/usr/bin/csrutil","status"]); assert "disabled" in status,"This experiment requires an already prepared clone with SIP disabled"; print(json.dumps({"qualified":True}))']))
elif sys.argv[2]=='desktop':
    request({'Action':'capture'},60)
    label=sys.argv[3] if len(sys.argv)>3 else 'desktop'
    if not label.replace('-','').isalnum():raise ValueError('Invalid label')
    shutil.copyfile(channel/'Frame.png',root/(label+'.png'));print(root/(label+'.png'))
elif sys.argv[2]=='guest-script':
    local=Path(sys.argv[3]).resolve();remote=stage(local);print(run('/usr/bin/python',[remote],1800 if local.name=='mavericks-system-assets-apply.py' else 300))
elif sys.argv[2]=='install-library':
    library=root/'DesktopAppearance.dylib'
    subprocess.run(['xcrun','clang','-arch','x86_64','-mmacosx-version-min=10.9','-fno-objc-arc','-Wno-deprecated-declarations','-framework','Cocoa','-framework','CoreText','-framework','QuartzCore','-F'+subprocess.check_output(['xcrun','--show-sdk-path'],text=True).strip()+'/System/Library/PrivateFrameworks','-framework','CoreUI','-dynamiclib',str(source/'compat/MavericksAppearance/MavericksAppearance.m'),str(source/'compat/MavericksAppearance/MavericksDesktop.m'),str(source/'compat/MavericksAppearance/MavericksWidgets.m'),str(source/'compat/MavericksAppearance/MavericksCoreUI.m'),str(source/'compat/MavericksAppearance/MavericksCatalog.m'),'-o',str(library)],check=True)
    remote=stage(library);run('/bin/mkdir',['-p','/Library/Application Support/MavericksAppearance'])
    run('/bin/cp',[remote,'/Library/Application Support/MavericksAppearance/MavericksAppearance.next.dylib'])
    run('/bin/chmod',['0644','/Library/Application Support/MavericksAppearance/MavericksAppearance.next.dylib']);run('/bin/mv',['/Library/Application Support/MavericksAppearance/MavericksAppearance.next.dylib','/Library/Application Support/MavericksAppearance/MavericksAppearance.dylib']);print('Installed appearance library in cloned guest')
elif sys.argv[2]=='install-legacy-coreui':
    remote=stage(source/'Build/mavericks-appearance/assets/isolated-coreui.tar.gz')
    print(run('/usr/bin/python',['-c','import os,sys,tarfile,tempfile,time; base="/Library/Application Support/MavericksAppearance"; work=tempfile.mkdtemp(prefix="CoreUI-",dir=base); tarfile.open(sys.argv[1]).extractall(work); target=base+"/LoreUI.framework"; backup=base+"/LoreUI.previous-"+str(time.time()); os.rename(target,backup) if os.path.exists(target) else None; os.rename(work+"/LoreUI.framework",target); os.rmdir(work)',remote]))
    print('Installed isolated original rendering engine in clone')
elif sys.argv[2]=='probe-legacy-coreui':
    executable=root/'CoreUIProbe'
    subprocess.run(['xcrun','clang','-arch','x86_64','-mmacosx-version-min=10.9','-framework','Cocoa',str(source/'probes/mavericks-coreui.m'),'-o',str(executable)],check=True)
    remote=stage(executable);print(run(remote,sys.argv[3:],180))
elif sys.argv[2]=='export-named':
    executable=root/'ExportNamedImages'
    subprocess.run(['xcrun','clang','-arch','x86_64','-mmacosx-version-min=10.9','-fno-objc-arc','-Wno-deprecated-declarations','-framework','Cocoa','-I',str(source/'Build/mavericks-appearance'),str(source/'probes/mavericks-export-named-images.m'),'-o',str(executable)],check=True)
    remote=stage(executable);print(run(remote,['/tmp/MavericksNamedImagesConsole'],300))
    run('/usr/bin/tar',['czf','/tmp/MavericksNamedImages.tar.gz','-C','/tmp/MavericksNamedImagesConsole','.']);print('Archive /tmp/MavericksNamedImages.tar.gz')
elif sys.argv[2]=='export-dock-scene':
    helper=root/'ReferenceSession'
    subprocess.run(['xcrun','clang','-arch','x86_64','-mmacosx-version-min=10.9',str(source/'probes/mavericks-reference-session.m'),'-o',str(helper)],check=True)
    remote=stage(helper);run('/bin/cp',[remote,'/tmp/MavericksReferenceSession']);run('/bin/chmod',['0755','/tmp/MavericksReferenceSession'])
    dumper=root/'DockImage'
    subprocess.run(['xcrun','clang','-arch','x86_64','-mmacosx-version-min=10.9','-framework','Foundation',str(source/'probes/mavericks-dock-image.m'),'-o',str(dumper)],check=True)
    if run('/usr/bin/python',['-c','import os;print(int(os.path.isfile("/tmp/MavericksDockDecrypted")))']).strip()!='1':
        remote=stage(dumper);pid=run('/usr/bin/pgrep',['-x','Dock']).strip();print(run(remote,[pid]))
    library=root/'ReferenceShell.dylib'
    subprocess.run(['xcrun','clang','-arch','x86_64','-mmacosx-version-min=10.9','-fno-objc-arc','-Wno-deprecated-declarations','-framework','Cocoa','-framework','QuartzCore','-dynamiclib',str(source/'probes/mavericks-reference-shell.m'),'-o',str(library)],check=True)
    remote=stage(library);run('/bin/cp',[remote,'/tmp/MavericksReferenceShell.dylib']);run('/bin/chmod',['0644','/tmp/MavericksReferenceShell.dylib'])
    print(run('/usr/bin/python',['-c',(source/'probes/mavericks-reference-shell.py').read_text()],180))
    run('/usr/bin/tar',['czf','/tmp/MavericksReferenceShell.tar.gz','-C','/tmp/MavericksReferenceShell','.'])
elif sys.argv[2]=='export-file':
    remote=sys.argv[3];dest=Path(sys.argv[4]).resolve()
    if not dest.is_relative_to(source/'Build/mavericks-appearance'):raise RuntimeError('Export destination leaves experiment')
    size=int(run('/usr/bin/stat',['-f','%z',remote]));data=bytearray()
    if not 0<size<134217728:raise RuntimeError('Export size cap')
    for offset in range(0,size,196608):data.extend(base64.b64decode(run('/usr/bin/python',['-c','import base64,sys;f=open(sys.argv[1],"rb");f.seek(int(sys.argv[2]));print(base64.b64encode(f.read(196608)))',remote,offset],180)))
    if len(data)!=size:raise RuntimeError('Truncated guest export')
    dest.write_bytes(data);print(str(dest),len(data))
elif sys.argv[2]=='install-legacy-compat':
    remote=stage(source/'Build/mavericks-appearance/LegacyDockCompatibility.dylib')
    run('/bin/cp',[remote,'/Library/Application Support/MavericksAppearance/LegacyDockCompatibility.dylib']);run('/bin/chmod',['0644','/Library/Application Support/MavericksAppearance/LegacyDockCompatibility.dylib'])
elif sys.argv[2]=='install-named':
    remote=stage(source/'Build/mavericks-appearance/assets/named-images.tar.gz')
    run('/bin/mkdir',['-p','/Library/Application Support/MavericksAppearance/NamedImages'])
    print(run('/usr/bin/python',['-c',(source/'probes/mavericks-named-assets-apply.py').read_text(),remote]))
    print('Installed the original AppKit image catalog')
elif sys.argv[2]=='install-dock-art':
    remote=stage(source/'Build/mavericks-appearance/original-dock-scene/mavericks-glass@2x.png')
    run('/bin/mkdir',['-p','/Library/Application Support/MavericksAppearance/Art'])
    run('/bin/cp',[remote,'/Library/Application Support/MavericksAppearance/Art/mavericks-glass@2x.png']);run('/bin/chmod',['0644','/Library/Application Support/MavericksAppearance/Art/mavericks-glass@2x.png']);print('Installed original Dock glass artwork')
elif sys.argv[2] in ('install-installer-assets','install-bundle-assets'):
    artifact='bundle-assets' if sys.argv[2]=='install-bundle-assets' else 'installer-assets'
    archive=stage(source/('Build/mavericks-appearance/assets/'+artifact+'.tar.gz'));manifest=stage(source/('Build/mavericks-appearance/assets/'+artifact+'.json'))
    print(run('/usr/bin/python',['-c',(source/'probes/mavericks-installer-assets-apply.py').read_text(),archive,manifest],900))
elif sys.argv[2] in ('install-installer-assets-media','install-bundle-assets-media'):
    artifact='bundle-assets' if sys.argv[2]=='install-bundle-assets-media' else 'installer-assets'
    volumes=json.loads(run('/usr/bin/python',['-c','import json,os,sys;print(json.dumps(["/Volumes/"+n+"/" for n in os.listdir("/Volumes") if os.path.isfile("/Volumes/"+n+"/"+sys.argv[1]+".json") and os.path.isfile("/Volumes/"+n+"/"+sys.argv[1]+".tar.gz") and os.statvfs("/Volumes/"+n).f_flag&1]))',artifact]))
    if len(volumes)!=1:raise RuntimeError('Exactly one read-only installer asset medium required: '+str(volumes))
    base=volumes[0]
    print(run('/usr/bin/python',['-c',(source/'probes/mavericks-installer-assets-apply.py').read_text(),base+artifact+'.tar.gz',base+artifact+'.json'],900))
elif sys.argv[2]=='relaunch-apps':
    executable=root/'RelaunchApplications'
    subprocess.run(['xcrun','clang','-arch','x86_64','-mmacosx-version-min=10.9','-fno-objc-arc','-Wno-deprecated-declarations','-framework','Cocoa',str(source/'probes/mavericks-relaunch-applications.m'),'-o',str(executable)],check=True)
    remote=stage(executable);target='/Library/Application Support/MavericksAppearance/RelaunchApplications'
    run('/bin/cp',[remote,target]);run('/bin/chmod',['0755',target]);uid=run('/usr/bin/stat',['-f','%u','/dev/console']).strip()
    print(run('/bin/launchctl',['asuser',uid,'/usr/bin/sudo','-n','-u','#'+uid,'/usr/bin/env','DYLD_INSERT_LIBRARIES=/Library/Application Support/MavericksAppearance/MavericksAppearance.dylib',target],300))
elif sys.argv[2]=='install-font-alias':
    patch=stage(source/'Build/mavericks-appearance/assets/lucida-modern.patch')
    print(run('/usr/bin/python',['-c',(source/'probes/mavericks-font-alias-apply.py').read_text(),patch],300))
elif sys.argv[2]=='legacy-imports':
    executable=root/'LegacyImports'
    subprocess.run(['xcrun','clang','-arch','x86_64','-mmacosx-version-min=10.9','-framework','Foundation','-I',str(source/'Build/mavericks-appearance'),str(source/'probes/mavericks-legacy-imports.m'),'-o',str(executable)],check=True)
    remote=stage(executable);print(run(remote,[],180))
elif sys.argv[2]=='install-shell-icons':
    archive=stage(source/'Build/mavericks-appearance/assets/shell-icons.tar');manifest=stage(source/'Build/mavericks-appearance/assets/shell-icons.json')
    print(run('/usr/bin/python',['-c',(source/'probes/mavericks-shell-assets-apply.py').read_text(),archive,manifest],300))
elif sys.argv[2]=='install-patterns':
    for name in ('titlebar-active.tiff','titlebar-inactive.tiff'):
        remote=stage(source/'Build/mavericks-appearance/original/generated'/name)
        run('/bin/cp',[remote,'/Library/Application Support/MavericksAppearance/Art/'+name])
    print('Original titlebar patterns installed')
elif sys.argv[2]=='export-titlebar':
    remote='/tmp/lc-titlebar-render-0.tiff' if '--rendered' in sys.argv else '/tmp/lc-titlebar-0.tiff';size=int(run('/usr/bin/stat',['-f','%z',remote]));data=bytearray()
    if not 0<size<8388608:raise RuntimeError('Pattern size cap')
    for offset in range(0,size,12000):data.extend(base64.b64decode(run('/usr/bin/python',['-c','import base64,sys;f=open(sys.argv[1],"rb");f.seek(int(sys.argv[2]));print(base64.b64encode(f.read(12000)))',remote,offset])))
    out=source/'Build/mavericks-appearance/original/generated';out.mkdir(exist_ok=True)
    (out/(('titlebar-rendered-' if '--rendered' in sys.argv else 'titlebar-')+('inactive.tiff' if '--inactive' in sys.argv else 'active.tiff'))).write_bytes(data);print('Exported original titlebar pattern',len(data))
elif sys.argv[2]=='font-smoothing':
    uid=run('/usr/bin/stat',['-f','%u','/dev/console']).strip()
    if not uid.isdigit() or int(uid)<501:raise RuntimeError('No console user')
    prefix=['asuser',uid,'/usr/bin/sudo','-n','-u','#'+uid,'/usr/bin/defaults','write','-g']
    run('/bin/launchctl',prefix+['CGFontRenderingFontSmoothingDisabled','-bool','NO'])
    run('/bin/launchctl',prefix+['AppleFontSmoothing','-int','2'])
    print('Enabled legacy font-smoothing preferences for the disposable guest console user')
elif sys.argv[2]=='install-art':
    remote=stage(source/'Build/mavericks-appearance/assets/render-art.tar');run('/bin/mkdir',['-p','/Library/Application Support/MavericksAppearance/Art']);run('/usr/bin/tar',['xf',remote,'-C','/Library/Application Support/MavericksAppearance/Art']);print('Original control artwork installed')
elif sys.argv[2]=='inspect':
    probe=stage(source/'Build/mavericks-appearance/control-inspect');text=run(probe,[]);(root/'selectors.json').write_text(text);print(text)
elif sys.argv[2]=='inspect-image-catalogs':
    executable=root/'ImageCatalogs'
    subprocess.run(['xcrun','clang','-arch','x86_64','-mmacosx-version-min=10.9','-framework','Cocoa',str(source/'probes/mavericks-image-catalogs.m'),'-o',str(executable)],check=True)
    remote=stage(executable);result=run(remote,[]);(root/'image-catalogs.json').write_text(result);print(root/'image-catalogs.json')
elif sys.argv[2]=='capture':
    label=sys.argv[3];mode=sys.argv[4] if len(sys.argv)>4 else '2';reference=mode=='reference';state=sys.argv[5] if len(sys.argv)>5 else 'active'
    if not label.replace('-','').replace('_','').isalnum() or state not in ('active','inactive','disabled','progress0','progress50','progress100'):raise ValueError('Invalid label/state')
    snapshot=root/'source-snapshots'/label;snapshot.mkdir(parents=True,exist_ok=True)
    shutil.copyfile(source/'probes/mavericks-appearance.m',snapshot/'fixture.m')
    shutil.copyfile(source/'compat/MavericksAppearance/MavericksAppearance.m',snapshot/'appearance.m')
    shutil.copyfile(source/'probes/seamless-session-join.h',snapshot/'seamless-session-join.h')
    source_hashes={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(snapshot.iterdir())}
    common=['xcrun','clang','-arch','x86_64','-mmacosx-version-min=10.9','-fno-objc-arc','-Wno-deprecated-declarations','-framework','Cocoa','-framework','QuartzCore']
    fixture=root/(label+'-fixture');library=root/(label+'-appearance.dylib')
    subprocess.run(common+[str(snapshot/'fixture.m'),'-o',str(fixture)],check=True)
    if not reference and '--modern-sdk' not in sys.argv:
        data=bytearray(fixture.read_bytes());at=32
        for _ in range(struct.unpack_from('<I',data,16)[0]):
            cmd,size=struct.unpack_from('<II',data,at)
            if cmd==0x24:struct.pack_into('<I',data,at+12,0xa0900)
            at+=size
        fixture.write_bytes(data)
    if not reference:
        subprocess.run(common+['-framework','CoreText','-dynamiclib',str(snapshot/'appearance.m'),'-o',str(library)],check=True)
    remote=stage(fixture);dylib=stage(library) if not reference else ''
    png='/tmp/lc-appearance-live-'+label+'.png'
    text=run(remote,['0' if reference else mode,png,dylib,state],360);report=json.loads(text[text.index('{'):]);report['sourceSHA256']=source_hashes;report['requestedState']=state;(root/(label+'.json')).write_text(json.dumps(report,indent=2))
    if '--metrics' in sys.argv:
        print(json.dumps(report,indent=2));sys.exit(0)
    size=int(run('/usr/bin/stat',['-f','%z',png]));data=bytearray()
    if not 0<size<4000000:raise RuntimeError('Capture size cap')
    for offset in range(0,size,12000):data.extend(base64.b64decode(run('/usr/bin/python',['-c','import base64,sys;f=open(sys.argv[1],"rb");f.seek(int(sys.argv[2]));print(base64.b64encode(f.read(12000)))',png,offset])))
    (root/(label+'.png')).write_bytes(data);print(json.dumps(report,indent=2))
else:raise SystemExit('inspect or capture required')
